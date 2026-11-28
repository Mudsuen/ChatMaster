import LensCore
import MudsUI
import SwiftUI

/// Floating search panel anchored below the top bar search field with inline filters.
struct SearchOverlayView: View {
    @EnvironmentObject var model: AppModel
    var close: () -> Void

    enum TimeRange: String, CaseIterable, Hashable {
        case all, today, week, month, year

        var title: String {
            switch self {
            case .all: return "全部时间"
            case .today: return "今天"
            case .week: return "近 7 天"
            case .month: return "近 30 天"
            case .year: return "近一年"
            }
        }

        var sinceTs: Int64? {
            let now = Date()
            switch self {
            case .all: return nil
            case .today: return Int64(Calendar.current.startOfDay(for: now).timeIntervalSince1970)
            case .week: return Int64(now.addingTimeInterval(-7 * 86400).timeIntervalSince1970)
            case .month: return Int64(now.addingTimeInterval(-30 * 86400).timeIntervalSince1970)
            case .year: return Int64(now.addingTimeInterval(-365 * 86400).timeIntervalSince1970)
            }
        }
    }

    @State private var results: [LensMessage] = []
    @State private var chatScope: String?
    @State private var timeRange: TimeRange = .all
    @State private var recalledOnly = false
    @State private var chatKind: ChatKind?
    @State private var sender: SearchSender = .all
    @State private var searching = false
    @State private var searchSeq = 0
    @State private var debounceTask: Task<Void, Never>?

    private var trimmedQuery: String {
        model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasActiveFilter: Bool {
        chatScope != nil || timeRange != .all || recalledOnly || chatKind != nil || sender != .all
    }

    var body: some View {
        VStack(spacing: 0) {
            filterHeader
            Rectangle().fill(DS.edge).frame(height: 1)
            statusStrip
            resultsBody
        }
        .frame(minWidth: 420, idealWidth: 560, maxWidth: 620)
        .frame(maxHeight: 500)
        .fixedSize(horizontal: false, vertical: true)
        .background(DS.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(DS.edge, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 22, y: 10)
        .background {
            Button("") { close() }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
        }
        .onAppear { run() }
        .onChange(of: model.searchTrigger) { _, _ in run() }
        .onChange(of: chatScope) { _, _ in run() }
        .onChange(of: timeRange) { _, _ in run() }
        .onChange(of: recalledOnly) { _, _ in run() }
        .onChange(of: chatKind) { _, _ in run() }
        .onChange(of: sender) { _, _ in run() }
        .onChange(of: model.searchQuery) { _, _ in
            debounceTask?.cancel()
            debounceTask = Task {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                run()
            }
        }
    }

    private var filterHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Menu {
                    Button("全部会话") { chatScope = nil }
                    if let cur = model.selectedChat {
                        Button("当前会话：\(model.displayName(cur))") { chatScope = cur }
                    }
                    Divider()
                    ForEach(model.chats.prefix(60)) { c in
                        Button(c.display) { chatScope = c.username }
                    }
                } label: {
                    Label(chatScope.map { model.displayName($0) } ?? "全部会话", systemImage: "bubble.left.and.bubble.right")
                }
                .menuStyle(.button)
                .buttonStyle(BButtonStyle(kind: .secondary, compact: true))
                .fixedSize()

                Menu {
                    ForEach(TimeRange.allCases, id: \.self) { range in
                        Button(range.title) { timeRange = range }
                    }
                } label: {
                    Label(timeRange.title, systemImage: "calendar")
                }
                .menuStyle(.button)
                .buttonStyle(BButtonStyle(kind: .secondary, compact: true))
                .fixedSize()

                Spacer(minLength: 4)

                if hasActiveFilter || !trimmedQuery.isEmpty {
                    Button("重置") { resetFilters() }
                        .buttonStyle(BButtonStyle(kind: .ghost, compact: true))
                }

                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(DS.ink4)
                }
                .buttonStyle(IconButtonStyle(size: 22))
                .help("关闭搜索 (Esc)")
            }

