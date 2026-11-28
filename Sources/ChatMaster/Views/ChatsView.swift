import LensCore
import MudsUI
import SwiftUI

struct ChatsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Prefs.showMutedChats) private var showMuted = false
    @State private var filter = ""
    @State private var kindFilter: KindFilter = .all

    enum KindFilter: Hashable { case all, person, group, watched }

    private var matchingKindAndSearch: [ChatSummary] {
        model.chats.filter { c in
            let kindOK: Bool
            switch kindFilter {
            case .all: kindOK = true
            case .person: kindOK = c.kind == .person
            case .group: kindOK = c.kind == .group
            case .watched: kindOK = model.watchlist.contains(c.username)
            }
            return kindOK && (filter.isEmpty || c.display.localizedCaseInsensitiveContains(filter))
        }
    }

    private var mutedHiddenCount: Int {
        matchingKindAndSearch.filter { $0.isMuted || $0.isFolded }.count
    }

    private var chats: [ChatSummary] {
        if showMuted { return matchingKindAndSearch }
        return matchingKindAndSearch.filter { !$0.isMuted && !$0.isFolded }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    FilterField(text: $filter, prompt: "筛选会话")
                    Button {
                        withAnimation(DS.ease) { showMuted.toggle() }
                    } label: {
                        Image(systemName: showMuted ? "bell.slash.fill" : "bell.slash")
                            .foregroundStyle(showMuted ? DS.pick : DS.ink4)
                    }
                    .buttonStyle(IconButtonStyle(size: 28))
                    .help(showMuted ? "隐藏免打扰会话" : "显示已免打扰会话")
                }
                BSegmented(selection: $kindFilter, options: [(.all, "全部"), (.person, "私聊"), (.group, "群聊"), (.watched, "关注")],
                           compact: true)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(chats) { c in
                            ChatListRow(chat: c, watched: model.watchlist.contains(c.username), selected: model.selectedChat == c.username)
                                .onTapGesture { withAnimation(DS.spring) { model.selectedChat = c.username } }
                                .contextMenu {
                                    Button(model.watchlist.contains(c.username) ? "取消关注" : "关注（新消息自动分析）") {
                                        model.setWatched(c.username, !model.watchlist.contains(c.username))
                                    }
                                }
                        }
                        if !showMuted && mutedHiddenCount > 0 {
                            Button {
                                withAnimation(DS.ease) { showMuted = true }
                            } label: {
                                Text("已隐藏 \(mutedHiddenCount) 个免打扰会话 · 显示")
                                    .font(DS.micro)
                                    .foregroundStyle(DS.ink4)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .frame(maxWidth: .infinity)
                                    .background(DS.wash, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 6)
                        }
                    }
                }
            }
            .padding(10)
            .frame(width: 232)
            .background(DS.bg)
            Rectangle().fill(DS.edge).frame(width: 1)
            Group {
                if let chat = model.selectedChat {
                    ChatTranscriptView(chat: chat).id(chat)
                } else {
                    EmptyHint(title: "选择一个会话", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ChatListRow: View {
    var chat: ChatSummary
    var watched: Bool
    var selected = false
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(username: chat.username, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(chat.display).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.chatTitle).lineLimit(1)
                    if chat.isMuted { Image(systemName: "bell.slash").font(.system(size: 9.5)).foregroundStyle(DS.ink5) }
                    if watched { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(DS.warning) }
                    Spacer(minLength: 2)
                    Text(Fmt.smart(Date(timeIntervalSince1970: TimeInterval(chat.lastTs))))
                        .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(DS.ink5)
                }
                HStack {
                    Text(chat.lastText).font(DS.sub).foregroundStyle(DS.ink4).lineLimit(1)
                    Spacer(minLength: 2)
                    if chat.unread > 0 {
                        Text(chat.unread > 99 ? "99+" : "\(chat.unread)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(chat.kind == .person && !chat.isMuted ? DS.error : DS.ink5, in: Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(selected ? DS.card : (hover ? DS.wash : .clear), in: RoundedRectangle(cornerRadius: DS.innerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.innerRadius, style: .continuous).strokeBorder(selected ? DS.edge : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(DS.ease, value: hover)
    }
}

struct ChatTranscriptView: View {
    @EnvironmentObject var model: AppModel
    var chat: String
    @State private var messages: [LensMessage] = []
    @State private var exhausted = false
    @State private var convState: ConvState = .idle
    @State private var showSummary = false

    enum ConvState { case idle, loading(Date), done(ConversationAnalysis, Date), failed(String) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(DS.edge).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if !exhausted && !messages.isEmpty {
                            Button("加载更早的消息") { loadOlder() }.buttonStyle(BButtonStyle(kind: .ghost, compact: true))
                                .frame(maxWidth: .infinity).padding(8)
                        }
                        ForEach(Array(messages.enumerated()), id: \.element.id) { i, m in
                            if i == 0 || m.ts - messages[i - 1].ts > 1800 {
                                Text(Fmt.smart(m.date)).font(DS.micro).foregroundStyle(DS.ink5)
                                    .padding(.horizontal, 8).padding(.vertical, 2)
                                    .background(DS.wash, in: Capsule())
                                    .frame(maxWidth: .infinity).padding(.top, 10)
                            }
                            MessageBubble(message: m, isGroup: chat.hasSuffix("@chatroom")).id(m.id)
                        }
                    }
                    .padding(16)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: messages.last?.id) { _, id in
                    guard let id else { return }
                    // Lazy rows settle their heights after the first pass; scroll again once laid out.
                    proxy.scrollTo(id, anchor: .bottom)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
        .background(DS.bg)
        .sheet(isPresented: $showSummary) { summarySheet }
        .task(id: model.revision) { reloadTail() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AvatarView(username: chat, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayName(chat)).font(DS.title).foregroundStyle(Theme.chatTitle)
                if let c = model.store?.contact(chat), !c.remark.isEmpty, !c.nick.isEmpty, c.remark != c.nick {
                    Text(c.nick).font(DS.sub).foregroundStyle(DS.ink4)
                }
            }
            Spacer()
            Button { model.setWatched(chat, !model.watchlist.contains(chat)) } label: {
                Image(systemName: model.watchlist.contains(chat) ? "star.fill" : "star")
                    .foregroundStyle(model.watchlist.contains(chat) ? DS.warning : DS.ink3)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(IconButtonStyle()).help("关注：新消息自动分析")
            Button {
                model.insightChat = chat
                model.section = .insight
            } label: { Label("关系洞察", systemImage: "person.2.wave.2") }
                .buttonStyle(BButtonStyle(kind: .secondary))
            Button { summarize(force: false) } label: { Label("总结对话", systemImage: "sparkles") }
                .buttonStyle(BButtonStyle(kind: .primary))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder private var summarySheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("对话总结").font(.system(size: 20, weight: .semibold)).tracking(-0.3)
                    Text(model.displayName(chat)).font(DS.sub).foregroundStyle(DS.ink4)
                }
                Spacer()
                Button("重新生成") { summarize(force: true) }.buttonStyle(BButtonStyle(kind: .secondary))
                    .disabled({ if case .loading = convState { return true }; return false }())
                Button("关闭") { showSummary = false }.buttonStyle(BButtonStyle(kind: .primary)).keyboardShortcut(.cancelAction)
            }
            ScrollView {
                switch convState {
                case .idle: EmptyView()
                case .loading(let since): AnalyzingView(since: since, label: "agy 正在阅读最近 80 条消息…")
                case .failed(let e): Text(e).foregroundStyle(DS.error).textSelection(.enabled)
                case .done(let a, let at):
                    VStack(alignment: .leading, spacing: 10) {
                        ConversationAnalysisCard(analysis: a)
                        Text("生成于 \(Fmt.smart(at))").font(DS.micro).foregroundStyle(DS.ink5)
                    }
                    .transition(.opacity)
                }
            }
            .animation(DS.spring, value: { if case .done = convState { return true }; return false }())
        }
        .padding(24)
        .frame(width: 580, height: 640)
        .background(DS.card)
    }

    private func summarize(force: Bool) {
        guard let engine = model.engine else { return }
        showSummary = true
        if !force, case .done = convState { return }
        convState = .loading(Date())
        Task {
            do {
                let a = try await engine.analyzeConversation(chat: chat, force: force)
                convState = .done(a, Date())
            } catch {
                convState = .failed(error.localizedDescription)
            }
        }
    }

    private func reloadTail() {
        guard let store = model.store else { return }
        let fresh = store.messages(chat: chat, limit: max(150, min(messages.count, 1000)))
        if fresh.map(\.id) != messages.map(\.id) || fresh.map(\.recalledAt) != messages.map(\.recalledAt) { messages = fresh }
        if messages.count < 150 { exhausted = true }
        if case .idle = convState, let (a, at) = model.engine?.latestConversationAnalysis(chat: chat) {
            convState = .done(a, at)
        }
    }

    private func loadOlder() {
        guard let store = model.store, let first = messages.first else { return }
        let older = store.messages(chat: chat, before: first.ts, limit: 200)
        if older.count < 200 { exhausted = true }
        messages = older + messages
    }
}

struct MessageBubble: View {
    @EnvironmentObject var model: AppModel
    var message: LensMessage
    var isGroup: Bool
    @State private var hover = false

    var body: some View {
        if message.isSystem {
            Text(message.text).font(DS.micro).foregroundStyle(DS.ink5).frame(maxWidth: .infinity).padding(.vertical, 2)
        } else {
            HStack(alignment: .top, spacing: 8) {
                if message.isSelf { Spacer(minLength: 70) } else {
                    AvatarView(username: message.sender ?? message.chat, size: 30)
                }
                VStack(alignment: message.isSelf ? .trailing : .leading, spacing: 3) {
                    if isGroup && !message.isSelf {
                        Text(model.senderLabel(message)).font(DS.micro).foregroundStyle(DS.ink5)
                    }
                    if message.isRecalled { RecallChip(message: message) }
                    HStack(alignment: .bottom, spacing: 6) {
                        if message.isSelf { analyzeButton }
                        VStack(alignment: .leading, spacing: 4) {
                            if let q = message.quote {
                                Text(q).font(DS.sub).foregroundStyle(message.isSelf ? DS.onSlab.opacity(0.65) : DS.ink4).lineLimit(2)
                                    .padding(.leading, 7)
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(message.isSelf ? DS.onSlab.opacity(0.4) : DS.ink.opacity(0.2)).frame(width: 2)
                                    }
                            }
                            Text(message.text).font(.system(size: 14))
                                .textSelection(.enabled)
                                .foregroundStyle(message.isSelf ? DS.onSlab.opacity(message.isTextual ? 1 : 0.7)
                                                 : (message.isTextual ? DS.ink : DS.ink4))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(message.isSelf ? DS.slab : DS.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(message.isRecalled ? DS.warning : (message.isSelf ? .clear : DS.edge),
                                              style: StrokeStyle(lineWidth: message.isRecalled ? 1.5 : 1, dash: message.isRecalled ? [4, 3] : []))
                        }
                        .overlay(alignment: message.isSelf ? .topLeading : .topTrailing) { badge }
                        if !message.isSelf { analyzeButton }
                    }
                }
                if !message.isSelf { Spacer(minLength: 70) }
            }
            .onHover { hover = $0 }
            .contextMenu { MessageMenu(message: message) }
        }
    }

    @ViewBuilder private var analyzeButton: some View {
        if message.isTextual {
            Button { model.inspect(message) } label: { Image(systemName: "sparkles") }
                .buttonStyle(IconButtonStyle(size: 24))
                .opacity(hover || model.inspected?.id == message.id ? 1 : 0)
                .animation(DS.ease, value: hover)
                .help("分析情绪与意图")
        }
    }

    @ViewBuilder private var badge: some View {
        if let a = model.analysisState(message.id)?.result {
            Text(a.emoji).font(.system(size: 13))
                .padding(3)
                .background(DS.raised, in: Circle())
                .overlay(Circle().strokeBorder(DS.edge, lineWidth: 0.5))
                .offset(x: message.isSelf ? -10 : 10, y: -10)
                .transition(.scale.combined(with: .opacity))
                .help("\(a.emotion) · \(a.intent)")
        }
    }
}
