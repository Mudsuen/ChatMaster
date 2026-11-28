import AppKit
import LensCore
import MudsUI
import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var isSidebarVisible = true
    @State private var showInspector = true
    @FocusState private var searchFocused: Bool

    private let panelCurve = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.2)

    private var inspectorVisible: Bool {
        showInspector && model.section.supportsInspector
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                if isSidebarVisible {
                    CompactSidebar(topInset: 44)
                        .frame(width: 166)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Rectangle()
                        .fill(DS.edge)
                        .frame(width: 1)
                }

                VStack(spacing: 0) {
                    topBar
                    Rectangle().fill(DS.edge).frame(height: 1)

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
                    .frame(minWidth: 512, maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .animation(panelCurve, value: inspectorVisible)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.bg)
            }

            TopTrafficChrome(
                isSidebarVisible: $isSidebarVisible.animation(panelCurve),
                canGoBack: model.canGoBack,
                canGoForward: model.canGoForward,
                goBack: { model.goBack() },
                goForward: { model.goForward() }
            )
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 680, minHeight: 460)
        .background(DS.bg)
        .onAppear {
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .onChange(of: model.inspected) { _, m in
            if m != nil {
                withAnimation(panelCurve) { showInspector = true }
            }
        }
        .onChange(of: model.focusSearchTrigger) { _, _ in
            searchFocused = true
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(topTitle)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Theme.chatTitle)
                    .lineLimit(1)
                if let sub = topSubtitle {
                    Text(sub)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DS.ink4)
                        .lineLimit(1)
                }
            }
            .padding(.leading, isSidebarVisible ? 16 : 162)

            Spacer(minLength: 8)

            globalSearchField

            if model.section == .dashboard {
                BSegmented(
                    selection: $model.dashboardPeriod,
                    options: AppModel.DashboardPeriod.allCases.map { ($0, $0.title) },
                    compact: true
                )
            } else if model.section == .live {
                BSegmented(
                    selection: $model.liveFilter,
                    options: [(.all, "全部"), (.incoming, "收到"), (.privateOnly, "私聊"), (.watched, "关注")],
                    compact: true
                )
            }

            if model.section.supportsInspector {
                Button {
                    withAnimation(panelCurve) { showInspector.toggle() }
                } label: {
                    Image(systemName: "sidebar.trailing")
                        .foregroundStyle(showInspector ? DS.ink : DS.ink4)
                }
                .buttonStyle(IconButtonStyle(size: 26))
                .help(showInspector ? "隐藏分析面板" : "显示分析面板")
            }
        }
        .padding(.trailing, 14)
        .frame(height: 40)
        .background(WindowDragArea())
    }

    private var globalSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(searchFocused ? DS.pick : DS.ink4)
            TextField("搜索聊天记录… (⌘K)", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onSubmit { model.submitGlobalSearch() }
            if !model.searchQuery.isEmpty {
                Button {
                    model.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.ink5)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .frame(minWidth: 150, idealWidth: 210, maxWidth: 250)
        .background(DS.wash, in: Capsule())
        .overlay(
            Capsule().strokeBorder(searchFocused ? DS.pick.opacity(0.65) : DS.edge, lineWidth: searchFocused ? 1.25 : 0.75)
        )
        .animation(DS.ease, value: searchFocused)
    }

    private var topTitle: String {
        if model.section == .dashboard {
            let hour = Calendar.current.component(.hour, from: Date())
            return hour < 6 ? "夜深了" : hour < 12 ? "早上好" : hour < 18 ? "下午好" : "晚上好"
        }
        return model.section.title
    }

    private var topSubtitle: String? {
        switch model.section {
        case .dashboard:
            guard let ts = model.dashboard?.stats.firstTs, ts > 0 else { return nil }
            return "始于 \(Fmt.day.string(from: Date(timeIntervalSince1970: TimeInterval(ts))))"
        case .live:
            return model.lastSync.map { "更新于 \(Fmt.time.string(from: $0))" }
        default:
            return nil
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

/// Sidebar toggle and Back/Forward buttons positioned directly beside the macOS traffic lights.
private struct TopTrafficChrome: View {
    @Binding var isSidebarVisible: Bool
    var canGoBack: Bool
    var canGoForward: Bool
    var goBack: () -> Void
    var goForward: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            chromeButton(
                systemImage: "sidebar.left",
                width: 26,
                help: isSidebarVisible ? "隐藏侧边栏" : "显示侧边栏",
                isEnabled: true
            ) {
                isSidebarVisible.toggle()
            }
            chromeButton(
                systemImage: "chevron.left",
                width: 24,
                help: "返回 (⌘[)",
                isEnabled: canGoBack,
                action: goBack
            )
            chromeButton(
                systemImage: "chevron.right",
                width: 24,
                help: "前进 (⌘])",
                isEnabled: canGoForward,
                action: goForward
            )
        }
        .frame(height: 40)
        .padding(.leading, 76)
    }

    private func chromeButton(
        systemImage: String,
        width: CGFloat,
        help: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: width, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(TopChromeButtonStyle())
        .disabled(!isEnabled)
        .help(help)
    }
}

private struct TopChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BodyView(configuration: configuration)
    }

    private struct BodyView: View {
        @Environment(\.isEnabled) private var isEnabled
        @State private var hover = false
        let configuration: Configuration

        var body: some View {
            configuration.label
                .foregroundStyle(Color.primary)
                .opacity(isEnabled ? (configuration.isPressed ? 0.55 : (hover ? 0.92 : 0.68)) : 0.25)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hover && isEnabled ? DS.wash2 : .clear)
                )
                .scaleEffect(configuration.isPressed ? 0.95 : 1)
                .onHover { hover = $0 }
                .animation(DS.ease, value: hover)
        }
    }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}

/// Compact left navigation sidebar starting cleanly below the traffic lights (no redundant brand header).
struct CompactSidebar: View {
    @EnvironmentObject var model: AppModel
    @State private var hovered: AppSection?
    var topInset: CGFloat = 42

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element.id) { index, item in
                navRow(item, index: index)
            }

            Spacer(minLength: 8)
            SyncFooter()
        }
        .padding(.top, topInset)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.sidebar.overlay(alignment: .top) {
            WindowDragArea().frame(height: topInset)
        })
    }

    private func navRow(_ item: AppSection, index: Int) -> some View {
        let on = model.section == item
        let hot = hovered == item
        let n = badge(for: item)
        return Button {
            withAnimation(DS.ease) { model.navigate(to: item) }
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
