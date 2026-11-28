import LensCore
import MudsUI
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    @State private var range: Range = .day
    @State private var selectedSlotKey: HeatSlotKey?
    @State private var slotSummary: HeatmapSlotSummary?
    @State private var loadingSlot = false

    enum Range: Hashable { case day, week }

    private var snap: AppModel.DashboardSnapshot {
        model.dashboard ?? AppModel.DashboardSnapshot(period: model.dashboardPeriod)
    }

    private var animateOnAppear: Bool { !model.dashboardAnimatedOnce }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                kpiStrip
                volumeCard
                HStack(alignment: .top, spacing: 10) {
                    Card(padding: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle(title: "活跃时段", subtitle: "近一年 · 星期 × 小时 · 点击查看对话")
                            InteractiveHeatGrid(
                                cells: snap.heat.map { MUHeatCell(weekday: $0.weekday, hour: $0.hour, count: $0.count) },
                                selected: selectedSlotKey
                            ) { w, h in
                                openHeatmapSlot(weekday: w, hour: h)
                            }
                        }
                    }
                    .popover(item: $selectedSlotKey, arrowEdge: .trailing) { key in
                        HeatSlotPopover(
                            key: key,
                            summary: slotSummary,
                            loading: loadingSlot,
                            onClose: { selectedSlotKey = nil }
                        )
                        .environmentObject(model)
                    }

                    Card(padding: 14) {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionTitle(title: "消息构成", subtitle: "每点 0.5% · 指向查看")
                            if !snap.kinds.isEmpty {
                                CompactDotField(
                                    items: snap.kinds.map { MUSegmentItem(label: $0.kind, count: $0.count) },
                                    cols: 25,
                                    rows: 8,
                                    caption: "条消息，近一年",
                                    animate: animateOnAppear
                                )
                            }
                        }
                    }
                    .frame(maxWidth: 320)
                }
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(
                            title: topTitle,
                            subtitle: "深色为我发出的部分"
                        )
                        VStack(spacing: 2) {
                            ForEach(Array(snap.top.enumerated()), id: \.element.id) { i, c in
                                Button { model.openChat(c.chat) } label: {
                                    TopChatRow(
                                        rank: i + 1,
                                        item: c,
                                        maxCount: snap.top.first?.count ?? 1,
                                        animate: animateOnAppear
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
        .defaultScrollAnchor(.top)
        .navigationTitle("")
        .task(id: model.revision / 20) { model.loadDashboard() }
        .onChange(of: model.dashboardPeriod) { _, _ in model.loadDashboard(force: true) }
        .onChange(of: model.dashboard != nil) { _, ready in
            if ready && !model.dashboardAnimatedOnce {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    model.dashboardAnimatedOnce = true
                }
            }
        }
    }

    private var kpiStrip: some View {
        let s = snap.stats
        let msgLabel: String = {
            switch model.dashboardPeriod {
            case .today: return "今日消息"
            case .week: return "近 7 天消息"
            case .month: return "近 30 天消息"
            case .all: return "总消息"
            }
        }()
        let shareText = s.total > 0 ? "\(Int(Double(s.sentByMe) / Double(s.total) * 100))%" : "—"
        let chatNote = model.dashboardPeriod == .all && (s.contacts > 0 || s.groups > 0)
            ? "\(s.contacts) 好友 · \(s.groups) 群"
            : nil

        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            MetricTile(title: msgLabel, value: Fmt.grouped(Double(s.total)), icon: "text.bubble.fill", tint: DS.warning)
            MetricTile(title: "活跃会话", value: Fmt.grouped(Double(s.activeChats)), icon: "bubble.left.and.bubble.right.fill",
                       tint: DS.ok, note: chatNote)
            MetricTile(title: "我发出占比", value: shareText, icon: "paperplane.fill", tint: Color(muHex: 0x14B8A6))
            Button {
                withAnimation(DS.ease) { model.section = .pending }
            } label: {
                MetricTile(title: "待回复", value: "\(snap.pendingCount)", icon: "tray.full.fill",
                           tint: snap.pendingCount > 0 ? DS.error : DS.pick,
                           note: snap.pendingCount > 0 ? "点击处理" : "已清空")
            }
            .buttonStyle(.plain)
        }
    }

    private var volumeCard: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(
                    title: "消息量",
                    subtitle: range == .day ? "近 90 天，每天" : "近 26 周，每周",
                    trailing: AnyView(
                        HStack(spacing: 12) {
                            HStack(spacing: 10) {
                                legend(DS.ink, "发出")
                                legend(DS.ink.opacity(0.22), "收到")
                            }
                            BSegmented(selection: $range, options: [(.day, "日"), (.week, "周")], compact: true)
                        }
                    )
                )
                MessageVolumeBars(data: bars, height: 140, animate: animateOnAppear)
            }
        }
    }

    private var topTitle: String {
        switch model.dashboardPeriod {
        case .today: return "今日最常聊"
        case .week: return "近 7 天最常聊"
        case .month: return "近 30 天最常聊"
        case .all: return "历史最常聊"
        }
    }

    private var bars: [BarDatum] {
        switch range {
        case .day:
            return snap.daily.suffix(90).enumerated().map { i, d in
                BarDatum(id: i, label: Fmt.shortDay.string(from: d.date), mine: d.mine, theirs: d.total - d.mine)
            }
        case .week:
            let days = Array(snap.daily.suffix(182))
            return stride(from: 0, to: days.count, by: 7).enumerated().map { i, start in
                let chunk = days[start..<min(start + 7, days.count)]
                let mine = chunk.reduce(0) { $0 + $1.mine }, total = chunk.reduce(0) { $0 + $1.total }
                return BarDatum(id: i, label: "\(Fmt.shortDay.string(from: chunk.first!.date)) 起一周", mine: mine, theirs: total - mine)
            }
        }
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 8, height: 8)
            Text(t).font(DS.micro).foregroundStyle(DS.ink4)
        }
    }

    private var header: some View {
        let hour = Calendar.current.component(.hour, from: Date())
        let hello = hour < 6 ? "夜深了" : hour < 12 ? "早上好" : hour < 18 ? "下午好" : "晚上好"
        return HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(hello)
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(Theme.chatTitle)
                if snap.stats.firstTs > 0 {
                    Text("始于 \(Fmt.day.string(from: Date(timeIntervalSince1970: TimeInterval(snap.stats.firstTs))))")
                        .font(DS.sub)
                        .foregroundStyle(DS.ink4)
                }
            }
            Spacer(minLength: 8)
            BSegmented(
                selection: $model.dashboardPeriod,
                options: AppModel.DashboardPeriod.allCases.map { ($0, $0.title) },
                compact: true
            )
        }
    }

    private func openHeatmapSlot(weekday: Int, hour: Int) {
        let key = HeatSlotKey(weekday: weekday, hour: hour)
        selectedSlotKey = key
        slotSummary = nil
        loadingSlot = true
        guard let store = model.store else { loadingSlot = false; return }
        Task.detached(priority: .userInitiated) {
            let summary = store.heatmapSlot(weekday: weekday, hour: hour)
            await MainActor.run {
                if selectedSlotKey == key {
                    slotSummary = summary
                    loadingSlot = false
                }
            }
        }
    }
}

