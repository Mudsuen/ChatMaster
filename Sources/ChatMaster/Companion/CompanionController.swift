import AppKit
import Carbon.HIToolbox
import Combine
import LensCore
import SwiftUI

/// Non-activating floating panel: clicking it does not take focus away from WeChat.
final class FloatingPanel: NSPanel {
    init(size: NSSize, titled: Bool) {
        var style: NSWindow.StyleMask = [.nonactivatingPanel, .fullSizeContentView]
        if titled { style.formUnion([.titled, .closable, .resizable, .utilityWindow]) } else { style.insert(.borderless) }
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        if titled {
            titleVisibility = .hidden
            titlebarAppearsTransparent = true
            isMovableByWindowBackground = true
        }
    }

    override var canBecomeKey: Bool { true }
}

enum ClipboardGuard {
    /// changeCount produced by our own copy actions (ignored by the watcher).
    nonisolated(unsafe) static var ownChangeCount = -1
}

@MainActor
final class PopupModel: ObservableObject {
    enum Source { case clipboard, ocr }
    enum State { case idle, loading(Date), done(MessageAnalysis), failed(String) }

    @Published var text = ""
    @Published var source: Source = .clipboard
    @Published var chatHint: String?
    @Published var matched: LensMessage?
    @Published var state: State = .idle

    func start(text: String, source: Source, chatHint: String?) {
        self.text = text
        self.source = source
        self.chatHint = chatHint
        matched = AppModel.shared.store?.findMessage(text: text, preferChat: chatHint)
        run(force: false)
    }

