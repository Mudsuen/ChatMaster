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
    @AppStorage(Prefs.sendWithCommandReturn) private var sendWithCommandReturn = false

    @State private var messages: [LensMessage] = []
    @State private var expanded: Set<Int64> = []
    @State private var hoveredMoodID: Int64?
    @State private var scrollTargetID: Int64?

    // Group mode state
    @State private var selectedMember: String?

    // Unified collapsible AI drawer
    @State private var drawer: DrawerState = .none
    @State private var showDrawer = false

    // Bottom quick-reply composer
    @State private var drafts: [String: String] = [:]
    @State private var quickReplyState: QuickReplyState = .idle
    @State private var sending = false
    @State private var sendSuccess = false
    @State private var sendError: String?
    @FocusState private var replyFocused: Bool

    enum DrawerState {
        case none
        case convLoading(Date), convDone(ConversationAnalysis), convFailed(String)
        case groupLoading(Date), groupDone(GroupAnalysis), groupFailed(String)
        case memberLoading(String, Date), memberDone(String, GroupMemberAnalysis), memberFailed(String, String)

        var title: String {
            switch self {
            case .none: return ""
            case .convLoading, .convDone, .convFailed: return "AI 对话分析"
            case .groupLoading, .groupDone, .groupFailed: return "群聊分析 · 分人洞察"
            case .memberLoading, .memberDone, .memberFailed: return "成员分析"
            }
        }
    }

    enum QuickReplyState {
        case idle
        case loading(Date)
        case ready([ReplySuggestion])
        case failed(String)
    }

    private struct GroupMemberStat: Identifiable {
        var id: String { username }
        var username: String
        var display: String
        var count: Int
        var avgSentiment: Double?
    }

    private var isGroup: Bool {
        companion.currentChat?.hasSuffix("@chatroom") == true
    }

    private var activeMembers: [GroupMemberStat] {
        guard isGroup else { return [] }
        var counts: [String: Int] = [:]
        var scores: [String: [Double]] = [:]
        for m in messages where !m.isSelf && !m.isSystem {
            guard let s = m.sender, !s.isEmpty else { continue }
            counts[s, default: 0] += 1
            if let v = m.sentiment { scores[s, default: []].append(v) }
        }
        return counts
            .sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }
            .prefix(12)
            .map { u, c in
                let arr = scores[u] ?? []
                let avg = arr.isEmpty ? nil : arr.reduce(0, +) / Double(arr.count)
                return GroupMemberStat(username: u, display: model.displayName(u), count: c, avgSentiment: avg)
            }
    }

    private var displayedMessages: [LensMessage] {
        guard isGroup, let selectedMember else { return messages }
        return messages.filter { $0.sender == selectedMember }
    }

    private var hoveredMoodMsg: LensMessage? {
        guard let hoveredMoodID else { return nil }
        return others.first { $0.id == hoveredMoodID }
    }

    var body: some View {
        Group {
            if companion.collapsed { collapsedBar } else { full }
        }
        .background(DS.card, in: RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).strokeBorder(DS.edge, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: DS.radius, style: .continuous))
        .task(id: "\(companion.currentChat ?? "-")|\(model.revision)") { reload() }
        .onChange(of: companion.currentChat) { _, _ in
            drawer = .none
            showDrawer = false
            selectedMember = nil
            hoveredMoodID = nil
            quickReplyState = .idle
            sendSuccess = false
            sendError = nil
            expanded = []
        }
        .animation(DS.spring, value: companion.currentChat)
    }

    private var collapsedBar: some View {
        VStack(spacing: 14) {
            Button { companion.collapsed = false } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(IconButtonStyle()).help("展开")
            if let chat = companion.currentChat { AvatarView(username: chat, size: 28) }
            if isGroup {
                Image(systemName: "person.2")
                    .font(.system(size: 14))
                    .foregroundStyle(DS.ink3)
                    .help("群聊分析")
            } else if let s = moodScore {
                Text(moodEmoji(s)).font(.title3).help("对方情绪：\(Sentiment.label(s))")
            }
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
            if let chat = companion.currentChat {
                if isGroup {
                    groupAnalysisStrip(chat: chat)
                } else {
                    privateMoodStrip
                }
                if showDrawer { analysisDrawer(chat: chat) }
                Rectangle().fill(DS.edge).frame(height: 1)
                list
                Rectangle().fill(DS.edge).frame(height: 1)
                replyBar(chat: chat)
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
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
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

    // MARK: - Private Chat Mood Strip (Hoverable + AI Button + Watch Toggle)

    private var privateMoodStrip: some View {
        let recents = Array(others.suffix(24))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let s = moodScore {
                    let focus = hoveredMoodMsg
                    let emoji = focus.flatMap { $0.sentiment.map(moodEmoji) } ?? moodEmoji(s)
                    let tone = focus?.sentiment ?? s
                    Text(emoji)
                        .font(.system(size: 18))
                        .frame(width: 32, height: 32)
                        .background(Theme.valence(tone).opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(focus.map { "\(Sentiment.label($0.sentiment)) · \(Fmt.time.string(from: $0.date))" }
                             ?? "情绪 · \(Sentiment.label(s))")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(focus != nil ? Theme.valence(focus?.sentiment) : DS.ink2)
                            .lineLimit(1)
                        HStack(alignment: .center, spacing: 2) {
                            ForEach(recents) { m in
                                let isHot = hoveredMoodID == m.id
                                Capsule()
                                    .fill(Theme.valence(m.sentiment))
                                    .frame(width: 5.5, height: isHot ? 16 : 11)
                                    .opacity(hoveredMoodID == nil || isHot ? 1 : 0.35)
                                    .contentShape(Rectangle().inset(by: -2))
                                    .onHover { inside in
                                        hoveredMoodID = inside ? m.id : (hoveredMoodID == m.id ? nil : hoveredMoodID)
                                    }
                                    .onTapGesture {
                                        scrollTargetID = m.id
                                        withAnimation(DS.spring) {
                                            expanded.insert(m.id)
                                            model.analyze(m)
                                        }
                                    }
                            }
                        }
                        .frame(height: 16)
                        .animation(DS.ease, value: hoveredMoodID)
                    }
                } else {
                    Text("对方最近没有文字消息").font(DS.sub).foregroundStyle(DS.ink5)
                }

                Spacer(minLength: 4)

                Button { runConversation(force: false) } label: {
                    Label("AI 分析", systemImage: "sparkles")
                }
                .buttonStyle(BButtonStyle(kind: showDrawer ? .primary : .secondary, compact: true))
                .fixedSize()
                .help("AI 总结最近对话并给出回复建议")

                watchStarButton
            }

            if let hm = hoveredMoodMsg {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.valence(hm.sentiment))
                        .frame(width: 5, height: 5)
                    Text(hm.text)
                        .font(DS.micro)
                        .foregroundStyle(DS.ink2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text("点击查看")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.ink5)
                        .fixedSize()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(DS.wash, in: Capsule())
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Group Chat Strip (Member Filter + Group / Per-Member AI Analysis)

    private func groupAnalysisStrip(chat: String) -> some View {
        let members = activeMembers
        let selectedStat = selectedMember.flatMap { id in members.first { $0.username == id } }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(members.isEmpty ? "暂无发言记录" : "近期 \(members.count) 人发言 · \(messages.count) 条")
                    .font(DS.sub)
                    .foregroundStyle(DS.ink4)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button { runGroupAnalysis(force: false) } label: {
                    Label("群聊分析", systemImage: "sparkles")
                }
                .buttonStyle(BButtonStyle(kind: showDrawer && !isMemberDrawer ? .primary : .secondary, compact: true))
                .fixedSize()
                .help("AI 总结群聊主线与分人观点")

                watchStarButton
            }

            if !members.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        Button {
                            withAnimation(DS.ease) { selectedMember = nil }
                        } label: {
                            Text("全部")
                                .font(.system(size: 11, weight: selectedMember == nil ? .semibold : .medium))
                                .foregroundStyle(selectedMember == nil ? DS.onSlab : DS.ink3)
                                .padding(.horizontal, 9)
                                .frame(height: 24)
                                .background(selectedMember == nil ? DS.slab : DS.wash, in: Capsule())
                        }
                        .buttonStyle(.plain)

                        ForEach(members) { m in
                            let on = selectedMember == m.username
                            Button {
                                withAnimation(DS.ease) {
                                    selectedMember = on ? nil : m.username
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    AvatarView(username: m.username, size: 15)
                                    Text(m.display)
                                        .font(.system(size: 11, weight: on ? .semibold : .medium))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .frame(maxWidth: 74)
                                    Text("\(m.count)")
                                        .font(.system(size: 10).monospacedDigit())
                                        .opacity(0.75)
                                    Circle()
                                        .fill(Theme.valence(m.avgSentiment))
                                        .frame(width: 4.5, height: 4.5)
                                }
                                .foregroundStyle(on ? DS.onSlab : DS.ink2)
                                .padding(.horizontal, 7)
                                .frame(height: 24)
                                .background(on ? DS.slab : DS.wash, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("只看「\(m.display)」发言（\(m.count) 条）")
                        }
                    }
                }
            }

            if let stat = selectedStat {
                HStack(spacing: 6) {
                    AvatarView(username: stat.username, size: 18)
                    Text("\(stat.display) · \(stat.count) 条 · \(Sentiment.label(stat.avgSentiment))")
                        .font(DS.micro)
                        .foregroundStyle(DS.ink2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Button {
                        runGroupMemberAnalysis(member: stat.username, force: false)
                    } label: {
                        Label("分析 TA", systemImage: "sparkles")
                    }
                    .buttonStyle(BButtonStyle(kind: .secondary, compact: true))
                    .fixedSize()

                    Button {
                        withAnimation(DS.ease) { selectedMember = nil }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DS.ink4)
                    }
                    .buttonStyle(IconButtonStyle(size: 20))
                    .help("显示全部群成员消息")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(DS.wash, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var watchStarButton: some View {
        if let chat = companion.currentChat {
            let watched = model.watchlist.contains(chat)
            Button {
                model.setWatched(chat, !watched)
            } label: {
                Image(systemName: watched ? "star.fill" : "star")
                    .foregroundStyle(watched ? DS.warning : DS.ink4)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(IconButtonStyle(size: 26))
            .help(watched ? "取消自动分析新消息" : "关注：新消息自动分析")
        }
    }

    private var isMemberDrawer: Bool {
        switch drawer {
        case .memberLoading, .memberDone, .memberFailed: return true
        default: return false
        }
    }

    // MARK: - Unified Collapsible AI Analysis Drawer

    private func analysisDrawer(chat: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Caption(title: drawer.title, icon: "sparkles")
                    Spacer()
                    Button { refreshCurrentDrawer() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(IconButtonStyle(size: 22))
                        .help("重新分析")
                    Button { withAnimation(DS.spring) { showDrawer = false } } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 22))
                        .help("收起")
                }

                switch drawer {
                case .none:
                    EmptyView()
                case .convLoading(let since):
                    AnalyzingView(since: since, label: "agy 正在阅读最近 60 条…")
                case .convFailed(let e):
                    Text(e).font(DS.sub).foregroundStyle(DS.error).textSelection(.enabled)
                case .convDone(let a):
                    ConversationAnalysisCard(analysis: a) { text in
                        fillReply(text, for: chat)
                    }

                case .groupLoading(let since):
                    AnalyzingView(since: since, label: "agy 正在梳理群聊发言与观点…")
                case .groupFailed(let e):
                    Text(e).font(DS.sub).foregroundStyle(DS.error).textSelection(.enabled)
                case .groupDone(let g):
                    GroupAnalysisCard(
                        analysis: g,
                        onSelectMemberName: { name in
                            if let matched = activeMembers.first(where: { $0.display == name || $0.display.localizedCaseInsensitiveContains(name) }) {
                                withAnimation(DS.ease) { selectedMember = matched.username }
                                runGroupMemberAnalysis(member: matched.username, force: false)
                            }
                        },
                        onFillReply: { text in
                            fillReply(text, for: chat)
                        }
                    )

                case .memberLoading(let member, let since):
                    AnalyzingView(since: since, label: "agy 正在分析「\(model.displayName(member))」的发言…")
                case .memberFailed(_, let e):
                    Text(e).font(DS.sub).foregroundStyle(DS.error).textSelection(.enabled)
                case .memberDone(_, let m):
                    GroupMemberAnalysisCard(analysis: m) { text in
                        fillReply(text, for: chat)
                    }
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 330)
        .background(DS.wash)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Message List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(displayedMessages) { m in
                        CompanionMessageRow(
                            message: m,
                            expanded: expanded.contains(m.id),
                            toggle: {
                                withAnimation(DS.spring) {
                                    if expanded.contains(m.id) { expanded.remove(m.id) } else { expanded.insert(m.id); model.analyze(m) }
                                }
                            },
                            onFillReply: { text in
                                if let chat = companion.currentChat { fillReply(text, for: chat) }
                            }
                        )
                        .id(m.id)
                    }
                }
                .padding(10)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: displayedMessages.last?.id) { _, id in
                if scrollTargetID == nil, let id {
                    withAnimation(DS.spring) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            .onChange(of: scrollTargetID) { _, id in
                guard let id else { return }
                withAnimation(DS.ease) { proxy.scrollTo(id, anchor: .center) }
                scrollTargetID = nil
            }
        }
    }

    // MARK: - Bottom AI Quick-Reply Bar

    @ViewBuilder
    private func replyBar(chat: String) -> some View {
        let draft = Binding<String>(
            get: { drafts[chat] ?? "" },
            set: { drafts[chat] = $0 }
        )
        let trimmed = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSend = !trimmed.isEmpty && !sending
        let targetName: String = {
            let raw = (isGroup ? selectedMember.map { model.displayName($0) } : nil) ?? model.displayName(chat)
            return raw.count > 8 ? String(raw.prefix(8)) + "…" : raw
        }()

        VStack(spacing: 0) {
            quickReplyStrip(draft: draft)

            if sendSuccess {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.ok)
                    Text("已发送到微信").font(DS.micro).foregroundStyle(DS.ink2)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(DS.ok.opacity(0.10))
            } else if let err = sendError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.warning)
                    Text(err).font(DS.micro).foregroundStyle(DS.ink2).lineLimit(2)
                    Spacer(minLength: 4)
                    if !trimmed.isEmpty {
                        Button("复制") {
                            copyText(trimmed)
                            ToastCenter.shared.show(.success, "已复制回复内容", duration: 2)
                        }
                        .buttonStyle(BButtonStyle(kind: .secondary, compact: true))
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(DS.warning.opacity(0.12))
            }

            HStack(alignment: .bottom, spacing: 6) {
                let loadingReply: Bool = { if case .loading = quickReplyState { return true }; return false }()
                let hasReady: Bool = { if case .ready = quickReplyState { return true }; return false }()

                Button {
                    generateQuickReplies(chat: chat, force: hasReady)
                } label: {
                    Group {
                        if loadingReply {
                            ThinkingOrb(size: 14)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(hasReady ? DS.pick : DS.ink3)
                        }
                    }
                    .frame(width: 28, height: 28)
                    .background(hasReady ? DS.pick.opacity(0.14) : DS.wash, in: Circle())
                    .overlay(Circle().strokeBorder(hasReady ? DS.pick.opacity(0.45) : DS.edge, lineWidth: 0.75))
                }
                .buttonStyle(.plain)
                .disabled(loadingReply)
                .help("AI 一键生成建议回复并填入")

                Group {
                    if sendWithCommandReturn {
                        TextField("回复 \(targetName)… (⌘↩)", text: draft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .lineLimit(1...4)
                            .focused($replyFocused)
                    } else {
                        TextField("回复 \(targetName)… (↩)", text: draft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .lineLimit(1...4)
                            .focused($replyFocused)
                            .onSubmit { sendReply(chat: chat) }
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(DS.bg, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(replyFocused ? DS.pick.opacity(0.6) : DS.edge, lineWidth: 1))

                Button {
                    sendReply(chat: chat)
                } label: {
                    if sending {
                        ProgressView().controlSize(.small).frame(width: 26, height: 26)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(canSend ? DS.ink : DS.ink5.opacity(0.45))
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help(sendWithCommandReturn ? "发送 (⌘↩)" : "发送 (↩ 发送)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(DS.sidebar)
        }
    }

    @ViewBuilder
    private func quickReplyStrip(draft: Binding<String>) -> some View {
        switch quickReplyState {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 6) {
                ThinkingOrb(size: 11)
                Text("AI 正在生成建议回复…").font(DS.micro).foregroundStyle(DS.ink4)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(DS.wash)
        case .failed(let e):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(DS.warning)
                Text(e).font(DS.micro).foregroundStyle(DS.ink4).lineLimit(1)
                Spacer()
                Button { quickReplyState = .idle } label: { Image(systemName: "xmark").font(.system(size: 9.5)) }
                    .buttonStyle(.plain).foregroundStyle(DS.ink5)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(DS.wash)
        case .ready(let list):
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(list, id: \.self) { s in
                            Button {
                                draft.wrappedValue = s.text
                                replyFocused = true
                            } label: {
                                HStack(spacing: 4) {
                                    Text(s.style)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(DS.pick)
                                    Text(s.text)
                                        .font(DS.micro)
                                        .foregroundStyle(DS.ink2)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(DS.card, in: Capsule())
                                .overlay(Capsule().strokeBorder(DS.edge, lineWidth: 0.75))
                            }
                            .buttonStyle(.plain)
                            .help("点击填入：\(s.text)")
                        }
                    }
                    .padding(.vertical, 5)
                }
                Button {
                    withAnimation(DS.ease) { quickReplyState = .idle }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(DS.ink5)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .background(DS.wash)
        }
    }

    // MARK: - Actions & Data Loading

    private func fillReply(_ text: String, for chat: String) {
        drafts[chat] = text
        replyFocused = true
    }

    private func reload() {
        guard let store = model.store, let chat = companion.currentChat else { messages = []; return }
        let fresh = store.messages(chat: chat, limit: 60).filter { !($0.isSystem && $0.subType == 0 && $0.text.count > 60) }
        if fresh.map(\.id) != messages.map(\.id) || fresh.map(\.recalledAt) != messages.map(\.recalledAt) { messages = fresh }
        if model.watchlist.contains(chat), let last = fresh.last(where: { !$0.isSelf && $0.isTextual }), model.analyses[last.id] != nil {
            expanded.insert(last.id)
        }
    }

    private func runConversation(force: Bool) {
        guard let engine = model.engine, let chat = companion.currentChat else { return }
        if !force, showDrawer, case .convDone = drawer {
            withAnimation(DS.spring) { showDrawer = false }
            return
        }
        withAnimation(DS.spring) { showDrawer = true }
        if !force, case .convDone = drawer { return }
        if !force, let (cached, _) = engine.latestConversationAnalysis(chat: chat) {
            drawer = .convDone(cached)
            return
        }
        drawer = .convLoading(Date())
        Task {
            do { drawer = .convDone(try await engine.analyzeConversation(chat: chat, limit: 60, force: force)) }
            catch { drawer = .convFailed(error.localizedDescription) }
        }
    }

    private func runGroupAnalysis(force: Bool) {
        guard let engine = model.engine, let chat = companion.currentChat else { return }
        if !force, showDrawer, case .groupDone = drawer {
            withAnimation(DS.spring) { showDrawer = false }
            return
        }
        withAnimation(DS.spring) { showDrawer = true }
        if !force, case .groupDone = drawer { return }
        if !force, let (cached, _) = engine.latestGroupAnalysis(chat: chat) {
            drawer = .groupDone(cached)
            return
        }
        drawer = .groupLoading(Date())
        Task {
            do { drawer = .groupDone(try await engine.analyzeGroup(chat: chat, limit: 80, force: force)) }
            catch { drawer = .groupFailed(error.localizedDescription) }
        }
    }

    private func runGroupMemberAnalysis(member: String, force: Bool) {
        guard let engine = model.engine, let chat = companion.currentChat else { return }
        withAnimation(DS.spring) { showDrawer = true }
        if !force, case .memberDone(let cur, _) = drawer, cur == member { return }
        if !force, let (cached, _) = engine.latestGroupMemberAnalysis(chat: chat, member: member) {
            drawer = .memberDone(member, cached)
            return
        }
        drawer = .memberLoading(member, Date())
        Task {
            do { drawer = .memberDone(member, try await engine.analyzeGroupMember(chat: chat, member: member, limit: 80, force: force)) }
            catch { drawer = .memberFailed(member, error.localizedDescription) }
        }
    }

    private func refreshCurrentDrawer() {
        switch drawer {
        case .convDone, .convFailed, .convLoading:
            runConversation(force: true)
        case .groupDone, .groupFailed, .groupLoading:
            runGroupAnalysis(force: true)
        case .memberDone(let m, _), .memberFailed(let m, _), .memberLoading(let m, _):
            runGroupMemberAnalysis(member: m, force: true)
        case .none:
            if isGroup { runGroupAnalysis(force: true) } else { runConversation(force: true) }
        }
    }

    private func generateQuickReplies(chat: String, force: Bool) {
        guard let engine = model.engine else { return }
        let focus = isGroup ? selectedMember : nil
        quickReplyState = .loading(Date())
        Task {
            do {
                let suggestions = try await engine.quickReplies(chat: chat, focusMember: focus, limit: 30, force: force)
                withAnimation(DS.spring) { quickReplyState = .ready(suggestions) }
                if let first = suggestions.first?.text {
                    drafts[chat] = first
                    replyFocused = true
                }
            } catch {
                quickReplyState = .failed(error.localizedDescription)
            }
        }
    }

    private func sendReply(chat: String) {
        let text = (drafts[chat] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        sendError = nil
        sendSuccess = false
        let contact = model.store?.contact(chat)
        let fallback = model.displayName(chat)
        let chats = model.chats
        let cmdReturn = sendWithCommandReturn

        Task {
            do {
                try await WeChatReplyService.send(
                    text: text,
                    to: chat,
                    contact: contact,
                    fallbackDisplay: fallback,
                    chats: chats,
                    useCommandReturn: cmdReturn,
                    restorePreviousApp: false
                )
                drafts[chat] = ""
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

struct CompanionMessageRow: View {
    @EnvironmentObject var model: AppModel
    var message: LensMessage
    var expanded: Bool
    var toggle: () -> Void
    var onFillReply: ((String) -> Void)? = nil
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
                MessageAnalysisSlot(message: message, compact: true, onFillReply: onFillReply)
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