private struct MetricTile: View {
    var title: String
    var value: String
    var icon: String
    var tint: Color
    var note: String? = nil

    var body: some View {
        Card(padding: 13) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 20, height: 20)
                        .background(tint.opacity(0.12), in: Circle())
                    Text(title)
                        .font(DS.sub)
                        .foregroundStyle(DS.ink4)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text(value)
                    .font(.system(size: 23, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.chatTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                if let note {
                    Text(note)
                        .font(DS.micro)
                        .foregroundStyle(DS.ink5)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// Custom stacked bar chart with column-wash + accent-lifted hover and single-line non-wrapping tooltip.
private struct MessageVolumeBars: View {
    var data: [BarDatum]
    var height: CGFloat
    var animate: Bool
    @State private var hover: Int?
    @State private var grown: Bool

    init(data: [BarDatum], height: CGFloat = 140, animate: Bool) {
        self.data = data
        self.height = height
        self.animate = animate
        _grown = State(initialValue: !animate)
    }

    var body: some View {
        GeometryReader { geo in
            let n = max(data.count, 1)
            let gap: CGFloat = n > 60 ? 2 : (n > 30 ? 3 : 5)
            let w = max(2, (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            let plotH = geo.size.height - 6
            let maxV = CGFloat(max(1, data.map(\.total).max() ?? 1))
            let corner = min(w / 2, 4)

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0 ..< 3, id: \.self) { _ in
                        Rectangle().fill(DS.edge).frame(height: 1)
                        Spacer()
                    }
                }

                if let i = hover, let idx = data.firstIndex(where: { $0.id == i }) {
                    let x = CGFloat(idx) * (w + gap)
                    let colW = max(w + 6, 10)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(DS.ink.opacity(0.07))
                        .frame(width: colW, height: geo.size.height)
                        .offset(x: x - (colW - w) / 2, y: 0)
                }

                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(Array(data.enumerated()), id: \.element.id) { idx, d in
                        let isHover = hover == d.id
                        let hT = CGFloat(d.theirs) / maxV * plotH
                        let hM = CGFloat(d.mine) / maxV * plotH
                        VStack(spacing: d.theirs > 0 && d.mine > 0 ? 1.5 : 0) {
                            RoundedRectangle(cornerRadius: corner, style: .continuous)
                                .fill(isHover ? DS.ink.opacity(0.46) : DS.ink.opacity(0.20))
                                .frame(height: d.theirs > 0 ? max(hT, 1.5) : 0)
                            RoundedRectangle(cornerRadius: corner, style: .continuous)
                                .fill(isHover ? DS.pick : DS.ink)
                                .frame(height: d.mine > 0 ? max(hM, 1.5) : 0)
                        }
                        .frame(width: w)
                        .scaleEffect(x: 1, y: grown ? 1 : 0.02, anchor: .bottom)
                        .opacity(hover == nil || isHover ? 1 : 0.32)
                        .animation(animate ? DS.spring.delay(Double(idx) * 0.004) : .none, value: grown)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
                .animation(DS.ease, value: hover)

                if let i = hover, let idx = data.firstIndex(where: { $0.id == i }) {
                    let d = data[idx]
                    let x = CGFloat(idx) * (w + gap)
                    let tipW: CGFloat = 180
                    tooltip(d)
                        .fixedSize()
                        .offset(x: min(max(0, x + w / 2 - tipW / 2), max(0, geo.size.width - tipW)), y: -6)
                        .animation(DS.ease, value: hover)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let idx = Int(p.x / (w + gap))
                    hover = data.indices.contains(idx) ? data[idx].id : nil
                case .ended:
                    hover = nil
                }
            }
        }
        .frame(height: height)
        .onAppear {
            if !grown { grown = true }
        }
    }

    private func tooltip(_ d: BarDatum) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(d.label)
                .font(DS.micro)
                .foregroundStyle(DS.ink4)
                .lineLimit(1)
            HStack(spacing: 12) {
                legendDot(DS.pick, "发出", d.mine)
                legendDot(DS.ink.opacity(0.45), "收到", d.theirs)
            }
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(DS.raised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(DS.edge, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    private func legendDot(_ c: Color, _ label: String, _ v: Int) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 7, height: 7)
            Text("\(label) \(v)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(DS.ink)
                .lineLimit(1)
        }
    }
}

private struct HeatSlotKey: Identifiable, Hashable {
    var weekday: Int
    var hour: Int
    var id: Int { weekday * 24 + hour }
}

private struct InteractiveHeatGrid: View {
    var cells: [MUHeatCell]
    var selected: HeatSlotKey?
    var onSelect: (Int, Int) -> Void

    @State private var hover: MUHeatCell.ID?
    private let days = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        let maxV = max(cells.map(\.count).max() ?? 1, 1)
        let focus = cells.first { $0.id == hover }
        let byID = Dictionary(cells.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(focus.map { "周\(days[$0.weekday]) \($0.hour):00" } ?? "最活跃")
                    .font(DS.sub).foregroundStyle(DS.ink4)
                Spacer()
                let peak = cells.max { $0.count < $1.count }
                Text(focus.map { "\($0.count) 条" } ?? peak.map { "周\(days[$0.weekday]) \($0.hour):00" } ?? "")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.chatTitle)
                    .contentTransition(.numericText())
            }
            .animation(DS.ease, value: hover)

            VStack(spacing: 3) {
                ForEach(0 ..< 7, id: \.self) { w in
                    HStack(spacing: 3) {
                        Text(days[w]).font(.system(size: 10)).foregroundStyle(DS.ink5).frame(width: 12)
                        ForEach(0 ..< 24, id: \.self) { h in
                            let cell = byID[w * 24 + h]
                            let v = cell?.count ?? 0
                            let isHover = hover != nil && hover == cell?.id
                            let isSelected = selected?.weekday == w && selected?.hour == h
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(v == 0 ? DS.wash : DS.ink.opacity(0.1 + 0.9 * sqrt(Double(v) / Double(maxV))))
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .strokeBorder(isSelected || isHover ? DS.pick : .clear, lineWidth: 1.5)
                                )
                                .scaleEffect(isHover ? 1.18 : 1)
                                .zIndex(isHover || isSelected ? 1 : 0)
                                .animation(DS.ease, value: isHover)
                                .onHover { if $0 { hover = cell?.id } }
                                .onTapGesture {
                                    if v > 0 { onSelect(w, h) }
                                }
                        }
                    }
                }
                HStack(spacing: 3) {
                    Text("").frame(width: 12)
                    ForEach([0, 6, 12, 18, 23], id: \.self) { h in
                        Text("\(h)").font(.system(size: 10)).foregroundStyle(DS.ink5)
                        if h != 23 { Spacer() }
                    }
                }
            }
            .onHover { if !$0 { hover = nil } }
        }
    }
}