    func run(force: Bool) {
        guard let engine = AppModel.shared.engine else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { state = .failed("没有可分析的文字"); return }
        state = .loading(Date())
        let hint = chatHint
        Task {
            do {
                let (a, m) = try await engine.analyze(text: t, chatHint: hint, force: force)
                matched = m
                if let m { AppModel.shared.analyses[m.id] = .done(a) }
                state = .done(a)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

@MainActor
final class CompanionController: ObservableObject {
    static let shared = CompanionController()

    let tracker = WeChatTracker()
    let popup = PopupModel()
    @Published var currentChat: String?
    @Published var followWeChat = true
    @Published var collapsed = false
    @Published var detectedByOCR = false
    @Published var isPreviewing = false

    private var sidebarPanel: FloatingPanel?
    private var sidebarResignObserver: NSObjectProtocol?
    private var bubblePanel: FloatingPanel?
    private var popupPanel: FloatingPanel?
    private var bag = Set<AnyCancellable>()
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var bubbleText = ""
    private var bubbleHide: DispatchWorkItem?
    private var lastSelfSent: Date?
    private var lastOCRMatch: Date?
    private var lastOpened: Date?
    private var ocrBusy = false
    private var promptedAX = false

    func start() {
        tracker.start()
        Publishers.CombineLatest(tracker.$frame, tracker.$isFrontmost)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.updateSidebar() }
            .store(in: &bag)
        $collapsed.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateSidebar() }
        }.store(in: &bag)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.updateSidebar() }.store(in: &bag)
        AppModel.shared.newMessageHandlers.append { [weak self] msgs in self?.onNewMessages(msgs) }
        AppModel.shared.chatOpenedHandlers.append { [weak self] chat in self?.onChatOpened(chat) }

        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollClipboard() }
        }
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.detectCurrentChat() }
        }

        let mods = controlKey | optionKey
        HotKeyCenter.shared.register(id: 1, keyCode: kVK_ANSI_A, modifiers: mods) { [weak self] in self?.captureAndAnalyze() }
        HotKeyCenter.shared.register(id: 2, keyCode: kVK_ANSI_V, modifiers: mods) { [weak self] in self?.analyzeClipboard() }
        HotKeyCenter.shared.register(id: 3, keyCode: kVK_ANSI_S, modifiers: mods) {
            Prefs.d.set(!Prefs.d.bool(forKey: Prefs.sidebar), forKey: Prefs.sidebar)
        }

        currentChat = AppModel.shared.store?.recent(limit: 50).first(where: { $0.isSelf })?.chat
            ?? AppModel.shared.store?.recent(limit: 1).first?.chat
        if Prefs.d.bool(forKey: Prefs.sidebar) && !AXIsProcessTrusted() { promptAccessibility() }
    }

    func promptAccessibility() {
        guard !promptedAX else { return }
        promptedAX = true
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - sidebar

    private func updateSidebar() {
        if tracker.isFrontmost, let chat = currentChat {
            AppModel.shared.markMenuBarRead(chat)
        }
        if isPreviewing {
            let panel = sidebarPanel ?? makeSidebar()
            let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
            let w: CGFloat = collapsed ? 46 : 340
            let h = min(680, max(500, vf.height - 80))
            let target = CGRect(x: vf.maxX - w - 36, y: round(vf.midY - h / 2), width: w, height: collapsed ? min(h, 200) : h)
            if panel.frame != target { panel.setFrame(target, display: true) }
            panel.orderFrontRegardless()
            return
        }
        let enabled = Prefs.d.bool(forKey: Prefs.sidebar)
        guard enabled, let wf = tracker.frame, tracker.isFrontmost || (sidebarPanel?.isKeyWindow ?? false) else {
            sidebarPanel?.orderOut(nil)
            return
        }
        let panel = sidebarPanel ?? makeSidebar()
        let target = sidebarFrame(for: wf)
        if panel.frame != target { panel.setFrame(target, display: true) }
        if !panel.isVisible { panel.orderFront(nil) }
    }

    func previewSidebar(chat: String) {
        currentChat = chat
        followWeChat = false
        collapsed = false
        isPreviewing = true
        updateSidebar()
    }

    func endPreview() {
        isPreviewing = false
        followWeChat = true
        updateSidebar()
    }

    private func makeSidebar() -> FloatingPanel {
        let p = FloatingPanel(size: NSSize(width: 340, height: 600), titled: false)
        p.contentView = NSHostingView(rootView: CompanionSidebarView()
            .environmentObject(AppModel.shared).environmentObject(self))
        sidebarResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: p,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSidebar() }
        }
        sidebarPanel = p
        return p
    }

    private func sidebarFrame(for wf: CGRect) -> CGRect {
        let width: CGFloat = collapsed ? 46 : 340
        let gap: CGFloat = 6
        let screen = NSScreen.screens.first { $0.frame.intersects(wf) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? wf
        var x = wf.maxX + gap
        if x + width > vf.maxX {
            x = wf.minX - gap - width
            if x < vf.minX { x = wf.maxX - width - 8 }
        }
        let y = max(wf.minY, vf.minY)
        let h = min(wf.maxY, vf.maxY) - y
        return CGRect(x: x, y: y, width: width, height: collapsed ? min(h, 200) : h).integral
    }

    func pin(_ chat: String?) {
        if let chat { currentChat = chat; followWeChat = false } else { followWeChat = true; detectCurrentChat() }
    }

    // MARK: - current chat detection

    var ocrAvailable: Bool { Prefs.d.bool(forKey: Prefs.followOCR) && CGPreflightScreenCaptureAccess() }

    private var ocrFresh: Bool { Date().timeIntervalSince(lastOCRMatch ?? .distantPast) < 4 }

    /// Signals, strongest first: OCR of the title bar > chat opened (WeChat cleared its unread
    /// marker) > a message I just sent > (without OCR) a new private message.
    private func onChatOpened(_ chat: String) {
        guard followWeChat, !ocrFresh else { return }
        lastOpened = Date()
        if currentChat != chat { currentChat = chat }
    }

    private func onNewMessages(_ msgs: [LensMessage]) {
        guard followWeChat, !ocrFresh else { return }
        if let mine = msgs.last(where: { $0.isSelf }) {
            lastSelfSent = Date()
            currentChat = mine.chat
            return
        }
        let recentlyChosen = Date().timeIntervalSince(lastSelfSent ?? .distantPast) < 120
            || Date().timeIntervalSince(lastOpened ?? .distantPast) < 120
        if !ocrAvailable, !recentlyChosen, let m = msgs.last(where: { !$0.chat.hasSuffix("@chatroom") && !$0.isSystem }) {
            currentChat = m.chat
        }
    }

    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    private func detectCurrentChat() {
        guard followWeChat, tracker.isFrontmost, !ocrBusy, Prefs.d.bool(forKey: Prefs.followOCR),
              CGPreflightScreenCaptureAccess(), tracker.frame != nil else { return }
        ocrBusy = true
        let chats = AppModel.shared.chats
        Task {
            defer { ocrBusy = false }
            // Title bar strip only: the session list starts below it, so its names are not captured.
            guard let img = await ScreenText.captureWeChatHeader(height: 54) else { return }
            let lines = await Task.detached { ScreenText.recognize(img).map { ($0.text, $0.box.minX) } }.value
            if let chat = CompanionController.match(lines: lines, chats: chats) {
                detectedByOCR = true
                lastOCRMatch = Date()
                if currentChat != chat { currentChat = chat }
                AppModel.shared.markMenuBarRead(chat)
            }
        }
    }

    nonisolated static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: #"\s*[\(（]\d+[\)）]$"#, options: .regularExpression) { t.removeSubrange(r) }
        for suffix in ["...", "…"] where t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
        return t
    }

    /// Matches OCR lines (text, normalized minX) against chat names; the chat title is the
    /// right-most match (left of it there is only the search field / session list).
    nonisolated static func match(lines: [(String, CGFloat)], chats: [ChatSummary]) -> String? {
        let ignored: Set<String> = ["搜索", "Search", "微信", "Weixin", "WeChat"]
        let cands = lines.map { (normalize($0.0), $0.1) }.filter { !$0.0.isEmpty && !ignored.contains($0.0) }
            .sorted { $0.1 > $1.1 }
        for (t, _) in cands { if let c = chats.first(where: { $0.display == t }) { return c.username } }
        for (t, _) in cands where t.count >= 3 {
            if let c = chats.first(where: { $0.display.count >= 3 && ($0.display.hasPrefix(t) || t.hasPrefix($0.display)) }) {
                return c.username
            }
        }
        return nil
    }

    // MARK: - clipboard bubble

    private func pollClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard pb.changeCount != ClipboardGuard.ownChangeCount, Prefs.d.bool(forKey: Prefs.bubble), tracker.isFrontmost,
              let s = pb.string(forType: .string) else { return }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 4000 else { return }
        showBubble(text: t)
    }

    private func showBubble(text: String) {
        bubbleText = text
        let panel = bubblePanel ?? {
            let p = FloatingPanel(size: NSSize(width: 118, height: 40), titled: false)
            p.contentView = NSHostingView(rootView: BubbleView { [weak self] in self?.bubbleTapped() })
            bubblePanel = p
            return p
        }()
        let m = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: m.x + 14, y: m.y - 50))
        panel.alphaValue = 1
        panel.orderFront(nil)
        bubbleHide?.cancel()
        let work = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        bubbleHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func bubbleTapped() {
        bubblePanel?.orderOut(nil)
        openPopup(text: bubbleText, source: .clipboard, near: bubblePanel?.frame.origin ?? NSEvent.mouseLocation)
    }

    func analyzeClipboard() {
        guard let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { NSSound.beep(); return }
        openPopup(text: s, source: .clipboard, near: NSEvent.mouseLocation)
    }

    func captureAndAnalyze() {
        Task {
            guard let img = await ScreenText.captureRegion() else { return }
            let text = await Task.detached { ScreenText.text(of: img) }.value
            guard !text.isEmpty else { NSSound.beep(); return }
            openPopup(text: text, source: .ocr, near: NSEvent.mouseLocation)
        }
    }

    // MARK: - popup

    func openPopup(text: String, source: PopupModel.Source, near point: NSPoint) {
        let panel = popupPanel ?? {
            let p = FloatingPanel(size: NSSize(width: 420, height: 600), titled: true)
            p.contentView = NSHostingView(rootView: PopupAnalysisView()
                .environmentObject(AppModel.shared).environmentObject(popup))
            p.minSize = NSSize(width: 360, height: 360)
            popupPanel = p
            return p
        }()
        popup.start(text: text, source: source, chatHint: tracker.isFrontmost ? currentChat : nil)
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? .zero
        var origin = NSPoint(x: point.x + 16, y: point.y - size.height + 20)
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
        origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
        panel.orderFront(nil)
        panel.makeKey()
    }
}
