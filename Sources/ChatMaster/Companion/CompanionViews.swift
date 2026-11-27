import LensCore
import MudsUI
import SwiftUI

struct BubbleView: View {
    var action: () -> Void
    @State private var appear = false
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                ThinkingOrb(size: 14, active: hover)
                Text("分析").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(DS.onSlab)
            .padding(.horizontal, 13).frame(height: 32)
            .background(DS.slab, in: Capsule())
            .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
            .scaleEffect(appear ? (hover ? 1.05 : 1) : 0.5)
            .opacity(appear ? 1 : 0)
        }
        .buttonStyle(.plain)
        .frame(width: 118, height: 40)
        .onHover { hover = $0 }
        .animation(DS.bouncy, value: hover)
        .onAppear { withAnimation(DS.bouncy) { appear = true } }
        .help("分析刚复制的消息")
    }
}

struct PopupAnalysisView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var popup: PopupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: popup.source == .ocr ? "text.viewfinder" : "doc.on.clipboard")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.ink4)
                Text(popup.source == .ocr ? "截图识别的消息" : "复制的消息").font(DS.title).foregroundStyle(DS.ink)
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 32).padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    matchInfo
                    Group {
                        if popup.source == .ocr {
                            TextEditor(text: $popup.text).font(DS.body).frame(minHeight: 60, maxHeight: 120)
                                .scrollContentBackground(.hidden)
                        } else {
                            Text(popup.text).font(.system(size: 14)).lineLimit(8).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                    .background(DS.wash, in: RoundedRectangle(cornerRadius: DS.innerRadius, style: .continuous))

                    switch popup.state {
                    case .idle: EmptyView()
                    case .loading(let since): AnalyzingView(since: since, label: "agy 正在分析…")
                    case .failed(let e):
                        VStack(alignment: .leading, spacing: 6) {
                            Label("分析失败", systemImage: "xmark.octagon.fill").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.error)
                            Text(e).font(DS.sub).foregroundStyle(DS.ink4).textSelection(.enabled)
                        }
                    case .done(let a): MessageAnalysisCard(analysis: a, compact: true).transition(.opacity)
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 14)
            }

            Rectangle().fill(DS.edge).frame(height: 1)
            HStack {
                Button { popup.run(force: true) } label: { Label("重新分析", systemImage: "arrow.clockwise") }
                    .buttonStyle(BButtonStyle(kind: .ghost, compact: true))
                Spacer()
                if let m = popup.matched {
                    Button {
                        model.openChat(m.chat)
                        model.inspect(m, analyze: false)
                    } label: { Label("在 ChatMaster 中查看", systemImage: "arrow.up.right") }
                        .buttonStyle(BButtonStyle(kind: .secondary, compact: true))
                }
            }
            .padding(12)
        }
        .background(DS.card)
    }

    @ViewBuilder private var matchInfo: some View {
        if let m = popup.matched {
            HStack(spacing: 8) {
                AvatarView(username: m.isSelf ? (model.store?.selfUsername ?? "") : (m.sender ?? m.chat), size: 22)
                Text("\(model.senderLabel(m)) · \(model.displayName(m.chat)) · \(Fmt.smart(m.date))")
                    .font(DS.sub).foregroundStyle(DS.ink4).lineLimit(1)
                Spacer()
                Chip(text: "已匹配原消息", color: DS.ok)
            }
        } else if let chat = popup.chatHint {
            Chip(text: "未匹配原消息 · 参考「\(model.displayName(chat))」的最近对话", color: DS.warning)
        } else {
            Chip(text: "未匹配原消息 · 按纯文本分析", color: DS.warning)
        }
    }
}