private struct HeatSlotPopover: View {
    @EnvironmentObject var model: AppModel
    var key: HeatSlotKey
    var summary: HeatmapSlotSummary?
    var loading: Bool
    var onClose: () -> Void
    @State private var chatFilter: String?

    private let days = ["一", "二", "三", "四", "五", "六", "日"]

    private var filteredMessages: [LensMessage] {
        guard let msgs = summary?.messages else { return [] }
        guard let chatFilter else { return msgs }
        return msgs.filter { $0.chat == chatFilter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("周\(days[key.weekday]) \(String(format: "%02d", key.hour)):00–\(String(format: "%02d", key.hour)):59")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.chatTitle)
                    if let summary {
                        Text("近一年 · 共 \(summary.total) 条消息")
                            .font(DS.micro)
                            .foregroundStyle(DS.ink4)
                    }
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 24))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Rectangle().fill(DS.edge).frame(height: 1)

            if loading {
                VStack(spacing: 10) {
                    ThinkingOrb(size: 26)
                    Text("加载该时段对话…").font(DS.sub).foregroundStyle(DS.ink4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let summary {
                if !summary.topChats.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            Button {
                                chatFilter = nil
                            } label: {
                                Text("全部")
                                    .font(DS.micro)
                                    .foregroundStyle(chatFilter == nil ? DS.onSlab : DS.ink3)
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .background(chatFilter == nil ? DS.slab : DS.wash, in: Capsule())
                            }
                            .buttonStyle(.plain)

                            ForEach(summary.topChats) { c in
                                let on = chatFilter == c.chat
                                Button {
                                    chatFilter = on ? nil : c.chat
                                } label: {
                                    HStack(spacing: 5) {
                                        AvatarView(username: c.chat, size: 16)
                                        Text(c.display).font(DS.micro).lineLimit(1)
                                        Text("\(c.count)").font(.system(size: 10).monospacedDigit()).opacity(0.75)
                                    }
                                    .foregroundStyle(on ? DS.onSlab : DS.ink2)
                                    .padding(.horizontal, 8).padding(.vertical, 3.5)
                                    .background(on ? DS.slab : DS.wash, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                    Rectangle().fill(DS.edge).frame(height: 1)
                }

                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredMessages) { m in
                            Button {
                                onClose()
                                model.openChat(m.chat)
                                model.inspect(m, analyze: false)
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    AvatarView(username: m.chat, size: 26)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 5) {
                                            Text(model.displayName(m.chat))
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(Theme.chatTitle)
                                                .lineLimit(1)
                                            if m.chat.hasSuffix("@chatroom") || m.isSelf {
                                                Text(model.senderLabel(m))
                                                    .font(DS.micro)
                                                    .foregroundStyle(DS.ink4)
                                                    .lineLimit(1)
                                            }
                                            Spacer(minLength: 4)
                                            Text(Fmt.dayTime.string(from: m.date))
                                                .font(.system(size: 10).monospacedDigit())
                                                .foregroundStyle(DS.ink5)
                                        }
                                        Text(m.text)
                                            .font(.system(size: 12))
                                            .foregroundStyle(DS.ink3)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(DS.wash.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                }
                .overlay {
                    if filteredMessages.isEmpty {
                        EmptyHint(title: "暂无消息", systemImage: "tray")
                    }
                }
            }
        }
        .frame(width: 440, height: 420)
        .background(DS.bg)
    }
}

private struct CompactDotField: View {
    var items: [MUSegmentItem]
    var cols: Int
    var rows: Int
    var caption: String
    var animate: Bool

    @State private var hover: String?
    @State private var appeared: Bool

    init(items: [MUSegmentItem], cols: Int = 25, rows: Int = 8, caption: String = "条消息，近一年", animate: Bool) {
        self.items = items
        self.cols = cols
        self.rows = rows
        self.caption = caption
        self.animate = animate
        _appeared = State(initialValue: !animate)
    }

    private var groups: [MUSegmentItem] {
        let top = Array(items.prefix(6))
        let rest = items.dropFirst(6).reduce(0) { $0 + $1.count }
        return rest > 0 ? top + [MUSegmentItem(label: "其他", count: rest)] : top
    }

    private static func allocate(_ counts: [Int], cells: Int) -> [Int] {
        let total = max(1, counts.reduce(0, +))
        let raw = counts.map { Double($0) / Double(total) * Double(cells) }
        var alloc = raw.map { Int($0) }
        let order = raw.enumerated().sorted { ($0.element - floor($0.element)) > ($1.element - floor($1.element)) }.map(\.offset)
        var left = counts.reduce(0, +) == 0 ? 0 : cells - alloc.reduce(0, +)
        for i in order where left > 0 { alloc[i] += 1; left -= 1 }
        return alloc
    }

    var body: some View {
        let gs = groups
        let total = max(1, gs.reduce(0) { $0 + $1.count })
        let alloc = Self.allocate(gs.map(\.count), cells: cols * rows)
        var owner: [Int] = []
        for (i, n) in alloc.enumerated() { owner += Array(repeating: i, count: n) }
        let focus = gs.firstIndex { $0.label == hover }
        let shown = focus.map { gs[$0] }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(shown.map { "\(Int((Double($0.count) / Double(total) * 100).rounded()))%" } ?? Fmt.count(total))
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.chatTitle)
                Text(shown.map { "\($0.label) · \(Fmt.count($0.count)) 条" } ?? caption)
                    .font(DS.sub).foregroundStyle(DS.ink4)
            }
            .animation(DS.ease, value: hover)

            VStack(spacing: 3) {
                ForEach(0 ..< rows, id: \.self) { r in
                    HStack(spacing: 3) {
                        ForEach(0 ..< cols, id: \.self) { c in
                            let i = c * rows + r
                            let k = i < owner.count ? owner[i] : -1
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(k >= 0 ? DS.palette[k % DS.palette.count] : DS.wash)
                                .opacity(focus == nil || focus == k ? 1 : 0.16)
                                .aspectRatio(1, contentMode: .fit)
                                .scaleEffect(appeared ? 1 : 0.2)
                                .animation(animate ? DS.bouncy.delay(Double(c) * 0.012) : .none, value: appeared)
                                .onHover { inside in if inside, k >= 0 { hover = gs[k].label } }
                        }
                    }
                }
            }
            .animation(DS.ease, value: hover)
            .onHover { if !$0 { hover = nil } }

            FlowLayout(spacing: 5) {
                ForEach(Array(gs.enumerated()), id: \.element.label) { i, g in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(DS.palette[i % DS.palette.count]).frame(width: 7, height: 7)
                        Text(g.label).font(DS.micro).foregroundStyle(hover == g.label ? DS.ink : DS.ink3)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(hover == g.label ? DS.wash2 : DS.wash, in: Capsule())
                    .onHover { hover = $0 ? g.label : nil }
                }
            }
        }
        .onAppear {
            if !appeared { appeared = true }
        }
    }
}

