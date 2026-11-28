import LensCore
import MudsUI
import SwiftUI

struct ChatsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Prefs.showMutedChats) private var showMuted = false
    @State private var filter = ""
    @State private var kindFilter: KindFilter = .all
    @State private var totalWidth: CGFloat = 700

    enum KindFilter: Hashable { case all, person, group, watched }

    private var listWidth: CGFloat {
        (totalWidth > 0 && totalWidth < 560) ? 192 : 224
    }

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
                    .buttonStyle(IconButtonStyle(size: 26))
                    .help(showMuted ? "隐藏免打扰会话" : "显示已免打扰会话")
                }
                BSegmented(selection: $kindFilter, options: [(.all, "全部"), (.person, "私聊"), (.group, "群聊"), (.watched, "关注")],
                           compact: true)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(chats) { c in
                            let unread = model.displayUnread(for: c)
                            ChatListRow(
                                chat: c,
                                unread: unread,
                                watched: model.watchlist.contains(c.username),
                                selected: model.selectedChat == c.username
                            )
                                .onTapGesture {
                                    withAnimation(DS.spring) {
                                        if unread > 0, let first = model.firstUnreadMessage(for: c.username, unreadCount: unread) {
                                            model.unreadAnchorMessageID = first.id
                                            model.focusedMessageID = first.id
                                            model.markMenuBarRead(c.username)
                                        } else {
                                            model.unreadAnchorMessageID = nil
                                        }
                                        model.selectedChat = c.username
                                        model.recordNavigation()
                                    }
                                }
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
            .frame(width: listWidth)
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { totalWidth = $0 }
    }
}

struct ChatListRow: View {
    var chat: ChatSummary
    var unread: Int
    var watched: Bool
    var selected = false
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(username: chat.username, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(chat.display)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.chatTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if chat.isMuted { Image(systemName: "bell.slash").font(.system(size: 9.5)).foregroundStyle(DS.ink5) }
                    if watched { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(DS.warning) }
                    Spacer(minLength: 4)
                    Text(DateFmt.compactList(Date(timeIntervalSince1970: TimeInterval(chat.lastTs))))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(DS.ink5)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                HStack {
                    Text(chat.lastText)
                        .font(DS.sub)
                        .foregroundStyle(DS.ink4)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if unread > 0 {
                        Text(unread > 99 ? "99+" : "\(unread)")
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
    @State private var viewingContext = false
    @State private var highlightedID: Int64?
    @State private var headerWidth: CGFloat = 600
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
                            if model.unreadAnchorMessageID == m.id {
                                HStack(spacing: 8) {
                                    Rectangle().fill(DS.pick.opacity(0.35)).frame(height: 1)
                                    Text("以下为未读消息")
                                        .font(DS.micro)
                                        .foregroundStyle(DS.pick)
                                        .fixedSize()
                                    Rectangle().fill(DS.pick.opacity(0.35)).frame(height: 1)
                                }
                                .padding(.vertical, 6)
                            }
                            MessageBubble(
                                message: m,
                                isGroup: chat.hasSuffix("@chatroom"),
                                compact: headerWidth > 0 && headerWidth < 380,
                                highlighted: highlightedID == m.id
                            )
                            .id(m.id)
                        }
                    }
                    .padding(16)
                }
                .defaultScrollAnchor(.bottom)
                .overlay(alignment: .bottom) {
                    if viewingContext {
                        Button {
                            viewingContext = false
                            reloadMessages()
                        } label: {
                            Label("回到最新消息", systemImage: "arrow.down.to.line")
                        }
                        .buttonStyle(BButtonStyle(kind: .secondary, compact: true))
                        .padding(.bottom, 12)
                    }
                }
                .onAppear { focusTargetIfNeeded(proxy: proxy) }
                .onChange(of: model.focusedMessageID) { _, _ in focusTargetIfNeeded(proxy: proxy) }
                .onChange(of: messages.last?.id) { _, id in
                    guard !viewingContext, model.focusedMessageID == nil, highlightedID == nil, let id else { return }
                    // Lazy rows settle their heights after the first pass; scroll again once laid out.
                    proxy.scrollTo(id, anchor: .bottom)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
        .background(DS.bg)
        .sheet(isPresented: $showSummary) { summarySheet }
        .task(id: model.revision) {
            if model.focusedMessageID == nil { reloadMessages() }
        }
    }

