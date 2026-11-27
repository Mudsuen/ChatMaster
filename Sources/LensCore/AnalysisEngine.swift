import Foundation

/// High-level analyses on top of the index, with a persistent cache.
public final class AnalysisEngine: @unchecked Sendable {
    public let store: LensStore
    private let client = AgyClient()
    private let lock = NSLock()
    private var _config: AgyConfig

    public init(store: LensStore, config: AgyConfig) {
        self.store = store
        self._config = config
    }

    public var config: AgyConfig {
        get { lock.lock(); defer { lock.unlock() }; return _config }
        set { lock.lock(); _config = newValue; lock.unlock() }
    }

    private func call<T: Decodable>(_ prompt: String, schema: [String: Any], as: T.Type) async throws -> (T, String) {
        let cfg = config
        guard FileManager.default.isExecutableFile(atPath: cfg.binary) else {
            throw AgyError(message: "找不到 agy：\(cfg.binary)。请在设置里指定路径。")
        }
        let r = try await client.run(prompt: prompt, schema: S.json(schema), config: cfg)
        do {
            return (try JSONDecoder().decode(T.self, from: r.json), String(decoding: r.json, as: UTF8.self))
        } catch {
            throw AgyError(message: "结果解析失败：\(error.localizedDescription)")
        }
    }

    private func cached<T: Decodable>(_ key: String, as: T.Type) -> T? {
        guard let json = store.cachedAnalysis(key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - single message

    public func cachedAnalysis(messageID: Int64) -> MessageAnalysis? { cached("msg:\(messageID)", as: MessageAnalysis.self) }

    public func analyze(message m: LensMessage, contextSize: Int = 14, force: Bool = false) async throws -> MessageAnalysis {
        let key = "msg:\(m.id)"
        if !force, let c = cached(key, as: MessageAnalysis.self) { return c }
        let ctx = store.context(for: m, before: contextSize, after: 3)
        let (a, json) = try await call(Prompts.message(m, context: ctx, store: store), schema: MessageAnalysis.schema,
                                       as: MessageAnalysis.self)
        store.saveAnalysis(key: key, kind: "msg", target: m.chat, model: config.model, json: json)
        return a
    }

    /// Analyzes copied / OCR'd text. Uses the indexed original (with context) when it can be found.
    public func analyze(text: String, chatHint: String?, force: Bool = false) async throws -> (MessageAnalysis, LensMessage?) {
        if let m = store.findMessage(text: text, preferChat: chatHint) {
            return (try await analyze(message: m, force: force), m)
        }
        let key = "text:\(WeChatSource.md5(text + "|" + (chatHint ?? "")))"
        if !force, let c = cached(key, as: MessageAnalysis.self) { return (c, nil) }
        let ctx = chatHint.map { store.messages(chat: $0, limit: 12) } ?? []
        let (a, json) = try await call(Prompts.rawText(text, chat: chatHint, context: ctx, store: store),
                                       schema: MessageAnalysis.schema, as: MessageAnalysis.self)
        store.saveAnalysis(key: key, kind: "text", target: chatHint ?? "", model: config.model, json: json)
        return (a, nil)
    }

    // MARK: - conversation

    public func latestConversationAnalysis(chat: String) -> (ConversationAnalysis, Date)? {
        guard let r = store.latestAnalysis(kind: "conv", target: chat),
              let a = try? JSONDecoder().decode(ConversationAnalysis.self, from: Data(r.json.utf8)) else { return nil }
        return (a, Date(timeIntervalSince1970: TimeInterval(r.created)))
    }

    public func analyzeConversation(chat: String, limit: Int = 80, force: Bool = false) async throws -> ConversationAnalysis {
        let msgs = store.messages(chat: chat, limit: limit)
        guard let last = msgs.last else { throw AgyError(message: "这个会话没有消息") }
        let key = "conv:\(chat):\(last.id):\(limit)"
        if !force, let c = cached(key, as: ConversationAnalysis.self) { return c }
        let (a, json) = try await call(Prompts.conversation(msgs, chat: chat, store: store),
                                       schema: ConversationAnalysis.schema, as: ConversationAnalysis.self)
        store.saveAnalysis(key: key, kind: "conv", target: chat, model: config.model, json: json)
        return a
    }

    // MARK: - relationship

    public func latestRelationshipReport(chat: String) -> (RelationshipReport, Date)? {
        guard let r = store.latestAnalysis(kind: "rel", target: chat),
              let a = try? JSONDecoder().decode(RelationshipReport.self, from: Data(r.json.utf8)) else { return nil }
        return (a, Date(timeIntervalSince1970: TimeInterval(r.created)))
    }

    public func relationshipReport(chat: String, force: Bool = false) async throws -> RelationshipReport {
        let msgs = store.messages(chat: chat, limit: 400).filter { $0.isTextual }
        guard let last = msgs.last else { throw AgyError(message: "没有足够的文字消息") }
        let key = "rel:\(chat):\(last.id)"
        if !force, let c = cached(key, as: RelationshipReport.self) { return c }
        let stats = store.relationship(chat: chat)
        let (a, json) = try await call(Prompts.relationship(msgs, stats: stats, chat: chat, store: store),
                                       schema: RelationshipReport.schema, as: RelationshipReport.self)
        store.saveAnalysis(key: key, kind: "rel", target: chat, model: config.model, json: json)
        return a
    }

    // MARK: - daily briefing

    public static func dayKey(_ day: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: day)
    }

    public func latestBriefing(day: Date) -> (DailyBriefing, Date)? {
        guard let r = store.latestAnalysis(kind: "daily", target: AnalysisEngine.dayKey(day)),
              let a = try? JSONDecoder().decode(DailyBriefing.self, from: Data(r.json.utf8)) else { return nil }
        return (a, Date(timeIntervalSince1970: TimeInterval(r.created)))
    }

    public func dailyBriefing(day: Date, force: Bool = false) async throws -> DailyBriefing {
        let start = Calendar.current.startOfDay(for: day)
        let end = start.addingTimeInterval(86400)
        let msgs = store.messages(since: Int64(start.timeIntervalSince1970), until: Int64(end.timeIntervalSince1970))
            .filter { !$0.isSystem }
        guard let last = msgs.last else { throw AgyError(message: "这一天没有聊天记录") }
        let key = "daily:\(AnalysisEngine.dayKey(day)):\(last.id)"
        if !force, let c = cached(key, as: DailyBriefing.self) { return c }
        var byChat: [String: [LensMessage]] = [:]
        for m in msgs { byChat[m.chat, default: []].append(m) }
        // Private chats first, then by activity.
        let ordered = byChat.sorted { a, b in
            let ga = a.key.hasSuffix("@chatroom"), gb = b.key.hasSuffix("@chatroom")
            if ga != gb { return !ga }
            return a.value.count > b.value.count
        }.map { ($0.key, Array($0.value.suffix(40))) }
        let (a, json) = try await call(Prompts.daily(day, chats: ordered, store: store),
                                       schema: DailyBriefing.schema, as: DailyBriefing.self)
        store.saveAnalysis(key: key, kind: "daily", target: AnalysisEngine.dayKey(day), model: config.model, json: json)
        return a
    }
}
