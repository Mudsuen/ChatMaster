import LensCore
import MudsUI
import SwiftUI

struct AIAnalysisView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab: Tab = .compose
    @State private var viewWidth: CGFloat = 900

    // Compose / single-text analysis
    @State private var inputText = ""
    @State private var contextChat: String?
    @State private var msgState: MsgState = .idle

    // Quick conversation summary
    @State private var summaryChat: String?
    @State private var convState: ConvState = .idle

    // Saved analysis history
    @State private var historyKind: HistoryFilter = .all
    @State private var history: [AnalysisRecord] = []
    @State private var selectedRecord: AnalysisRecord?

    enum Tab: Hashable { case compose, history }
    enum HistoryFilter: String, CaseIterable, Hashable {
        case all, message, conversation, relationship

        var title: String {
            switch self {
            case .all: return "全部"
            case .message: return "消息"
            case .conversation: return "会话"
            case .relationship: return "关系"
            }
        }

        var kinds: [String]? {
            switch self {
            case .all: return nil
            case .message: return ["msg", "text"]
            case .conversation: return ["conv"]
            case .relationship: return ["rel"]
            }
        }
    }

    private enum MsgState {
        case idle
        case loading(Date)
        case done(MessageAnalysis, LensMessage?)
        case failed(String)
    }

    private enum ConvState {
        case idle
        case loading(Date)
        case done(String, ConversationAnalysis)
        case failed(String)
    }

    private var compact: Bool { viewWidth > 0 && viewWidth < 520 }
    private var splitHistory: Bool { viewWidth >= 680 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BSegmented(selection: $tab, options: [(.compose, "快速分析"), (.history, "分析记录")], compact: true)
                    .fixedSize()
                Spacer(minLength: 4)
                if !compact {
                    Text("模型：\(model.agyConfig.model)")
                        .font(DS.micro)
                        .foregroundStyle(DS.ink4)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Rectangle().fill(DS.edge).frame(height: 1)

            Group {
                switch tab {
                case .compose: composeView
                case .history: historyView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DS.bg)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewWidth = $0 }
        .onAppear {
            if summaryChat == nil { summaryChat = model.selectedChat ?? model.chats.first?.username }
            loadHistory()
        }
        .onChange(of: historyKind) { _, _ in loadHistory() }
    }

    // MARK: - Compose Tab

    private var composeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(title: "消息情绪与回复分析", subtitle: compact ? nil : "输入对方消息或聊天片段，解读潜台词与意图并生成回复建议")

                        ZStack(alignment: .topLeading) {
                            if inputText.isEmpty {
                                Text("粘贴聊天内容或输入对方说的话…")
                                    .font(DS.body)
                                    .foregroundStyle(DS.ink5)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 9)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $inputText)
                                .font(DS.body)
                                .foregroundStyle(DS.ink)
                                .scrollContentBackground(.hidden)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 5)
                                .frame(minHeight: 86, maxHeight: 150)
                        }
                        .background(DS.wash, in: RoundedRectangle(cornerRadius: DS.innerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.innerRadius, style: .continuous)
                                .strokeBorder(DS.edge, lineWidth: 0.75)
                        )

                        HStack(spacing: 8) {
                            Menu {
                                Button("不关联会话") { contextChat = nil }
                                Divider()
                                ForEach(model.chats.prefix(40)) { c in
                                    Button(c.display) { contextChat = c.username }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "person.crop.circle")
                                    Text(contextChat.map { model.displayName($0) } ?? (compact ? "会话" : "关联会话（可选）"))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                .frame(maxWidth: 160, alignment: .leading)
                            }
                            .menuStyle(.button)
                            .buttonStyle(BButtonStyle(kind: .secondary, compact: true))
                            .fixedSize()

                            Spacer(minLength: 4)

                            if !inputText.isEmpty {
                                Button("清空") {
                                    inputText = ""
                                    msgState = .idle
                                }
                                .buttonStyle(BButtonStyle(kind: .ghost, compact: true))
                                .fixedSize()
                            }

                            let isLoading: Bool = { if case .loading = msgState { return true }; return false }()
                            Button { runTextAnalysis(force: false) } label: {
                                if compact {
                                    Image(systemName: "sparkles")
                                } else {
                                    Label("开始分析", systemImage: "sparkles")
                                }
                            }
                            .buttonStyle(BButtonStyle(kind: .primary, compact: true))
                            .fixedSize()
                            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                            .help("开始分析")
                        }
                    }
                }

                switch msgState {
                case .idle:
                    EmptyView()
                case .loading(let since):
                    Card { AnalyzingView(since: since, label: "agy 正在分析情绪与意图…") }
                case .failed(let err):
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("分析失败", systemImage: "xmark.octagon.fill")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(DS.error)
                            Text(err).font(DS.sub).foregroundStyle(DS.ink4).textSelection(.enabled)
                            Button("重试") { runTextAnalysis(force: true) }
                                .buttonStyle(BButtonStyle(compact: true))
                        }
                    }
                case .done(let analysis, let matched):
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            MessageAnalysisCard(analysis: analysis)
                            HStack(spacing: 8) {
                                if let matched {
                                    Button {
                                        model.openChat(matched.chat, focusMessage: matched)
                                    } label: {
                                        Label("定位原消息", systemImage: "arrow.up.right")
                                    }
                                    .buttonStyle(BButtonStyle(kind: .secondary, compact: true))
                                }
                                Spacer()
                                Button { runTextAnalysis(force: true) } label: {
                                    Label("重新分析", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(BButtonStyle(kind: .ghost, compact: true))
                            }
                        }
                    }
                    .transition(.opacity)
                }

                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            SectionTitle(title: "快捷会话总结", subtitle: compact ? nil : "提炼最近 80 条消息要点与待办")
                            Spacer(minLength: 4)
                            Menu {
                                ForEach(model.chats.prefix(40)) { c in
                                    Button(c.display) { summaryChat = c.username }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "bubble.left.and.bubble.right")
                                    Text(summaryChat.map { model.displayName($0) } ?? "选择会话")
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                .frame(maxWidth: 150, alignment: .leading)
                            }
                            .menuStyle(.button)
                            .buttonStyle(BButtonStyle(kind: .secondary, compact: true))
                            .fixedSize()

                            let convLoading: Bool = { if case .loading = convState { return true }; return false }()
                            Button { runConversationSummary(force: false) } label: {
                                if compact {
                                    Image(systemName: "sparkles")
                                } else {
                                    Label("生成总结", systemImage: "sparkles")
                                }
                            }
                            .buttonStyle(BButtonStyle(kind: .secondary, compact: true))
                            .fixedSize()
                            .disabled(summaryChat == nil || convLoading)
                            .help("生成最近 80 条对话总结")
                        }

                        switch convState {
                        case .idle:
                            EmptyView()
                        case .loading(let since):
                            AnalyzingView(since: since, label: "agy 正在阅读最近 80 条消息…")
                        case .failed(let err):
                            Text(err).font(DS.sub).foregroundStyle(DS.error).textSelection(.enabled)
                        case .done(let chat, let analysis):
                            VStack(alignment: .leading, spacing: 10) {
                                Divider()
                                ConversationAnalysisCard(analysis: analysis)
                                HStack {
                                    Button { model.openChat(chat) } label: {
                                        Label("打开会话", systemImage: "arrow.up.right")
                                    }
                                    .buttonStyle(BButtonStyle(kind: .secondary, compact: true))
                                    Spacer()
                                    Button { runConversationSummary(force: true) } label: {
                                        Label("重新生成", systemImage: "arrow.clockwise")
                                    }
                                    .buttonStyle(BButtonStyle(kind: .ghost, compact: true))
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - History Tab

    @ViewBuilder private var historyView: some View {
        if splitHistory {
            HStack(spacing: 0) {
                historyListPane
                    .frame(width: 260)
                Rectangle().fill(DS.edge).frame(width: 1)
                historyDetailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if selectedRecord != nil {
            VStack(spacing: 0) {
                HStack {
                    Button {
                        withAnimation(DS.ease) { selectedRecord = nil }
                    } label: {
                        Label("返回列表", systemImage: "chevron.left")
                    }
                    .buttonStyle(BButtonStyle(kind: .ghost, compact: true))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Rectangle().fill(DS.edge).frame(height: 1)
                historyDetailPane
            }
        } else {
            historyListPane
        }
    }

    private var historyListPane: some View {
        VStack(spacing: 8) {
            FlowLayout(spacing: 6) {
                ForEach(HistoryFilter.allCases, id: \.self) { f in
                    let on = historyKind == f
                    Button {
                        historyKind = f
                    } label: {
                        Text(f.title)
                            .font(.system(size: 11.5, weight: on ? .semibold : .medium))
                            .foregroundStyle(on ? DS.onSlab : DS.ink3)
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .background(on ? DS.slab : DS.wash, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 10)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(history) { r in
                        HistoryRecordRow(
                            record: r,
                            title: recordTitle(r),
                            preview: recordPreview(r),
                            icon: recordIcon(r.kind),
                            selected: selectedRecord?.id == r.id
                        )
                        .onTapGesture {
                            withAnimation(DS.ease) { selectedRecord = r }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .overlay {
                if history.isEmpty {
                    EmptyHint(
                        title: "暂无 AI 分析记录",
                        systemImage: "sparkles",
                        detail: "在「快速分析」、会话气泡或「关系洞察」生成的分析结果都会缓存在这里。"
                    )
                }
            }
        }
    }

    @ViewBuilder private var historyDetailPane: some View {
        if let record = selectedRecord {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Image(systemName: recordIcon(record.kind))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DS.pick)
                            .frame(width: 30, height: 30)
                            .background(DS.pick.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recordTitle(record))
                                .font(DS.title)
                                .foregroundStyle(Theme.chatTitle)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text("\(recordKindLabel(record.kind)) · \(Fmt.smart(record.createdDate)) · \(record.model)")
                                .font(DS.micro)
                                .foregroundStyle(DS.ink4)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 4)
                        if canOpenChat(record) {
                            Button { model.openChat(record.target) } label: {
                                Label("打开会话", systemImage: "arrow.up.right")
                            }
                            .buttonStyle(BButtonStyle(kind: .secondary, compact: true))
                            .fixedSize()
                        }
                    }

                    Card {
                        decodedDetail(record)
                    }
                }
                .padding(18)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        } else {
            EmptyHint(
                title: "选择一条分析记录",
                systemImage: "sparkles",
                detail: "支持回看单条消息情绪、对话总结和关系报告的缓存结果。"
            )
        }
    }

    // MARK: - Actions & Helpers

    private func runTextAnalysis(force: Bool) {
        guard let engine = model.engine else { return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let chat = contextChat
        msgState = .loading(Date())
        Task {
            do {
                let (analysis, matched) = try await engine.analyze(text: text, chatHint: chat, force: force)
                withAnimation(DS.spring) { msgState = .done(analysis, matched) }
                loadHistory()
            } catch {
                msgState = .failed(error.localizedDescription)
            }
        }
    }

    private func runConversationSummary(force: Bool) {
        guard let engine = model.engine, let chat = summaryChat else { return }
        convState = .loading(Date())
        Task {
            do {
                let a = try await engine.analyzeConversation(chat: chat, force: force)
                withAnimation(DS.spring) { convState = .done(chat, a) }
                loadHistory()
            } catch {
                convState = .failed(error.localizedDescription)
            }
        }
    }

    private func loadHistory() {
        guard let store = model.store else { return }
        let kinds = historyKind.kinds
        Task {
            let rows = await Task.detached { store.recentAnalyses(kinds: kinds, limit: 120) }.value
            history = rows
            if splitHistory {
                if let cur = selectedRecord, let refreshed = rows.first(where: { $0.id == cur.id }) {
                    selectedRecord = refreshed
                } else if selectedRecord == nil {
                    selectedRecord = rows.first
                }
            }
        }
    }

    private func canOpenChat(_ r: AnalysisRecord) -> Bool {
        !r.target.isEmpty && (r.kind == "msg" || r.kind == "text" || r.kind == "conv" || r.kind == "rel")
    }

    private func recordIcon(_ kind: String) -> String {
        switch kind {
        case "conv": return "text.bubble"
        case "rel": return "person.2.wave.2"
        case "daily": return "newspaper"
        default: return "sparkles"
        }
    }

    private func recordKindLabel(_ kind: String) -> String {
        switch kind {
        case "conv": return "会话总结"
        case "rel": return "关系报告"
        case "daily": return "每日简报"
        default: return "消息分析"
        }
    }

    private func recordTitle(_ r: AnalysisRecord) -> String {
        switch r.kind {
        case "daily": return "每日简报 · \(r.target)"
        default: return r.target.isEmpty ? "自由文本" : model.displayName(r.target)
        }
    }

    private func recordPreview(_ r: AnalysisRecord) -> String {
        let data = Data(r.json.utf8)
        switch r.kind {
        case "conv":
            if let a = try? JSONDecoder().decode(ConversationAnalysis.self, from: data) {
                return a.summary.isEmpty ? a.overallMood : a.summary
            }
        case "rel":
            if let a = try? JSONDecoder().decode(RelationshipReport.self, from: data) {
                return a.summary.isEmpty ? a.closenessLabel : a.summary
            }
        case "daily":
            if let a = try? JSONDecoder().decode(DailyBriefing.self, from: data) {
                return a.headline
            }
        default:
            if let a = try? JSONDecoder().decode(MessageAnalysis.self, from: data) {
                return "\(a.emoji) \(a.emotion) · \(a.intent)"
            }
        }
        return r.kind
    }

    @ViewBuilder private func decodedDetail(_ r: AnalysisRecord) -> some View {
        let data = Data(r.json.utf8)
        switch r.kind {
        case "conv":
            if let a = try? JSONDecoder().decode(ConversationAnalysis.self, from: data) {
                ConversationAnalysisCard(analysis: a)
            } else {
                Text(r.json).font(DS.micro.monospaced()).foregroundStyle(DS.ink4).textSelection(.enabled)
            }
        case "rel":
            if let a = try? JSONDecoder().decode(RelationshipReport.self, from: data) {
                RelationshipReportCard(report: a)
            } else {
                Text(r.json).font(DS.micro.monospaced()).foregroundStyle(DS.ink4).textSelection(.enabled)
            }
        case "daily":
            if let a = try? JSONDecoder().decode(DailyBriefing.self, from: data) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(a.headline).font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.ink)
                    BulletList(title: "情绪提醒", icon: "heart.text.square", items: a.moodAlerts, color: Color(muHex: 0xF43F5E))
                    BulletList(title: "建议", icon: "lightbulb", items: a.suggestions, color: DS.warning)
                }
            } else {
                Text(r.json).font(DS.micro.monospaced()).foregroundStyle(DS.ink4).textSelection(.enabled)
            }
        default:
            if let a = try? JSONDecoder().decode(MessageAnalysis.self, from: data) {
                MessageAnalysisCard(analysis: a)
            } else {
                Text(r.json).font(DS.micro.monospaced()).foregroundStyle(DS.ink4).textSelection(.enabled)
            }
        }
    }
}

private struct HistoryRecordRow: View {
    var record: AnalysisRecord
    var title: String
    var preview: String
    var icon: String
    var selected: Bool
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(selected ? DS.pick : DS.ink4)
                .frame(width: 22, height: 22)
                .background(selected ? DS.pick.opacity(0.14) : DS.wash, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.chatTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(DateFmt.compactList(record.createdDate))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(DS.ink5)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Text(preview)
                    .font(DS.sub)
                    .foregroundStyle(DS.ink4)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(selected ? DS.card : (hover ? DS.wash : .clear), in: RoundedRectangle(cornerRadius: DS.innerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.innerRadius, style: .continuous).strokeBorder(selected ? DS.edge : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(DS.ease, value: hover)
    }
}