struct TopChatRow: View {
    var rank: Int = 0
    var item: ChatCount
    var maxCount: Int
    var animate = true
    @State private var hover = false
    @State private var grown: Bool

    init(rank: Int = 0, item: ChatCount, maxCount: Int, animate: Bool = true) {
        self.rank = rank
        self.item = item
        self.maxCount = maxCount
        self.animate = animate
        _grown = State(initialValue: !animate)
    }

    var body: some View {
        HStack(spacing: 10) {
            if rank > 0 {
                Text("\(rank)").font(DS.micro.monospacedDigit()).foregroundStyle(DS.ink5).frame(width: 16)
            }
            AvatarView(username: item.chat, size: 24)
            Text(item.display).font(DS.body).foregroundStyle(Theme.chatTitle).lineLimit(1).frame(width: 150, alignment: .leading)
            GeometryReader { geo in
                let w = geo.size.width * CGFloat(item.count) / CGFloat(max(maxCount, 1)) * (grown ? 1 : 0)
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.ink.opacity(0.14)).frame(width: max(w, 4))
                    Capsule().fill(DS.ink).frame(width: max(w * CGFloat(item.mine) / CGFloat(max(item.count, 1)), 2))
                }
                .frame(height: 8)
                .frame(maxHeight: .infinity)
            }
            Text(Fmt.grouped(Double(item.count)))
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .foregroundStyle(DS.ink3)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .frame(height: 32)
        .background(hover ? DS.wash : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(DS.ease, value: hover)
        .onAppear {
            if !grown {
                withAnimation(animate ? DS.spring.delay(0.05 * Double(rank)) : .none) { grown = true }
            }
        }
    }
}
