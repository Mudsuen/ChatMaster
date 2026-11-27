import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ScreenCaptureKit
import Vision

let weChatBundleID = "com.tencent.xinWeChat"

/// Tracks the main WeChat window through the Accessibility API (frame only; WeChat 4.x exposes no chat content).
@MainActor
final class WeChatTracker: ObservableObject {
    @Published private(set) var frame: CGRect?  // Cocoa global coordinates
    @Published private(set) var isFrontmost = false
    @Published private(set) var axTrusted = AXIsProcessTrusted()
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    static func runningWeChat() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: weChatBundleID).first { !$0.isTerminated }
    }

    private func poll() {
        axTrusted = AXIsProcessTrusted()
        guard let app = WeChatTracker.runningWeChat() else { set(nil, false); return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        guard axTrusted, !app.isHidden else { set(nil, front); return }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { set(nil, front); return }
        var best: CGRect?
        for w in windows {
            var minimized: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &minimized)
            if (minimized as? Bool) == true { continue }
            var sub: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &sub)
            if let s = sub as? String, s != (kAXStandardWindowSubrole as String) { continue }
            guard let r = WeChatTracker.rect(of: w), r.width >= 480, r.height >= 360 else { continue }
            if best == nil || r.width * r.height > best!.width * best!.height { best = r }
        }
        set(best.map(WeChatTracker.toCocoa), front)
    }

    private func set(_ f: CGRect?, _ front: Bool) {
        if frame != f { frame = f }
        if isFrontmost != front { isFrontmost = front }
    }

    static func rect(of w: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    /// AX uses a top-left origin on the primary screen; Cocoa uses bottom-left.
    static func toCocoa(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: h - r.minY - r.height, width: r.width, height: r.height)
    }
}

// MARK: - Global hot keys (Carbon; no extra permission needed)

final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false

    func register(id: UInt32, keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        installIfNeeded()
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x434D_5354), id: id)  // 'CMST'
        if RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID, GetApplicationEventTarget(), 0, &ref) == noErr,
           let ref {
            refs.append(ref)
        }
    }

    fileprivate func fire(_ id: UInt32) {
        DispatchQueue.main.async { self.handlers[id]?() }
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            HotKeyCenter.shared.fire(hk.id)
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// MARK: - OCR helpers

enum ScreenText {
    struct Line { var text: String; var box: CGRect }  // box in normalized image coords (origin bottom-left)

    static func recognize(_ image: CGImage, fast: Bool = false) -> [Line] {
        let req = VNRecognizeTextRequest()
        req.recognitionLanguages = ["zh-Hans", "en-US"]
        req.recognitionLevel = fast ? .fast : .accurate
        req.usesLanguageCorrection = !fast
        let handler = VNImageRequestHandler(cgImage: image)
        try? handler.perform([req])
        return (req.results ?? []).compactMap { o in
            guard let c = o.topCandidates(1).first else { return nil }
            return Line(text: c.string, box: o.boundingBox)
        }
    }

    /// Lines ordered top-to-bottom, left-to-right, joined with newlines.
    static func text(of image: CGImage) -> String {
        recognize(image).sorted { a, b in
            abs(a.box.midY - b.box.midY) > 0.01 ? a.box.midY > b.box.midY : a.box.minX < b.box.minX
        }.map(\.text).joined(separator: "\n")
    }

    /// Interactive region capture with the system `screencapture` tool.
    static func captureRegion() async -> CGImage? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chatmaster-ocr-\(UUID().uuidString).png")
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-i", "-x", "-o", url.path]
                try? p.run()
                p.waitUntilExit()
                defer { try? FileManager.default.removeItem(at: url) }
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { cont.resume(returning: nil); return }
                cont.resume(returning: img)
            }
        }
    }

    /// Captures the top strip of the WeChat window (where the open chat's title is) via ScreenCaptureKit.
    static func captureWeChatHeader(height: CGFloat = 72) async -> CGImage? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let wins = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == weChatBundleID && $0.frame.width >= 480 && $0.frame.height >= 360
            }
            guard let win = wins.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = CGRect(x: 0, y: 0, width: win.frame.width, height: height)
            cfg.width = Int(win.frame.width * 2)
            cfg.height = Int(height * 2)
            cfg.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        } catch {
            return nil
        }
    }
}
