import Charts
import LensCore
import MudsUI
import SwiftUI

struct PendingView: View {
    @EnvironmentObject var model: AppModel
    @State private var items: [PendingReply] = []

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "待回复", subtitle: "最近 7 天，对方在等你的会话 · \(items.count) 个")
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(items) { p in PendingCard(item: p) }
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
            }
            .overlay { if items.isEmpty { EmptyHint(title: "没有人在等你", systemImage: "checkmark.seal", detail: "对方有提问、请求或在群里 @ 你时会出现在这里。") } }
        }
        .task(id: model.revision) {
            guard let store = model.store else { return }
            let r = await Task.detached { store.pendingReplies() }.value
            withAnimation(DS.spring) { items = r }
        }
    }
}

private struct PendingCard: View {
    @EnvironmentObject var model: AppModel
    var item: PendingReply

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    AvatarView(username: item.chat, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.display).font(DS.title).foregroundStyle(Theme.chatTitle)
                        Text("已等待 \(Fmt.duration(item.waiting))").font(DS.sub)
                            .foregroundStyle(item.waiting > 6 * 3600 ? DS.warning : DS.ink4)
                    }
                    Spacer()
                    FlowLayout(spacing: 5) { ForEach(item.reasons, id: \.self) { Chip(text: $0, color: DS.warning) } }
                        .frame(maxWidth: 260, alignment: .trailing)
                    Button("打开") { model.openChat(item.chat) }.buttonStyle(BButtonStyle(kind: .primary, compact: true))
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(item.recent.suffix(3)) { m in
                        HStack(alignment: .top, spacing: 8) {
                            Text(m.isSelf ? "我" : model.senderLabel(m)).font(DS.micro)
                                .foregroundStyle(m.isSelf ? DS.ink : DS.ink4).frame(width: 64, alignment: .trailing).lineLimit(1)
                            Text(m.text).font(DS.body).foregroundStyle(DS.ink2).lineLimit(2)
                            Spacer()
                            if !m.isSelf && m.isTextual {
                                Button { model.inspect(m) } label: { Image(systemName: "sparkles") }
                                    .buttonStyle(IconButtonStyle(size: 24)).help("分析")
                            }
                        }
                        .contextMenu { MessageMenu(message: m) }
                    }
                }
                .padding(10)
                .background(DS.wash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

struct InsightView: View {
    @EnvironmentObject var model: AppModel
    @State private var chat: String?
    @State private var stats: RelationshipStats?
    @State private var heat: [HeatCell] = []
    @State private var report: ReportState = .idle
    @State private var picker = ""

    enum ReportState { case idle, loading(Date), done(RelationshipReport, Date), failed(String) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                FilterField(text: $picker, prompt: "选择联系人或群")
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.chats.filter { picker.isEmpty || $0.display.localizedCaseInsensitiveContains(picker) }.prefix(300)) { c in
                            PickRow(chat: c, selected: chat == c.username)
                                .onTapGesture { withAnimation(DS.spring) { chat = c.username } }
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: 250)
            Rectangle().fill(DS.edge).frame(width: 1)
            Group {
                if let chat, let stats {
                    ScrollView { content(chat: chat, s: stats).padding(24).frame(maxWidth: 1000).frame(maxWidth: .infinity) }
                        .id(chat)
                        .transition(.opacity)
                } else {
                    EmptyHint(title: "选择一个联系人或群", systemImage: "person.2.wave.2", detail: "查看互动统计，并生成 AI 关系报告")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if let c = model.insightChat { chat = c; model.insightChat = nil } }
        .onChange(of: model.insightChat) { _, c in if let c { chat = c; model.insightChat = nil } }
        .task(id: chat) { await load() }
    }

    private func load() async {
        guard let store = model.store, let chat else { return }
        report = .idle
        let (s, h) = await Task.detached { (store.relationship(chat: chat), store.heatmap(days: 3650, chat: chat)) }.value
        withAnimation(DS.spring) { stats = s; heat = h }
        if let (r, at) = model.engine?.latestRelationshipReport(chat: chat) { report = .done(r, at) }
    }

    @ViewBuilder private func content(chat: String, s: RelationshipStats) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                AvatarView(username: chat, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName(chat)).font(.system(size: 26, weight: .semibold)).tracking(-0.5)
                    if s.firstTs > 0 {
                        Text("相识于 \(Fmt.day.string(from: Date(timeIntervalSince1970: TimeInterval(s.firstTs)))) · 聊过 \(s.activeDays) 天")
                            .font(DS.body).foregroundStyle(DS.ink4)
                    }
                }
                Spacer()
                if !s.topSenders.isEmpty {
                    AvatarStack(items: s.topSenders.map(\.chat)) { AvatarView(username: $0, size: 26) }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                StatTile(title: "总消息", value: s.total, icon: "text.bubble.fill", tint: DS.pick)
                StatTile(title: "我 : 对方", text: s.total > 0 ? "\(Int(Double(s.mine) / Double(s.total) * 100)) : \(100 - Int(Double(s.mine) / Double(s.total) * 100))" : "—",
                         icon: "arrow.left.arrow.right", tint: DS.ink)
                StatTile(title: "主动 我/对方", text: "\(s.myInitiations) / \(s.theirInitiations)", icon: "hand.wave.fill", tint: DS.warning)
                StatTile(title: "我回复", text: Fmt.duration(s.myMedianReply), icon: "timer", tint: Color(muHex: 0x14B8A6))
                StatTile(title: "对方回复", text: Fmt.duration(s.theirMedianReply), icon: "timer", tint: Color(muHex: 0xF43F5E))
            }
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(title: "每月消息量", subtitle: "深色为我发出")
                    StackedBarsView(data: s.months.enumerated().map { i, m in
                        BarDatum(id: i, label: Fmt.month.string(from: m.month), mine: m.mine, theirs: m.theirs)
                    }, height: 150)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "情绪走势", subtitle: "本地估算，只计有情绪色彩的消息")
                    Chart {
                        ForEach(s.months) { m in
                            if let v = m.theirSentiment {
                                LineMark(x: .value("月", m.month, unit: .month), y: .value("情绪", v))
                                    .foregroundStyle(by: .value("谁", "对方")).interpolationMethod(.catmullRom)
                                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                            }
                            if let v = m.mySentiment {
                                LineMark(x: .value("月", m.month, unit: .month), y: .value("情绪", v))
                                    .foregroundStyle(by: .value("谁", "我")).interpolationMethod(.catmullRom)
                                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                            }
                        }
                        RuleMark(y: .value("中性", 0)).foregroundStyle(DS.edge)
                    }
                    .chartForegroundStyleScale(["对方": DS.pick, "我": DS.ink])
                    .chartXAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(DS.ink5) } }
                    .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(DS.edge); AxisValueLabel().foregroundStyle(DS.ink5) } }
                    .frame(height: 140)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(title: "什么时候聊", subtitle: "星期 × 小时")
                        HeatGridView(cells: heat.map { MUHeatCell(weekday: $0.weekday, hour: $0.hour, count: $0.count) })
                    }
                }
                if !s.topSenders.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionTitle(title: "群内最活跃")
                            ForEach(Array(s.topSenders.prefix(8).enumerated()), id: \.element.id) { i, c in
                                TopChatRow(rank: i + 1, item: c, maxCount: s.topSenders.first?.count ?? 1)
                            }
                        }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(title: "AI 关系报告", subtitle: "基于统计与最近 400 条文字消息", trailing: AnyView(reportButton(chat)))
                    switch report {
                    case .idle:
                        Text("报告内容会发送给 agy 使用的模型生成。").font(DS.sub).foregroundStyle(DS.ink5)
                    case .loading(let since): AnalyzingView(since: since, label: "agy 正在撰写关系报告…")
                    case .failed(let e): Text(e).font(DS.sub).foregroundStyle(DS.error).textSelection(.enabled)
                    case .done(let r, let at):
                        RelationshipReportCard(report: r).transition(.opacity)
                        Text("生成于 \(Fmt.smart(at))").font(DS.micro).foregroundStyle(DS.ink5)
                    }
                }
                .animation(DS.spring, value: { if case .done = report { return true }; return false }())
            }
        }
    }

    private func reportButton(_ chat: String) -> some View {
        let isDone: Bool = { if case .done = report { return true }; return false }()
        let isLoading: Bool = { if case .loading = report { return true }; return false }()
        return Button {
            guard let engine = model.engine else { return }
            report = .loading(Date())
            Task {
                do { report = .done(try await engine.relationshipReport(chat: chat, force: isDone), Date()) }
                catch { report = .failed(error.localizedDescription) }
            }
        } label: { Label(isDone ? "重新生成" : "生成报告", systemImage: "sparkles") }
            .buttonStyle(BButtonStyle(kind: isDone ? .secondary : .primary, compact: true))
            .disabled(isLoading)
    }
}

