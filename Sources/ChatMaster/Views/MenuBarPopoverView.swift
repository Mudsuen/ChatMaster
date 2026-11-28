import AppKit
import LensCore
import MudsUI
import SwiftUI

/// Custom monochrome template glyph for the macOS menu bar: rounded speech bubble
/// with a bottom-left tail and a 4-point intelligence star punched out of the center.
/// When `unreadCount > 0`, renders a vibrant red unread pill directly into the status item image
/// so macOS MenuBar displays color instead of flattening SwiftUI backgrounds to monochrome.
enum ChatMasterGlyph {
    private static func drawGlyph(in rect: NSRect, fill: NSColor) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = NSRect(x: rect.minX + 1.5, y: rect.minY + 3.4, width: 15.0, height: 12.2)
        let r: CGFloat = 4.6
        let bubble = NSBezierPath(roundedRect: b, xRadius: r, yRadius: r)
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: b.minX + 3.0, y: b.minY + 1.2))
        tail.line(to: NSPoint(x: b.minX + 1.1, y: b.minY - 2.1))
        tail.line(to: NSPoint(x: b.minX + 6.2, y: b.minY + 0.3))
        tail.close()
        bubble.append(tail)

        fill.setFill()
        bubble.fill()

        ctx.saveGState()
        ctx.setBlendMode(.clear)
        let cx = b.midX
        let cy = b.midY
        let sr: CGFloat = 3.8
        let pinch = sr * 0.22
        let star = NSBezierPath()
        star.move(to: NSPoint(x: cx, y: cy + sr))
        star.curve(to: NSPoint(x: cx + sr, y: cy),
                   controlPoint1: NSPoint(x: cx + pinch, y: cy + pinch),
                   controlPoint2: NSPoint(x: cx + pinch, y: cy + pinch))
        star.curve(to: NSPoint(x: cx, y: cy - sr),
                   controlPoint1: NSPoint(x: cx + pinch, y: cy - pinch),
                   controlPoint2: NSPoint(x: cx + pinch, y: cy - pinch))
        star.curve(to: NSPoint(x: cx - sr, y: cy),
                   controlPoint1: NSPoint(x: cx - pinch, y: cy - pinch),
                   controlPoint2: NSPoint(x: cx - pinch, y: cy - pinch))
        star.curve(to: NSPoint(x: cx, y: cy + sr),
                   controlPoint1: NSPoint(x: cx - pinch, y: cy + pinch),
                   controlPoint2: NSPoint(x: cx - pinch, y: cy + pinch))
        star.close()
        star.fill()
        ctx.restoreGState()
    }

    static func menuBarImage(unreadCount: Int = 0) -> NSImage {
        if unreadCount <= 0 {
            let size = NSSize(width: 18, height: 18)
            let img = NSImage(size: size, flipped: false) { rect in
                drawGlyph(in: rect, fill: .labelColor)
                return true
            }
            img.isTemplate = true
            return img
        }

        let badgeText = unreadCount > 99 ? "99+" : "\(unreadCount)"
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let textSize = (badgeText as NSString).size(withAttributes: attrs)
        let pillWidth = max(15, ceil(textSize.width) + 9)
        let pillHeight: CGFloat = 14
        let gap: CGFloat = 2
        let totalSize = NSSize(width: 18 + gap + pillWidth, height: 18)

        let img = NSImage(size: totalSize, flipped: false) { _ in
            drawGlyph(in: NSRect(x: 0, y: 0, width: 18, height: 18), fill: .labelColor)

            let pillRect = NSRect(x: 18 + gap, y: (18 - pillHeight) / 2, width: pillWidth, height: pillHeight)
            NSColor(srgbRed: 1.0, green: 0.231, blue: 0.188, alpha: 1.0).setFill()
            NSBezierPath(roundedRect: pillRect, xRadius: pillHeight / 2, yRadius: pillHeight / 2).fill()

            let drawPoint = NSPoint(
                x: pillRect.minX + (pillRect.width - textSize.width) / 2,
                y: pillRect.minY + (pillRect.height - textSize.height) / 2 - 0.5
            )
            (badgeText as NSString).draw(at: drawPoint, withAttributes: attrs)
            return true
        }
        img.isTemplate = false
        return img
    }
}