    private var header: some View {
        let compact = headerWidth > 0 && headerWidth < 460
        return HStack(spacing: 10) {
            AvatarView(username: chat, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayName(chat))
                    .font(DS.title)
                    .foregroundStyle(Theme.chatTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let c = model.store?.contact(chat), !c.remark.isEmpty, !c.nick.isEmpty, c.remark != c.nick {
                    Text(c.nick)
                        .font(DS.sub)
                        .foregroundStyle(DS.ink4)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Button { model.setWatched(chat, !model.watchlist.contains(chat)) } label: {
                Image(systemName: model.watchlist.contains(chat) ? "star.fill" : "star")
                    .foregroundStyle(model.watchlist.contains(chat) ? DS.warning : DS.ink3)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(IconButtonStyle(size: 28)).help("关注：新消息自动分析")

            if compact {
                Button {
                    model.insightChat = chat
                    model.navigate(to: .insight)
                } label: {
                    Image(systemName: "person.2.wave.2")
                }
                .buttonStyle(IconButtonStyle(size: 28))
                .help("关系洞察")

                Button { summarize(force: false) } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(DS.onSlab)
                        .frame(width: 28, height: 28)
                        .background(DS.slab, in: Circle())
                }
                .buttonStyle(.plain)
                .help("总结对话")
            } else {
                Button {
                    model.insightChat = chat
                    model.navigate(to: .insight)
                } label: { Label("关系洞察", systemImage: "person.2.wave.2") }
                    .buttonStyle(BButtonStyle(kind: .secondary, compact: true))
                    .fixedSize()
                Button { summarize(force: false) } label: { Label("总结对话", systemImage: "sparkles") }
                    .buttonStyle(BButtonStyle(kind: .primary, compact: true))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { headerWidth = $0 }
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

    private func reloadMessages() {
        guard let store = model.store else { return }
        if !viewingContext {
            let fresh = store.messages(chat: chat, limit: max(150, min(messages.count, 1000)))
            if fresh.map(\.id) != messages.map(\.id) || fresh.map(\.recalledAt) != messages.map(\.recalledAt) {
                messages = fresh
            }
            exhausted = fresh.count < 150
        }
        if case .idle = convState, let (a, at) = model.engine?.latestConversationAnalysis(chat: chat) {
            convState = .done(a, at)
        }
    }

    private func focusTargetIfNeeded(proxy: ScrollViewProxy) {
        guard let targetID = model.focusedMessageID,
              let store = model.store,
              let target = store.message(id: targetID),
              target.chat == chat else {
            return
        }
        let isUnreadJump = (targetID == model.unreadAnchorMessageID)
        if !messages.contains(where: { $0.id == targetID }) {
            let tail = store.messages(chat: chat, limit: 150)
            if tail.contains(where: { $0.id == targetID }) {
                messages = tail
                viewingContext = false
                exhausted = tail.count < 150
            } else {
                messages = store.context(for: target, before: 20, after: 80)
                viewingContext = true
                exhausted = false
            }
        }
        highlightedID = targetID
        model.focusedMessageID = nil
        let anchor: UnitPoint = isUnreadJump ? .top : .center
        DispatchQueue.main.async {
            withAnimation(DS.ease) { proxy.scrollTo(targetID, anchor: anchor) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(DS.ease) { proxy.scrollTo(targetID, anchor: anchor) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if highlightedID == targetID {
                withAnimation(DS.ease) { highlightedID = nil }
            }
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
    var compact = false
    var highlighted = false
    @State private var hover = false

    var body: some View {
        if message.isSystem {
            Text(message.text).font(DS.micro).foregroundStyle(DS.ink5).frame(maxWidth: .infinity).padding(.vertical, 2)
        } else {
            let sideSpacer: CGFloat = compact ? 24 : 70
            HStack(alignment: .top, spacing: 8) {
                if message.isSelf { Spacer(minLength: sideSpacer) } else {
                    AvatarView(username: message.sender ?? message.chat, size: 30)
                }
                VStack(alignment: message.isSelf ? .trailing : .leading, spacing: 3) {
                    if isGroup && !message.isSelf {
                        Text(model.senderLabel(message))
                            .font(DS.micro)
                            .foregroundStyle(DS.ink5)
                            .lineLimit(1)
                            .truncationMode(.tail)
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
                                .strokeBorder(highlighted ? DS.pick : (message.isRecalled ? DS.warning : (message.isSelf ? .clear : DS.edge)),
                                              style: StrokeStyle(
                                                  lineWidth: highlighted ? 2 : (message.isRecalled ? 1.5 : 1),
                                                  dash: highlighted ? [] : (message.isRecalled ? [4, 3] : [])
                                              ))
                        }
                        .overlay(alignment: message.isSelf ? .topLeading : .topTrailing) { badge }
                        if !message.isSelf { analyzeButton }
                    }
                }
                if !message.isSelf { Spacer(minLength: sideSpacer) }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, highlighted ? 4 : 0)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(highlighted ? DS.pick.opacity(0.10) : .clear)
            )
            .animation(DS.ease, value: highlighted)
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