private struct PickRow: View {
    var chat: ChatSummary
    var selected: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            AvatarView(username: chat.username, size: 26)
            Text(chat.display).font(DS.body).foregroundStyle(Theme.chatTitle).lineLimit(1)
            Spacer()
            Text(Fmt.count(chat.count)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(DS.ink5)
        }
        .padding(.horizontal, 8).frame(height: 36)
        .background(selected ? DS.card : (hover ? DS.wash : .clear), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(selected ? DS.edge : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(DS.ease, value: hover)
    }
}

struct SearchView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var results: [LensMessage] = []
    @State private var chatScope: String?
    @State private var searching = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("搜索").font(.system(size: 22, weight: .semibold)).tracking(-0.4)
                HStack(spacing: 10) {
                    HStack(spacing: 10) {
                        if searching { ThinkingOrb(size: 18) } else {
                            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.ink4)
                        }
                        TextField("搜索全部聊天记录（支持中文片段）", text: $query)
                            .textFieldStyle(.plain).font(.system(size: 16)).focused($focused)
                            .onSubmit { run() }
                    }
                    .padding(.horizontal, 16).frame(height: 46)
                    .background(DS.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(focused ? DS.pick.opacity(0.7) : DS.edge, lineWidth: focused ? 2 : 1))
                    .animation(DS.ease, value: focused)
                    Menu {
                        Button("全部会话") { chatScope = nil }
                        Divider()
                        ForEach(model.chats.prefix(60)) { c in Button(c.display) { chatScope = c.username } }
                    } label: {
                        Label(chatScope.map { model.displayName($0) } ?? "全部会话", systemImage: "line.3.horizontal.decrease")
                    }
                    .menuStyle(.button).buttonStyle(BButtonStyle(kind: .secondary)).fixedSize()
                }
                if !results.isEmpty {
                    Text("\(results.count) 条结果 · 单击查看，双击打开会话").font(DS.sub).foregroundStyle(DS.ink4)
                }
            }
            .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 12)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(results) { m in
                        MessageRow(message: m, selected: model.inspected?.id == m.id)
                            .onTapGesture(count: 2) { model.openChat(m.chat) }
                            .onTapGesture { model.inspect(m, analyze: false) }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 20)
            }
            .overlay {
                if results.isEmpty {
                    EmptyHint(title: query.isEmpty ? "输入关键词" : "没有结果", systemImage: "text.magnifyingglass",
                              detail: query.isEmpty ? "三个字以上走全文索引，更短的走模糊匹配" : nil)
                }
            }
        }
        .onAppear { focused = true }
        .onChange(of: chatScope) { _, _ in run() }
    }

    private func run() {
        guard let store = model.store else { return }
        let q = query, scope = chatScope
        searching = true
        Task {
            let r = await Task.detached { store.search(q, chat: scope, limit: 400) }.value
            withAnimation(DS.spring) { results = r }
            searching = false
        }
    }
}

