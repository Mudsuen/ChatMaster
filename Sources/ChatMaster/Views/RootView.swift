import LensCore
import MudsUI
import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            LineSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 216, max: 260)
        } detail: {
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
                            .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                }
                .frame(minWidth: 560, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
                .background(DS.bg)
                .animation(DS.ease, value: model.section)
                ToastStackView().padding(20)
            }
        }
        .inspector(isPresented: $showInspector) {
            InspectorView()
                .background(DS.bg)
                .inspectorColumnWidth(min: 320, ideal: 380, max: 500)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showInspector.toggle() } label: { Label("分析面板", systemImage: "sidebar.trailing") }
                    .help("显示/隐藏分析面板")
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .navigationTitle("")
        .onChange(of: model.inspected) { _, m in if m != nil { showInspector = true } }
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

/// Navigation as a column of lines that extend toward the hovered / current item.
struct LineSidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        MULineNav(
            items: AppSection.allCases.map {
                MULineNavItem(id: $0, title: $0.title, systemImage: $0.icon, badge: badge(for: $0))
            },
            selection: $model.section
        ) {
            MUBrandHeader(title: "ChatMaster", active: model.analyses.values.contains { $0.isLoading })
        } footer: {
            SyncFooter()
        }
    }

    private func badge(for s: AppSection) -> Int {
        switch s {
        case .chats: return model.chats.reduce(0) { $0 + ($1.kind == .person ? $1.unread : 0) }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                PulseDot(color: model.syncErrors.isEmpty ? DS.ok : DS.warning)
                Text(model.syncErrors.isEmpty ? "实时同步中" : "同步有错误").font(.system(size: 12, weight: .medium)).foregroundStyle(DS.ink2)
                Spacer()
                Button { model.syncNow() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(IconButtonStyle(size: 22)).help("立即同步（⌘R）")
            }
            if let t = model.lastSync {
                HStack(spacing: 0) {
                    RollingNumber(value: model.totalIndexed, font: DS.micro.monospacedDigit(), format: { "\($0)" })
                    Text(" 条 · \(Fmt.time.string(from: t))").font(DS.micro.monospacedDigit())
                }
                .foregroundStyle(DS.ink5)
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
        .padding(12)
        .background(DS.card, in: RoundedRectangle(cornerRadius: DS.innerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.innerRadius, style: .continuous).strokeBorder(DS.edge, lineWidth: 1))
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
                .padding(16)
                .id(m.id)
                .transition(.opacity.combined(with: .offset(x: 12)))
            } else {
                EmptyHint(title: "选择一条消息", systemImage: "sparkles",
                          detail: "在任意列表里点 ✦ 或右键消息，分析结果会显示在这里。")
                    .padding(.top, 80)
            }
        }
        .animation(DS.spring, value: model.inspected?.id)
    }
}