            HStack(spacing: 6) {
                FilterTogglePill(
                    title: "仅撤回",
                    systemImage: "arrow.uturn.backward.circle",
                    active: recalledOnly,
                    tint: DS.warning
                ) {
                    recalledOnly.toggle()
                }

                pillDivider

                FilterTogglePill(
                    title: "私聊",
                    active: chatKind == .person,
                    tint: DS.pick
                ) {
                    chatKind = chatKind == .person ? nil : .person
                }
                FilterTogglePill(
                    title: "群聊",
                    active: chatKind == .group,
                    tint: DS.pick
                ) {
                    chatKind = chatKind == .group ? nil : .group
                }

                pillDivider

                FilterTogglePill(
                    title: "我发出",
                    active: sender == .mine,
                    tint: DS.pick
                ) {
                    sender = sender == .mine ? .all : .mine
                }
                FilterTogglePill(
                    title: "对方",
                    active: sender == .others,
                    tint: DS.pick
                ) {
                    sender = sender == .others ? .all : .others
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var pillDivider: some View {
        Rectangle()
            .fill(DS.edge)
            .frame(width: 1, height: 12)
    }

    private var statusStrip: some View {
        HStack(spacing: 6) {
            if searching {
                ThinkingOrb(size: 11)
                Text("搜索中…").font(DS.micro).foregroundStyle(DS.ink4)
            } else if !results.isEmpty {
                Text("\(results.count) 条结果 · 点击定位到会话").font(DS.micro).foregroundStyle(DS.ink4)
            } else if trimmedQuery.isEmpty && !hasActiveFilter {
                Text("输入关键词，或点选上方筛选项直接浏览（如「仅撤回」）")
                    .font(DS.micro)
                    .foregroundStyle(DS.ink4)
            } else {
                Text("没有匹配的消息").font(DS.micro).foregroundStyle(DS.ink4)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(DS.bg.opacity(0.45))
    }

    @ViewBuilder private var resultsBody: some View {
        if !results.isEmpty {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(results) { m in
                        MessageRow(message: m, selected: model.inspected?.id == m.id)
                            .onTapGesture {
                                model.openChat(m.chat, focusMessage: m)
                                close()
                            }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(height: 360)
        } else {
            VStack(spacing: 6) {
                Image(systemName: trimmedQuery.isEmpty && !hasActiveFilter ? "text.magnifyingglass" : "tray")
                    .font(.system(size: 22))
                    .foregroundStyle(DS.ink5)
                Text(trimmedQuery.isEmpty && !hasActiveFilter ? "支持按会话、时间、撤回状态和发送方组合筛选" : "试试放宽筛选条件或更换关键词")
                    .font(DS.sub)
                    .foregroundStyle(DS.ink4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 118)
        }
    }

    private func resetFilters() {
        model.searchQuery = ""
        chatScope = nil
        timeRange = .all
        recalledOnly = false
        chatKind = nil
        sender = .all
        results = []
        searching = false
    }

    private func run() {
        guard let store = model.store else { return }
        let q = trimmedQuery
        let hasScopeFilter = hasActiveFilter
        guard !q.isEmpty || hasScopeFilter else {
            searchSeq += 1
            results = []
            searching = false
            return
        }
        searchSeq += 1
        let token = searchSeq
        let scope = chatScope
        let recalled = recalledOnly
        let senderVal = sender
        let kindVal = chatKind
        let sinceTs = timeRange.sinceTs
        searching = true
        Task {
            let r = await Task.detached {
                store.search(
                    q,
                    chat: scope,
                    recalledOnly: recalled,
                    sender: senderVal,
                    chatKind: kindVal,
                    since: sinceTs,
                    limit: 300
                )
            }.value
            guard searchSeq == token else { return }
            withAnimation(DS.ease) { results = r }
            searching = false
        }
    }
}

private struct FilterTogglePill: View {
    var title: String
    var systemImage: String?
    var active: Bool
    var tint: Color
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: active ? "\(systemImage).fill" : systemImage)
                        .font(.system(size: 10.5))
                }
                Text(title)
                    .font(.system(size: 11.5, weight: active ? .semibold : .medium))
            }
            .foregroundStyle(active ? tint : DS.ink3)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(active ? tint.opacity(0.15) : (hover ? DS.wash2 : DS.wash), in: Capsule())
            .overlay(
                Capsule().strokeBorder(active ? tint.opacity(0.55) : DS.edge, lineWidth: 0.75)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(DS.ease, value: hover)
        .animation(DS.ease, value: active)
    }
}