struct MenuBarPopoverView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Prefs.sidebar) private var sidebar = true
    @AppStorage(Prefs.bubble) private var bubble = true
    @AppStorage(Prefs.sendWithCommandReturn) private var sendWithCommandReturn = false
    var onClose: () -> Void = {}

    @State private var filter: ListFilter = .all
    @State private var selectedChat: ChatSummary?
    @State private var messages: [LensMessage] = []
    @State private var drafts: [String: String] = [:]
    @State private var sending = false
    @State private var sendSuccess = false
    @State private var sendError: String?
    @FocusState private var inputFocused: Bool

    enum ListFilter: Hashable { case all, unread }

    private var displayedChats: [ChatSummary] {
        switch filter {
        case .all: return model.menuBarChats
        case .unread: return model.menuBarChats.filter { model.effectiveUnread(for: $0) > 0 }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let chat = selectedChat {
                detailView(for: chat)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .opacity))
            } else {
                listView
                    .transition(.opacity)
            }
        }
        .frame(width: 390, height: 520)
        .background(DS.bg)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(DS.edge, lineWidth: 1)
        )
        .animation(DS.spring, value: selectedChat?.username)
        .onDisappear {
            sendError = nil
            sendSuccess = false
        }
    }

    // MARK: - List Mode

    private var listView: some View {
        VStack(spacing: 0) {
            listHeader
            Rectangle().fill(DS.edge).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(displayedChats) { c in
                        MenuBarChatRow(chat: c, unread: model.effectiveUnread(for: c)) {
                            sendError = nil
                            sendSuccess = false
                            model.markMenuBarRead(c.username)
                            withAnimation(DS.spring) { selectedChat = c }
                        }
                    }
                }
                .padding(8)
            }
            .overlay {
                if displayedChats.isEmpty {
                    EmptyHint(
                        title: filter == .unread ? "没有未读消息" : "暂无最近消息",
                        systemImage: filter == .unread ? "checkmark.circle" : "bubble.left.and.bubble.right",
                        detail: "已自动过滤免打扰与已折叠会话。"
                    )
                }
            }
            Rectangle().fill(DS.edge).frame(height: 1)
            listFooter
        }
    }

    private var listHeader: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                ThinkingOrb(size: 16, active: model.analyses.values.contains { $0.isLoading })
                Text("ChatMaster").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.chatTitle)
                if model.menuBarUnreadCount > 0 {
                    Text(model.menuBarUnreadCount > 99 ? "99+" : "\(model.menuBarUnreadCount)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(DS.error, in: Capsule())
                }
            }
            Spacer(minLength: 4)
            BSegmented(selection: $filter, options: [(.all, "全部"), (.unread, "未读")], compact: true)
            Button { model.syncNow() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(IconButtonStyle(size: 26))
                .help("立即同步")
            Button {
                onClose()
                model.showMainWindow()
            } label: { Image(systemName: "macwindow") }
                .buttonStyle(IconButtonStyle(size: 26))
                .help("打开主窗口")
            overflowMenu
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var overflowMenu: some View {
        Menu {
            Button("打开 ChatMaster") {
                onClose()
                model.showMainWindow()
            }
            Divider()
            Button("分析剪贴板文字  ⌃⌥V") {
                onClose()
                CompanionController.shared.analyzeClipboard()
            }
            Button("框选屏幕并分析  ⌃⌥A") {
                onClose()
                CompanionController.shared.captureAndAnalyze()
            }
            Divider()
            Toggle("微信吸附侧栏  ⌃⌥S", isOn: $sidebar)
            Toggle("复制即分析气泡", isOn: $bubble)
            Divider()
            Button("设置…") {
                onClose()
                WindowOpener.shared.openSettingsWindow()
            }
            Button("退出") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.ink3)
                .frame(width: 26, height: 26)
                .background(DS.wash, in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多操作")
    }

    private var listFooter: some View {
        HStack(spacing: 7) {
            PulseDot(color: model.syncErrors.isEmpty ? DS.ok : DS.warning, size: 5)
            if let t = model.lastSync {
                Text("同步于 \(Fmt.time.string(from: t)) · 已排除免打扰/折叠")
                    .font(DS.micro.monospacedDigit()).foregroundStyle(DS.ink4)
            } else {
                Text("正在同步…").font(DS.micro).foregroundStyle(DS.ink4)
            }
            Spacer()
            Text("\(displayedChats.count) 个会话")
                .font(DS.micro.monospacedDigit()).foregroundStyle(DS.ink5)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: - Detail / Direct Reply Mode

    private func draftBinding(for chat: String) -> Binding<String> {
        Binding(
            get: { drafts[chat] ?? "" },
            set: { drafts[chat] = $0 }
        )
    }

    private var lastIncomingTextMessage: LensMessage? {
        messages.last(where: { !$0.isSelf && $0.isTextual })
    }

    @ViewBuilder
    private func detailView(for chat: ChatSummary) -> some View {
        let username = chat.username
        let draft = draftBinding(for: username)
        let incoming = lastIncomingTextMessage
        let analysisState = incoming.flatMap { model.analysisState($0.id) }

        VStack(spacing: 0) {
            detailHeader(chat: chat, lastIncoming: incoming)
            Rectangle().fill(DS.edge).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(messages) { m in
                            MenuBarMessageBubble(message: m, isGroup: chat.kind == .group)
                                .id(m.id)
                        }
                    }
                    .padding(12)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: messages.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }

            if let state = analysisState {
                suggestionStrip(state: state, draft: draft)
            }

            if sendSuccess {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.ok)
                    Text("已发送到微信").font(DS.micro).foregroundStyle(DS.ink2)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(DS.ok.opacity(0.10))
            } else if let err = sendError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.warning)
                    Text(err).font(DS.micro).foregroundStyle(DS.ink2).lineLimit(2)
                    Spacer(minLength: 4)
                    if !(drafts[username] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("复制") {
                            copyText(drafts[username] ?? "")
                            ToastCenter.shared.show(.success, "已复制回复内容", duration: 2)
                        }
                        .buttonStyle(BButtonStyle(kind: .secondary, compact: true))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(DS.warning.opacity(0.12))
            }

            Rectangle().fill(DS.edge).frame(height: 1)
            composer(chat: chat, draft: draft)
        }
        .task(id: "\(username)|\(model.revision)") {
            reloadMessages(for: username)
        }
        .onAppear {
            NSApp.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                inputFocused = true
            }
        }
    }

    private func detailHeader(chat: ChatSummary, lastIncoming: LensMessage?) -> some View {
        HStack(spacing: 8) {
            Button {
                sendError = nil
                sendSuccess = false
                withAnimation(DS.spring) { selectedChat = nil }
            } label: { Image(systemName: "chevron.left") }
                .buttonStyle(IconButtonStyle(size: 26))
                .help("返回会话列表")

            AvatarView(username: chat.username, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(chat.display).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.chatTitle).lineLimit(1)
                Text(chat.kind == .group ? "群聊" : "私聊")
                    .font(DS.micro).foregroundStyle(DS.ink5)
            }
            Spacer(minLength: 4)
            if let lastIncoming {
                Button { model.analyze(lastIncoming) } label: { Image(systemName: "sparkles") }
                    .buttonStyle(IconButtonStyle(size: 26))
                    .help("分析对方最新消息并生成回复建议")
            }
            Button {
                onClose()
                model.openChat(chat.username)
            } label: { Image(systemName: "arrow.up.right") }
                .buttonStyle(IconButtonStyle(size: 26))
                .help("在 ChatMaster 中打开")
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
    }

    @ViewBuilder
    private func suggestionStrip(state: AnalysisState, draft: Binding<String>) -> some View {
        switch state {
        case .loading:
            HStack(spacing: 6) {
                ThinkingOrb(size: 12)
                Text("生成回复建议…").font(DS.micro).foregroundStyle(DS.ink4)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(DS.wash)
        case .done(let a) where !a.replySuggestions.isEmpty:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(a.replySuggestions, id: \.self) { s in
                        Button {
                            draft.wrappedValue = s.text
                            inputFocused = true
                        } label: {
                            HStack(spacing: 4) {
                                Text(s.style).font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.pick)
                                Text(s.text).font(DS.micro).foregroundStyle(DS.ink2).lineLimit(1)
                            }
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(DS.card, in: Capsule())
                            .overlay(Capsule().strokeBorder(DS.edge, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("填入回复框：\(s.text)")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
            }
            .background(DS.wash)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func composer(chat: ChatSummary, draft: Binding<String>) -> some View {
        let trimmed = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSend = !trimmed.isEmpty && !sending

        HStack(alignment: .bottom, spacing: 8) {
            Group {
                if sendWithCommandReturn {
                    TextField("回复 \(chat.display)… (⌘↩ 发送)", text: draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .lineLimit(1...4)
                        .focused($inputFocused)
                } else {
                    TextField("回复 \(chat.display)… (↩ 发送)", text: draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .lineLimit(1...4)
                        .focused($inputFocused)
                        .onSubmit { sendReply(for: chat) }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(DS.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(inputFocused ? DS.pick.opacity(0.6) : DS.edge, lineWidth: 1))

            Button {
                sendReply(for: chat)
            } label: {
                if sending {
                    ProgressView().controlSize(.small).frame(width: 28, height: 28)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(canSend ? DS.ink : DS.ink5.opacity(0.45))
                }
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .help(sendWithCommandReturn ? "发送 (⌘↩)" : "发送 (↩ 或 ⌘↩)")
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(DS.sidebar)
    }

    private func reloadMessages(for chat: String) {
        guard let store = model.store else { messages = []; return }
        let fresh = store.messages(chat: chat, limit: 16).filter { !($0.isSystem && $0.subType == 0 && $0.text.count > 60) }
        if fresh.map(\.id) != messages.map(\.id) || fresh.map(\.recalledAt) != messages.map(\.recalledAt) {
            messages = fresh
        }
    }

    private func sendReply(for chat: ChatSummary) {
        let username = chat.username
        let text = (drafts[username] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        sendError = nil
        sendSuccess = false
        let contact = model.store?.contact(username)
        let chats = model.chats
        let cmdReturn = sendWithCommandReturn

        Task {
            do {
                try await WeChatReplyService.send(
                    text: text,
                    to: username,
                    contact: contact,
                    fallbackDisplay: chat.display,
                    chats: chats,
                    useCommandReturn: cmdReturn
                )
                drafts[username] = ""
                sending = false
                sendSuccess = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { sendSuccess = false }
            } catch {
                sending = false
                sendError = error.localizedDescription
            }
        }
    }
}

private struct MenuBarChatRow: View {
    var chat: ChatSummary
    var unread: Int
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    AvatarView(username: chat.username, size: 36)
                    if chat.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 7.5))
                            .foregroundStyle(DS.onSlab)
                            .padding(2.5)
                            .background(DS.ink3, in: Circle())
                            .offset(x: 3, y: -3)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(chat.display)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.chatTitle)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(DateFmt.compactList(Date(timeIntervalSince1970: TimeInterval(chat.lastTs))))
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(DS.ink5)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    HStack(spacing: 6) {
                        Text(chat.lastText.isEmpty ? "…" : chat.lastText)
                            .font(.system(size: 12))
                            .foregroundStyle(DS.ink4)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if unread > 0 {
                            Text(unread > 99 ? "99+" : "\(unread)")
                                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5.5).padding(.vertical, 1)
                                .background(DS.error, in: Capsule())
                        } else if hover {
                            Image(systemName: "arrowshape.turn.up.left.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(DS.ink4)
                        }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(hover ? DS.wash : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(DS.ease, value: hover)
    }
}

private struct MenuBarMessageBubble: View {
    @EnvironmentObject var model: AppModel
    var message: LensMessage
    var isGroup: Bool

    var body: some View {
        if message.isSystem {
            Text(message.text)
                .font(DS.micro)
                .foregroundStyle(DS.ink5)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
        } else {
            HStack(alignment: .top, spacing: 6) {
                if message.isSelf { Spacer(minLength: 44) }
                VStack(alignment: message.isSelf ? .trailing : .leading, spacing: 2) {
                    if isGroup && !message.isSelf {
                        Text(model.senderLabel(message)).font(.system(size: 10.5)).foregroundStyle(DS.ink5)
                    }
                    if message.isRecalled {
                        RecallChip(message: message)
                    }
                    Text(message.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(message.isSelf ? DS.onSlab : (message.isTextual ? DS.ink : DS.ink4))
                        .textSelection(.enabled)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(message.isSelf ? DS.slab : DS.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(message.isRecalled ? DS.warning : (message.isSelf ? .clear : DS.edge),
                                              lineWidth: message.isRecalled ? 1.2 : 1)
                        )
                }
                if !message.isSelf { Spacer(minLength: 44) }
            }
        }
    }
}