/// Docked panel next to the WeChat window.
struct CompanionSidebarView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var companion: CompanionController
    @State private var messages: [LensMessage] = []
    @State private var expanded: Set<Int64> = []
    @State private var conv: ConvState = .idle
    @State private var showConv = false

    enum ConvState { case idle, loading(Date), done(ConversationAnalysis), failed(String) }

    var body: some View {
        Group {
            if companion.collapsed { collapsedBar } else { full }
        }
        .background(DS.card, in: RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).strokeBorder(DS.edge, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
        .task(id: "\(companion.currentChat ?? "-")|\(model.revision)") { reload() }
        .onChange(of: companion.currentChat) { _, _ in conv = .idle; showConv = false; expanded = [] }
        .animation(DS.spring, value: companion.currentChat)
    }

    private var collapsedBar: some View {
        VStack(spacing: 14) {
            Button { companion.collapsed = false } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(IconButtonStyle()).help("展开")
            if let chat = companion.currentChat { AvatarView(username: chat, size: 28) }
            if let s = moodScore { Text(moodEmoji(s)).font(.title3).help("对方情绪：\(Sentiment.label(s))") }
            Spacer()
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }

    private var full: some View {
        VStack(spacing: 0) {
            header
            if companion.followWeChat && !companion.ocrAvailable {
                Button { companion.requestScreenRecording() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.dashed.badge.record")
                        Text("授予「屏幕录制」后可实时跟随切换会话").lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .font(DS.micro).foregroundStyle(DS.warning)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(DS.warning.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            if companion.currentChat != nil {
                moodStrip
                actions
                if showConv { convPanel }
                Rectangle().fill(DS.edge).frame(height: 1)
                list
                Rectangle().fill(DS.edge).frame(height: 1)
                footer
            } else {
                EmptyHint(title: "没有识别到当前会话", systemImage: "questionmark.bubble",
                          detail: "在微信里打开一个会话或发一条消息，或从上方菜单选择。")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let chat = companion.currentChat { AvatarView(username: chat, size: 30) }
            VStack(alignment: .leading, spacing: 2) {
                Menu {
                    Button { companion.pin(nil) } label: {
                        Label("跟随微信当前会话", systemImage: companion.followWeChat ? "checkmark" : "scope")
                    }
                    Divider()
                    ForEach(model.chats.prefix(20)) { c in Button(c.display) { companion.pin(c.username) } }
                } label: {
                    Text(companion.currentChat.map { model.displayName($0) } ?? "选择会话")
                        .font(DS.title).foregroundStyle(Theme.chatTitle).lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 200, alignment: .leading)
                HStack(spacing: 4) {
                    Circle().fill(companion.followWeChat ? DS.ok : DS.ink5).frame(width: 5, height: 5)
                    Text(companion.followWeChat ? (companion.ocrAvailable ? "跟随微信 · OCR" : "跟随微信 · 打开/发送") : "已固定")
                        .font(DS.micro).foregroundStyle(DS.ink4).lineLimit(1).fixedSize()
                }
            }
            Spacer(minLength: 4)
            Button { model.showMainWindow(); if let c = companion.currentChat { model.openChat(c) } } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(IconButtonStyle()).help("在 ChatMaster 中打开")
            Button { companion.collapsed = true } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(IconButtonStyle()).help("收起")
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
    }

    private var others: [LensMessage] { messages.filter { !$0.isSelf && $0.isTextual } }

    private var moodScore: Double? {
        let v = others.suffix(20).compactMap(\.sentiment)
        guard !v.isEmpty else { return nil }
        return v.reduce(0, +) / Double(v.count)
    }

    private func moodEmoji(_ s: Double) -> String {
        switch s {
        case 0.35...: return "😄"
        case 0.1..<0.35: return "🙂"
        case -0.1..<0.1: return "😐"
        case -0.35 ..< -0.1: return "😕"
        default: return "😣"
        }
    }

    private var moodStrip: some View {
        HStack(spacing: 10) {
            if let s = moodScore {
                Text(moodEmoji(s)).font(.system(size: 20))
                    .frame(width: 36, height: 36).background(Theme.valence(s).opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 5) {
                    Text("对方近期情绪 · \(Sentiment.label(s))").font(.system(size: 12, weight: .medium)).foregroundStyle(DS.ink2)
                    HStack(spacing: 2) {
                        ForEach(others.suffix(24)) { m in
                            Capsule().fill(Theme.valence(m.sentiment)).frame(width: 5, height: 12)
                        }
                    }
                }
            } else {
                Text("对方最近没有文字消息").font(DS.sub).foregroundStyle(DS.ink5)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button { runConversation(force: false) } label: { Label("总结 · 怎么回", systemImage: "sparkles") }
                .buttonStyle(BButtonStyle(kind: .primary, compact: true))
            Button {
                if let m = others.last { model.analyze(m); withAnimation(DS.spring) { _ = expanded.insert(m.id) } }
            } label: { Label("分析最后一条", systemImage: "text.bubble") }
                .buttonStyle(BButtonStyle(kind: .secondary, compact: true))
                .disabled(others.isEmpty)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
    }

    private var convPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Caption(title: "对话总结", icon: "text.badge.star")
                    Spacer()
                    Button { runConversation(force: true) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(IconButtonStyle(size: 22))
                    Button { withAnimation(DS.spring) { showConv = false } } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 22))
                }
                switch conv {
                case .idle: EmptyView()
                case .loading(let since): AnalyzingView(since: since, label: "agy 正在阅读最近 40 条…")
                case .failed(let e): Text(e).font(DS.sub).foregroundStyle(DS.error)
                case .done(let a): ConversationAnalysisCard(analysis: a)
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 340)
        .background(DS.wash)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(messages) { m in
                        CompanionMessageRow(message: m, expanded: expanded.contains(m.id)) {
                            withAnimation(DS.spring) {
                                if expanded.contains(m.id) { expanded.remove(m.id) } else { expanded.insert(m.id); model.analyze(m) }
                            }
                        }
                        .id(m.id)
                    }
                }
                .padding(10)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.last?.id) { _, id in if let id { withAnimation(DS.spring) { proxy.scrollTo(id, anchor: .bottom) } } }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let chat = companion.currentChat {
                Toggle(isOn: Binding(get: { model.watchlist.contains(chat) }, set: { model.setWatched(chat, $0) })) {
                    Text("新消息自动分析").font(.system(size: 12, weight: .medium)).foregroundStyle(DS.ink2)
                }
                .toggleStyle(LiquidToggleStyle(compact: true))
                .frame(width: 150)
            }
            Spacer()
            Text("⌃⌥A 截图分析").font(DS.micro).foregroundStyle(DS.ink5)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func reload() {
        guard let store = model.store, let chat = companion.currentChat else { messages = []; return }
        let fresh = store.messages(chat: chat, limit: 40).filter { !($0.isSystem && $0.subType == 0 && $0.text.count > 60) }
        if fresh.map(\.id) != messages.map(\.id) || fresh.map(\.recalledAt) != messages.map(\.recalledAt) { messages = fresh }
        if model.watchlist.contains(chat), let last = fresh.last(where: { !$0.isSelf && $0.isTextual }), model.analyses[last.id] != nil {
            expanded.insert(last.id)
        }
    }

    private func runConversation(force: Bool) {
        guard let engine = model.engine, let chat = companion.currentChat else { return }
        withAnimation(DS.spring) { showConv = true }
        if !force, case .done = conv { return }
        conv = .loading(Date())
        Task {
            do { conv = .done(try await engine.analyzeConversation(chat: chat, limit: 40, force: force)) }
            catch { conv = .failed(error.localizedDescription) }
        }
    }
}

struct CompanionMessageRow: View {
    @EnvironmentObject var model: AppModel
    var message: LensMessage
    var expanded: Bool
    var toggle: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(message.isSelf ? "我" : model.senderLabel(message)).font(DS.micro)
                            .foregroundStyle(message.isSelf ? DS.ink : DS.ink4).lineLimit(1)
                        Text(Fmt.time.string(from: message.date)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(DS.ink5)
                        if message.isRecalled { RecallChip(message: message) }
                    }
                    Text(message.text).font(DS.body).lineLimit(expanded ? nil : 3)
                        .foregroundStyle(message.isTextual ? DS.ink : DS.ink5)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 4)
                if message.isTextual {
                    Button(action: toggle) {
                        Group {
                            if let a = model.analysisState(message.id)?.result {
                                Text(a.emoji).font(.system(size: 15))
                            } else if model.analysisState(message.id)?.isLoading == true {
                                ThinkingOrb(size: 16)
                            } else {
                                Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(hover ? DS.ink : DS.ink5)
                            }
                        }
                        .frame(width: 26, height: 26)
                        .background(hover ? DS.wash2 : .clear, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(expanded ? "收起" : "分析情绪与意图")
                }
            }
            if expanded {
                MessageAnalysisSlot(message: message, compact: true)
                    .padding(12)
                    .background(DS.card, in: RoundedRectangle(cornerRadius: DS.innerRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DS.innerRadius, style: .continuous).strokeBorder(DS.edge, lineWidth: 1))
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .padding(10)
        .background(message.isSelf ? DS.wash2 : DS.wash, in: RoundedRectangle(cornerRadius: DS.innerRadius, style: .continuous))
        .onHover { hover = $0 }
        .animation(DS.ease, value: hover)
    }
}
