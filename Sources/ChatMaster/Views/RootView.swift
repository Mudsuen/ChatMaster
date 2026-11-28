import LensCore
import MudsUI
import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var showInspector = true

    private let panelCurve = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.2)

    private var inspectorVisible: Bool {
        showInspector && model.section.supportsInspector
    }

    var body: some View {
        NavigationSplitView {
            CompactSidebar()
                .navigationSplitViewColumnWidth(min: 148, ideal: 162, max: 192)
        } detail: {
            HStack(spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        switch model.state {
                        case .starting:
                            VStack(spacing: 14) { ThinkingOrb(size: 40); ShimmerText(text: "正在打开数据…") }
                        case .importing(let phase, let frac):
                            ImportingView(phase: phase, fraction: frac)
                        case .failed(let msg):
                            EmptyHint(title: "无法读取微信数据", systemImage: "lock.trianglebadge.exclamationmark", detail: msg)
                        case .ready:
                            detail.id(model.section)
                                .transition(.opacity)
                        }
                    }
                    .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
                    .background(DS.bg)
                    .animation(DS.ease, value: model.section)
                    ToastStackView().padding(16)
                }
                .clipped()

                if inspectorVisible {
                    Rectangle().fill(DS.edge).frame(width: 1)
                    InspectorView()
                        .frame(width: 280)
                        .frame(maxHeight: .infinity)
                        .background(DS.bg)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, minHeight: 460, maxHeight: .infinity)
            .clipped()
            .animation(panelCurve, value: inspectorVisible)
        }
        .toolbar {
            if model.section.supportsInspector {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        withAnimation(panelCurve) { showInspector.toggle() }
                    } label: {
                        Label("分析面板", systemImage: "sidebar.trailing")
                    }
                    .help("显示/隐藏分析面板")
                }
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .navigationTitle("")
        .onChange(of: model.inspected) { _, m in
            if m != nil {
                withAnimation(panelCurve) { showInspector = true }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .dashboard: DashboardView()
        case .live: LiveFeedView()
        case .chats: ChatsView()
        case .pending: PendingView()
        case .recalls: RecallsView()
        case .insight: InsightView()
        case .search: SearchView()
        case .briefing: BriefingView()
        }
    }
}

/// Compact left navigation sidebar with subtle hover and selection background highlights.
struct CompactSidebar: View {
    @EnvironmentObject var model: AppModel
    @State private var hovered: AppSection?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                ThinkingOrb(size: 18, active: model.analyses.values.contains { $0.isLoading })
                Text("ChatMaster")
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Theme.chatTitle)
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .padding(.bottom, 10)

            ForEach(Array(AppSection.allCases.enumerated()), id: \.element.id) { index, item in
                navRow(item, index: index)
            }

            Spacer(minLength: 8)
            SyncFooter()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.sidebar)
    }

    private func navRow(_ item: AppSection, index: Int) -> some View {
        let on = model.section == item
        let hot = hovered == item
        let n = badge(for: item)
        return Button {
            withAnimation(DS.ease) { model.section = item }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(on ? DS.ink : DS.ink4)
                    .frame(width: 16)
                Text(item.title)
                    .font(.system(size: 13, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Theme.chatTitle : DS.ink3)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if n > 0 {
                    Text(n > 99 ? "99+" : "\(n)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(on ? DS.onSlab : DS.ink3)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(on ? DS.slab : DS.wash2, in: Capsule())
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 29)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DS.card)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(DS.edge, lineWidth: 0.75)
                        )
                } else if hot {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DS.wash)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command) : nil)
        .onHover { hovered = $0 ? item : (hovered == item ? nil : hovered) }
        .animation(DS.ease, value: hot)
    }

    private func badge(for s: AppSection) -> Int {
        switch s {
        case .chats: return model.chats.reduce(0) { $0 + ($1.kind == .person && !$1.isMuted && !$1.isFolded ? $1.unread : 0) }
        case .recalls: return model.recalledToday
        default: return 0
        }
    }
}

struct ImportingView: View {
    var phase: String
    var fraction: Double

    var body: some View {
        VStack(spacing: 16) {
            ThinkingOrb(size: 48)
            Text("正在建立本地索引").font(.system(size: 20, weight: .semibold))
            ProgressView(value: fraction).tint(DS.ink).frame(width: 300)
            Text(phase).font(DS.micro.monospaced()).foregroundStyle(DS.ink4)
            Text("只读访问微信数据库，首次约需十几秒").font(DS.sub).foregroundStyle(DS.ink5)
        }
        .padding(40)
    }
}

struct SyncFooter: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                PulseDot(color: model.syncErrors.isEmpty ? DS.ok : DS.warning, size: 5)
                Text(model.syncErrors.isEmpty ? "同步中" : "同步异常")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.ink2)
                Spacer(minLength: 4)
                Button { model.syncNow() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(IconButtonStyle(size: 20))
                    .help("立即同步（⌘R）")
            }
            if let t = model.lastSync {
                Text("\(Fmt.count(model.totalIndexed)) 条 · \(Fmt.time.string(from: t))")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(DS.ink5)
                    .lineLimit(1)
            }
            if !model.missingKeys.isEmpty {
                Text("缺少密钥：\(model.missingKeys.joined(separator: ", "))")
                    .font(DS.micro).foregroundStyle(DS.warning).lineLimit(2)
                    .help("请先更新本地已解密数据源配置（all_keys.json）以补齐新数据库密钥")
            }
            ForEach(model.syncErrors.prefix(2), id: \.self) { e in
                Text(e).font(DS.micro).foregroundStyle(DS.warning).lineLimit(2).help(e)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(DS.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DS.edge, lineWidth: 1))
    }
}

/// Right-hand panel: the inspected message with context and its analysis.
struct InspectorView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            if let m = model.inspected {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        AvatarView(username: m.isSelf ? (model.store?.selfUsername ?? "") : (m.sender ?? m.chat), size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.senderLabel(m)).font(DS.title).foregroundStyle(DS.ink)
                            Text("\(model.displayName(m.chat)) · \(Fmt.smart(m.date))").font(DS.sub).foregroundStyle(DS.ink4)
                        }
                        Spacer()
                        Button { model.openChat(m.chat) } label: { Image(systemName: "arrow.up.right") }
                            .buttonStyle(IconButtonStyle()).help("打开会话")
                    }
                    if m.isRecalled { RecallBanner(message: m) }
                    VStack(alignment: .leading, spacing: 6) {
                        if let q = m.quote { Text("↪︎ \(q)").font(DS.sub).foregroundStyle(DS.ink4).lineLimit(2) }
                        Text(m.text).font(.system(size: 14.5)).foregroundStyle(m.isSelf ? DS.onSlab : DS.ink)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(m.isSelf ? DS.slab : DS.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(m.isSelf ? .clear : DS.edge, lineWidth: 1))
                    Card { MessageAnalysisSlot(message: m) }
                }
                .padding(14)
                .id(m.id)
                .transition(.opacity)
            } else {
                EmptyHint(title: "选择一条消息", systemImage: "sparkles",
                          detail: "在任意列表里点 ✦ 或右键消息，分析结果会显示在这里。")
                    .padding(.top, 80)
            }
        }
        .animation(DS.ease, value: model.inspected?.id)
    }
}