struct BriefingView: View {
    @EnvironmentObject var model: AppModel
    @State private var day = Date()
    @State private var state: BriefState = .idle

    enum BriefState { case idle, loading(Date), done(DailyBriefing, Date), failed(String) }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "每日简报", subtitle: Fmt.day.string(from: day)) {
                HStack(spacing: 8) {
                    DatePicker("", selection: $day, in: ...Date(), displayedComponents: .date)
                        .labelsHidden().datePickerStyle(.field).frame(width: 120)
                    Button { generate(force: isDone) } label: {
                        Label(isDone ? "重新生成" : "生成简报", systemImage: "sparkles")
                    }
                    .buttonStyle(BButtonStyle(kind: .primary)).disabled(isLoading)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch state {
                    case .idle:
                        EmptyHint(title: "还没有这一天的简报", systemImage: "newspaper",
                                  detail: "汇总当天私聊和群聊的要点、待回复、你答应别人的事和情绪异常。内容会发送给 agy 使用的模型。")
                            .frame(height: 380)
                    case .loading(let since): AnalyzingView(since: since, label: "agy 正在阅读当天的聊天…")
                    case .failed(let e): Text(e).foregroundStyle(DS.error).textSelection(.enabled)
                    case .done(let b, let at): briefing(b, at: at)
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
                .frame(maxWidth: 900).frame(maxWidth: .infinity)
                .animation(DS.spring, value: isDone)
            }
        }
        .task(id: AnalysisEngine.dayKey(day)) {
            if let (b, at) = model.engine?.latestBriefing(day: day) { state = .done(b, at) } else { state = .idle }
        }
    }

    private var isDone: Bool { if case .done = state { return true }; return false }
    private var isLoading: Bool { if case .loading = state { return true }; return false }

    private func generate(force: Bool) {
        guard let engine = model.engine else { return }
        state = .loading(Date())
        Task {
            do { state = .done(try await engine.dailyBriefing(day: day, force: force), Date()) }
            catch { state = .failed(error.localizedDescription) }
        }
    }

    @ViewBuilder private func briefing(_ b: DailyBriefing, at: Date) -> some View {
        Text(b.headline).font(.system(size: 22, weight: .semibold)).tracking(-0.4).foregroundStyle(DS.ink)
            .textSelection(.enabled).padding(.vertical, 4)
        if !b.highlights.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(title: "要点")
                    ForEach(b.highlights, id: \.self) { h in
                        HStack(alignment: .top, spacing: 10) {
                            Chip(text: h.importance, color: Theme.urgency(h.importance), filled: h.importance == "高")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h.chat).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(DS.ink)
                                Text(h.summary).font(DS.body).foregroundStyle(DS.ink2).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        HStack(alignment: .top, spacing: 12) {
            if !b.needReply.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "需要回复")
                        ForEach(b.needReply, id: \.self) { n in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(n.chat).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(DS.ink)
                                Text(n.reason).font(DS.sub).foregroundStyle(DS.ink4)
                            }
                        }
                    }
                }
            }
            if !b.myPromises.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "我答应的事")
                        ForEach(b.myPromises, id: \.self) { ChecklistRow(text: $0).font(DS.body) }
                    }
                }
            }
        }
        if !b.moodAlerts.isEmpty || !b.suggestions.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    BulletList(title: "情绪提醒", icon: "heart.text.square", items: b.moodAlerts, color: Color(muHex: 0xF43F5E))
                    BulletList(title: "明天的建议", icon: "lightbulb", items: b.suggestions, color: DS.warning)
                }
            }
        }
        Text("生成于 \(Fmt.smart(at))").font(DS.micro).foregroundStyle(DS.ink5)
    }
}
