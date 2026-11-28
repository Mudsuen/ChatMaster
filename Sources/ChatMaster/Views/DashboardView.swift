import LensCore
import MudsUI
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    @State private var overview = Overview()
    @State private var daily: [DayCount] = []
    @State private var heat: [HeatCell] = []
    @State private var kinds: [KindCount] = []
    @State private var top: [ChatCount] = []
    @State private var range: Range = .day
    @State private var loaded = false

    enum Range: Hashable { case day, week }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    StatTile(title: "今日消息", value: overview.today, icon: "sun.max.fill", tint: DS.warning)
                    StatTile(title: "近 7 天", value: overview.week, icon: "calendar", tint: DS.pick)
                    StatTile(title: "今日活跃会话", value: overview.activeChatsToday, icon: "bubble.left.and.bubble.right.fill", tint: DS.ok)
                    StatTile(title: "总消息", value: overview.total, icon: "archivebox.fill", tint: Color(muHex: 0x8B5CF6))
                    StatTile(title: "我发出的占比",
                             text: overview.total > 0 ? "\(Int(Double(overview.sentByMe) / Double(overview.total) * 100))%" : "—",
                             icon: "paperplane.fill", tint: Color(muHex: 0x14B8A6))
                    StatTile(title: "好友 / 群", text: "\(overview.contacts) / \(overview.groups)", icon: "person.2.fill",
                             tint: Color(muHex: 0xF43F5E))
                }
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionTitle(title: "消息量", subtitle: range == .day ? "近 90 天，每天" : "近 26 周，每周",
                                     trailing: AnyView(BSegmented(selection: $range, options: [(.day, "日"), (.week, "周")])))
                        StackedBarsView(data: bars, height: 170)
                        HStack(spacing: 14) {
                            legend(DS.ink, "发出")
                            legend(DS.ink.opacity(0.22), "收到")
                        }
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionTitle(title: "活跃时段", subtitle: "近一年 · 星期 × 小时")
                            HeatGridView(cells: heat.map { MUHeatCell(weekday: $0.weekday, hour: $0.hour, count: $0.count) })
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionTitle(title: "消息构成", subtitle: "每个点约等于 0.5% · 指向查看")
                            if !kinds.isEmpty {
                                DotFieldView(items: kinds.map { MUSegmentItem(label: $0.kind, count: $0.count) },
                                             cols: 20, rows: 10, caption: "条消息，近一年")
                            }
                        }
                    }
                    .frame(maxWidth: 340)
                }
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "近 30 天最常聊", subtitle: "深色为我发出的部分")
                        ForEach(Array(top.enumerated()), id: \.element.id) { i, c in
                            Button { model.openChat(c.chat) } label: {
                                TopChatRow(rank: i + 1, item: c, maxCount: top.first?.count ?? 1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.top)
        .navigationTitle("")
        .task(id: model.revision / 20) { load() }
    }

    private var bars: [BarDatum] {
        switch range {
        case .day:
            return daily.suffix(90).enumerated().map { i, d in
                BarDatum(id: i, label: Fmt.shortDay.string(from: d.date), mine: d.mine, theirs: d.total - d.mine)
            }
        case .week:
            let days = Array(daily.suffix(182))
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
        return VStack(alignment: .leading, spacing: 4) {
            Text(hello).font(.system(size: 30, weight: .semibold)).tracking(-0.6).foregroundStyle(DS.ink)
            if overview.firstTs > 0 {
                Text("从 \(Fmt.day.string(from: Date(timeIntervalSince1970: TimeInterval(overview.firstTs)))) 起的聊天记录，都在这里。")
                    .font(DS.body).foregroundStyle(DS.ink4)
            }
        }
        .padding(.bottom, 4)
    }

    private func load() {
        guard let store = model.store else { return }
        Task.detached(priority: .userInitiated) {
            let o = store.overview(), d = store.dailyCounts(days: 182), h = store.heatmap(), k = store.kindCounts(),
                t = store.topChats(days: 30, limit: 10)
            await MainActor.run {
                withAnimation(DS.spring) { overview = o; daily = d; heat = h; kinds = k; top = t; loaded = true }
            }
        }
    }
}

struct TopChatRow: View {
    var rank: Int = 0
    var item: ChatCount
    var maxCount: Int
    @State private var hover = false
    @State private var grown = false

    var body: some View {
        HStack(spacing: 12) {
            if rank > 0 {
                Text("\(rank)").font(DS.micro.monospacedDigit()).foregroundStyle(DS.ink5).frame(width: 16)
            }
            AvatarView(username: item.chat, size: 28)
            Text(item.display).font(DS.body).foregroundStyle(Theme.chatTitle).lineLimit(1).frame(width: 170, alignment: .leading)
            GeometryReader { geo in
                let w = geo.size.width * CGFloat(item.count) / CGFloat(max(maxCount, 1)) * (grown ? 1 : 0)
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.ink.opacity(0.14)).frame(width: max(w, 4))
                    Capsule().fill(DS.ink).frame(width: max(w * CGFloat(item.mine) / CGFloat(max(item.count, 1)), 2))
                }
                .frame(height: 8)
                .frame(maxHeight: .infinity)
            }
            RollingNumber(value: item.count, font: .system(size: 12.5, weight: .medium).monospacedDigit(), format: { "\($0)" })
                .foregroundStyle(DS.ink3).frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(hover ? DS.wash : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(DS.ease, value: hover)
        .onAppear { withAnimation(DS.spring.delay(0.05 * Double(rank))) { grown = true } }
    }
}
