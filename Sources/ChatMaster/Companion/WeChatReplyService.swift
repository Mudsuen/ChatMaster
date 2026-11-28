import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import LensCore

/// Sends a user-initiated reply to a WeChat chat via macOS Accessibility and CGEvents.
/// Never touches the WeChat container databases, never injects code, and verifies the active
/// chat title via OCR when Screen Recording permission is available before pasting/sending.
@MainActor
enum WeChatReplyService {
    enum ReplyError: LocalizedError, Equatable {
        case emptyText
        case busy
        case weChatNotRunning
        case accessibilityDenied
        case windowUnavailable
        case ambiguousTarget(String)
        case chatMismatch(String)

        var errorDescription: String? {
            switch self {
            case .emptyText: return "回复内容不能为空"
            case .busy: return "正在发送上一条消息，请稍候"
            case .weChatNotRunning: return "微信未运行，请先打开微信"
            case .accessibilityDenied: return "需要「辅助功能」权限才能直接回复，请在系统设置中授权"
            case .windowUnavailable: return "无法定位微信主窗口，请先打开微信窗口"
            case .ambiguousTarget(let name): return "「\(name)」未设置群名称或备注，无法安全定位，请先在微信中打开该会话"
            case .chatMismatch(let name): return "未能确认微信已切换到「\(name)」，已取消发送以防误发"
            }
        }
    }

    private static var isSending = false
    private static var lastExternalApp: NSRunningApplication?
    private static var observer: NSObjectProtocol?

    /// Tracks the last active application outside ChatMaster/WeChat so MenuBar replies can
    /// return focus cleanly to whatever the user was doing after sending.
    static func startObservingFrontmostApp() {
        guard observer == nil else { return }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier,
           front.bundleIdentifier != weChatBundleID {
            lastExternalApp = front
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let bid = app.bundleIdentifier
            if bid != Bundle.main.bundleIdentifier && bid != weChatBundleID {
                MainActor.assumeIsolated { lastExternalApp = app }
            }
        }
    }

    /// Picks a reliable search query for `⌘F` in WeChat, preferring remark > WeChat ID > nickname.
    /// Returns `nil` for unnamed group chats (`"群聊 ..."`).
    nonisolated static func searchQuery(for contact: Contact?, fallbackDisplay: String) -> String? {
        if let c = contact {
            if !c.remark.isEmpty { return c.remark }
            if c.kind == .person, !c.alias.isEmpty { return c.alias }
            if !c.nick.isEmpty { return c.nick }
            return nil
        }
        let trimmed = fallbackDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("群聊 ") else { return nil }
        return trimmed
    }

    static func send(text rawText: String, to chat: String, contact: Contact?, fallbackDisplay: String,
                     chats: [ChatSummary], useCommandReturn: Bool) async throws {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ReplyError.emptyText }
        guard !isSending else { throw ReplyError.busy }
        isSending = true
        defer { isSending = false }

        guard let app = WeChatTracker.runningWeChat() else { throw ReplyError.weChatNotRunning }
        guard AXIsProcessTrusted() else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            throw ReplyError.accessibilityDenied
        }

        let displayName = contact?.display ?? fallbackDisplay
        let prevClipboard = NSPasteboard.general.string(forType: .string)
        let screenOK = CGPreflightScreenCaptureAccess()
        let weChatWasHidden = app.isHidden
        let returnApp: NSRunningApplication? = {
            if let front = NSWorkspace.shared.frontmostApplication,
               front.bundleIdentifier != Bundle.main.bundleIdentifier,
               front.bundleIdentifier != weChatBundleID {
                return front
            }
            return lastExternalApp
        }()

        app.activate()
        try? await Task.sleep(for: .milliseconds(180))

        var axRect = weChatWindowRect(for: app)
        if axRect == nil {
            postKey(kVK_ANSI_1, flags: .maskCommand)
            try? await Task.sleep(for: .milliseconds(260))
            axRect = weChatWindowRect(for: app)
        }
        guard let winRect = axRect else { throw ReplyError.windowUnavailable }

        var matchedAlready = false
        if screenOK, let active = await detectActiveChat(chats: chats), active == chat {
            matchedAlready = true
        }

        if matchedAlready {
            // Focus the message composer in the bottom-right pane of WeChat's main window.
            let composerPoint = CGPoint(x: winRect.minX + winRect.width * 0.65, y: winRect.maxY - 64)
            click(at: composerPoint)
            try? await Task.sleep(for: .milliseconds(100))
        } else {
            guard let query = searchQuery(for: contact, fallbackDisplay: fallbackDisplay) else {
                throw ReplyError.ambiguousTarget(displayName)
            }
            postKey(kVK_ANSI_1, flags: .maskCommand)
            try? await Task.sleep(for: .milliseconds(120))
            postKey(kVK_ANSI_F, flags: .maskCommand)
            try? await Task.sleep(for: .milliseconds(180))
            postKey(kVK_ANSI_A, flags: .maskCommand)
            postKey(kVK_Delete)
            try? await Task.sleep(for: .milliseconds(60))

            setClipboard(query)
            postKey(kVK_ANSI_V, flags: .maskCommand)
            try? await Task.sleep(for: .milliseconds(420))
            postKey(kVK_Return)
            try? await Task.sleep(for: .milliseconds(300))

            if screenOK {
                var verified = await detectActiveChat(chats: chats) == chat
                if !verified {
                    try? await Task.sleep(for: .milliseconds(260))
                    verified = await detectActiveChat(chats: chats) == chat
                }
                if !verified {
                    restoreClipboard(prevClipboard)
                    throw ReplyError.chatMismatch(displayName)
                }
            }
        }

        setClipboard(text)
        postKey(kVK_ANSI_V, flags: .maskCommand)
        try? await Task.sleep(for: .milliseconds(120))
        postKey(kVK_Return, flags: useCommandReturn ? .maskCommand : [])
        try? await Task.sleep(for: .milliseconds(220))

        restoreClipboard(prevClipboard)
        if weChatWasHidden { app.hide() }
        if let returnApp, !returnApp.isTerminated {
            returnApp.activate()
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            AppModel.shared.syncNow()
        }
    }

    private static func detectActiveChat(chats: [ChatSummary]) async -> String? {
        guard let img = await ScreenText.captureWeChatHeader(height: 54) else { return nil }
        let lines = await Task.detached { ScreenText.recognize(img).map { ($0.text, $0.box.minX) } }.value
        return CompanionController.match(lines: lines, chats: chats)
    }

    private static func weChatWindowRect(for app: NSRunningApplication) -> CGRect? {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        var best: CGRect?
        for w in windows {
            var sub: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &sub)
            if let s = sub as? String, s != (kAXStandardWindowSubrole as String) { continue }
            var minimized: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &minimized)
            if (minimized as? Bool) == true {
                AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            guard let r = WeChatTracker.rect(of: w), r.width >= 480, r.height >= 360 else { continue }
            if best == nil || r.width * r.height > best!.width * best!.height { best = r }
        }
        return best
    }

    private static func setClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        ClipboardGuard.ownChangeCount = pb.changeCount
    }

    private static func restoreClipboard(_ previous: String?) {
        guard let previous else { return }
        setClipboard(previous)
    }

    private static func postKey(_ keyCode: Int, flags: CGEventFlags = []) {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func click(at point: CGPoint) {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
