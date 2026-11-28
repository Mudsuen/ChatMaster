import AppKit
import LensCore
import MudsUI
import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var showInspector = true
    @State private var topBarWidth: CGFloat = 900
    @FocusState private var searchFocused: Bool

    private let panelCurve = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.2)

    private var inspectorVisible: Bool {
        guard showInspector && model.section.supportsInspector else { return false }
        if model.inspected == nil && topBarWidth > 0 && topBarWidth < 680 {
            return false
        }
        return true
    }

    private var inspectorWidth: CGFloat {
        (topBarWidth > 0 && topBarWidth < 760) ? 236 : 280
    }

    var body: some View {
        HStack(spacing: 0) {
            IconNavRail(topInset: 50)
                .frame(width: 76)
            Rectangle()
                .fill(DS.edge)
                .frame(width: 1)

            VStack(spacing: 0) {
                topBar
                Rectangle().fill(DS.edge).frame(height: 1)

                ZStack(alignment: .topTrailing) {
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
                                .frame(width: inspectorWidth)
                                .frame(maxHeight: .infinity)
                                .background(DS.bg)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .frame(minWidth: 512, maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .animation(panelCurve, value: inspectorVisible)

                    if model.isSearchOpen {
                        Color.black.opacity(0.18)
                            .contentShape(Rectangle())
                            .onTapGesture { closeSearch() }
                            .transition(.opacity)
                        SearchOverlayView(close: closeSearch)
                            .padding(.top, 8)
                            .padding(.horizontal, 14)
                            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topTrailing)))
                    }
                }
                .animation(panelCurve, value: model.isSearchOpen)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DS.bg)
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
            withAnimation(panelCurve) { model.isSearchOpen = true }
            searchFocused = true
        }
        .onChange(of: searchFocused) { _, focused in
            if focused {
                withAnimation(panelCurve) { model.isSearchOpen = true }
            }
        }
    }

    private func closeSearch() {
        withAnimation(panelCurve) { model.isSearchOpen = false }
        searchFocused = false
    }

    private var topBar: some View {
        let hideSub = topBarWidth > 0 && topBarWidth < 560
        let iconSearch = topBarWidth > 0 && topBarWidth < 500 && !model.isSearchOpen && !searchFocused
        return HStack(spacing: 10) {
            HStack(spacing: 2) {
                navArrowButton(systemImage: "chevron.left", help: "返回 (⌘[)", enabled: model.canGoBack) {
                    model.goBack()
                }
                navArrowButton(systemImage: "chevron.right", help: "前进 (⌘])", enabled: model.canGoForward) {
                    model.goForward()
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(topTitle)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Theme.chatTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if hasSyncIssue {
                    Button { model.syncNow() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10.5))
                            if !hideSub {
                                Text(syncIssueLabel)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                            }
                        }
                        .foregroundStyle(DS.warning)
                        .padding(.horizontal, hideSub ? 6 : 8)
                        .padding(.vertical, 3)
                        .background(DS.warning.opacity(0.14), in: Capsule())
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .help(syncIssueDetail)
                } else if !hideSub, let sub = topSubtitle {
                    Text(sub)
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(DS.ink4)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            Spacer(minLength: 8)

            if iconSearch {
                Button {
                    withAnimation(panelCurve) { model.isSearchOpen = true }
                    searchFocused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(DS.ink3)
                }
                .buttonStyle(IconButtonStyle(size: 26))
                .help("搜索聊天记录 (⌘K)")
            } else {
                globalSearchField
            }

            if model.section == .dashboard {
                BSegmented(
                    selection: $model.dashboardPeriod,
                    options: AppModel.DashboardPeriod.allCases.map { ($0, $0.title) },
                    compact: true
                )
                .fixedSize()
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
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .frame(height: 40)
        .background(WindowDragArea())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { topBarWidth = $0 }
    }

    private func navArrowButton(systemImage: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(TopChromeButtonStyle())
        .disabled(!enabled)
        .help(help)
    }

    private var globalSearchField: some View {
        let active = searchFocused || model.isSearchOpen
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? DS.pick : DS.ink4)
            TextField("搜索聊天记录… (⌘K)", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onSubmit { model.submitGlobalSearch() }
                .onKeyPress(.escape) {
                    closeSearch()
                    return .handled
                }
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
        .frame(minWidth: 130, idealWidth: 200, maxWidth: 240)
        .background(DS.wash, in: Capsule())
        .overlay(
            Capsule().strokeBorder(active ? DS.pick.opacity(0.65) : DS.edge, lineWidth: active ? 1.25 : 0.75)
        )
        .contentShape(Capsule())
        .simultaneousGesture(
            TapGesture().onEnded {
                withAnimation(panelCurve) { model.isSearchOpen = true }
            }
        )
        .animation(DS.ease, value: active)
    }

    private var topTitle: String {
        if model.section == .dashboard {
            let hour = Calendar.current.component(.hour, from: Date())
            return hour < 6 ? "夜深了" : hour < 12 ? "早上好" : hour < 18 ? "下午好" : "晚上好"
        }
        return model.section.title
    }

    private var hasSyncIssue: Bool {
        !model.syncErrors.isEmpty || !model.missingKeys.isEmpty
    }

    private var syncIssueLabel: String {
        !model.missingKeys.isEmpty ? "缺少密钥" : "同步异常"
    }

    private var syncIssueDetail: String {
        var lines: [String] = []
        if !model.missingKeys.isEmpty {
            lines.append("缺少密钥：\(model.missingKeys.joined(separator: ", "))")
        }
        lines.append(contentsOf: model.syncErrors.prefix(2))
        lines.append("点击立即重试同步")
        return lines.joined(separator: "\n")
    }

    private var topSubtitle: String? {
        switch model.section {
        case .dashboard:
            return "更新于 \(Fmt.time.string(from: model.lastSync ?? Date()))"
        default:
            return nil
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .dashboard: DashboardView()
        case .chats: ChatsView()
        case .ai: AIAnalysisView()
        case .insight: InsightView()
        case .briefing: BriefingView()
        }
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

/// Vertical Muse-style circular icon rail aligned under the macOS traffic lights.
struct IconNavRail: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var hovered: AppSection?
    @State private var settingsHover = false
    var topInset: CGFloat = 50

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element.id) { index, item in
                railItem(item, index: index)
            }

            Spacer(minLength: 12)

            Button {
                openSettings()
            } label: {
                railGlyph("gearshape", active: false, hovered: settingsHover)
            }
            .buttonStyle(.plain)
            .onHover { settingsHover = $0 }
            .animation(DS.ease, value: settingsHover)
            .help("设置 (⌘,)")
        }
        .padding(.top, topInset)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DS.sidebar.overlay(alignment: .top) {
            WindowDragArea().frame(height: topInset)
        })
    }

    private func railItem(_ item: AppSection, index: Int) -> some View {
        let on = model.section == item
        let hot = hovered == item
        let n = badge(for: item)
        return Button {
            withAnimation(DS.ease) { model.navigate(to: item) }
        } label: {
            railGlyph(item.icon, active: on, hovered: hot)
                .overlay(alignment: .topTrailing) {
                    if n > 0 {
                        Text(n > 99 ? "99+" : "\(n)")
                            .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4.5)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(DS.error, in: Capsule())
                            .overlay(Capsule().strokeBorder(DS.sidebar, lineWidth: 1.5))
                            .offset(x: 2, y: -1)
                            .contentTransition(.numericText())
                    }
                }
        }
        .buttonStyle(.plain)
        .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command) : nil)
        .onHover { hovered = $0 ? item : (hovered == item ? nil : hovered) }
        .animation(DS.ease, value: hot)
        .help("\(item.title) (⌘\(index + 1))")
    }

    private func railGlyph(_ systemImage: String, active: Bool, hovered: Bool) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 18.5, weight: active ? .semibold : .regular))
            .foregroundStyle(active ? DS.ink : (hovered ? DS.ink2 : DS.ink3))
            .frame(width: 42, height: 42)
            .background {
                if active {
                    Circle()
                        .fill(DS.wash2)
                        .overlay(Circle().strokeBorder(DS.edge.opacity(0.85), lineWidth: 0.75))
                } else if hovered {
                    Circle().fill(DS.wash)
                }
            }
            .contentShape(Circle())
    }

    private func badge(for s: AppSection) -> Int {
        switch s {
        case .chats: return model.chats.reduce(0) { $0 + ($1.kind == .person && !$1.isMuted && !$1.isFolded ? $1.unread : 0) }
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
                            Text(model.senderLabel(m))
                                .font(DS.title)
                                .foregroundStyle(DS.ink)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text("\(model.displayName(m.chat)) · \(Fmt.smart(m.date))")
                                .font(DS.sub)
                                .foregroundStyle(DS.ink4)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 4)
                        Button { model.openChat(m.chat, focusMessage: m) } label: { Image(systemName: "arrow.up.right") }
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
