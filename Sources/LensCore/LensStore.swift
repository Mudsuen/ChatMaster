import Foundation

public enum SearchSender: String, CaseIterable, Hashable, Sendable {
    case all, mine, others
}

public struct AnalysisRecord: Identifiable, Hashable, Sendable {
    public var key: String
    public var kind: String
    public var target: String
    public var model: String
    public var created: Int64
    public var json: String

    public var id: String { key }
    public var createdDate: Date { Date(timeIntervalSince1970: TimeInterval(created)) }
}

/// Local index: normalized messages + FTS5 (trigram, works for Chinese substrings) + analysis cache.
/// Contains plaintext chat history; the directory is 700 and files are 600.
public final class LensStore: @unchecked Sendable {
    public let writer: SQLiteDB
    public let reader: SQLiteDB
    public let url: URL
    private let lock = NSLock()
    private var contactMap: [String: Contact] = [:]
    public private(set) var selfUsername: String = ""

    static let cols = "id, chat, sender, is_self, ts, base_type, sub_type, kind, text, quote, sentiment, recalled_at, recall_notice"
    private static let mCols = cols.split(separator: ",").map { "m." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")

    public init(url: URL = LensPaths.indexDB) throws {
        self.url = url
        writer = try SQLiteDB(path: url.path, readonly: false)
        try writer.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA temp_store=MEMORY;")
        try LensStore.migrate(writer)
        reader = try SQLiteDB(path: url.path, readonly: true)
        for suffix in ["", "-wal", "-shm"] { LensPaths.makePrivate(URL(fileURLWithPath: url.path + suffix)) }
        loadContacts()
        cleanupAnchorsOnce()
    }

    static func migrate(_ db: SQLiteDB) throws {
        try db.exec("""
            CREATE TABLE IF NOT EXISTS messages(
                id INTEGER PRIMARY KEY,
                src TEXT NOT NULL, tbl TEXT NOT NULL, local_id INTEGER NOT NULL, server_id INTEGER,
                chat TEXT NOT NULL, sender TEXT, is_self INTEGER NOT NULL DEFAULT 0, ts INTEGER NOT NULL,
                base_type INTEGER, sub_type INTEGER, kind TEXT, text TEXT, quote TEXT, sentiment REAL,
                UNIQUE(src, tbl, local_id));
            CREATE INDEX IF NOT EXISTS idx_msg_chat_ts ON messages(chat, ts);
            CREATE INDEX IF NOT EXISTS idx_msg_ts ON messages(ts);
            CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(text, content='messages', content_rowid='id', tokenize='trigram');
            CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
                INSERT INTO messages_fts(rowid, text) VALUES (new.id, new.text);
            END;
            CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
                INSERT INTO messages_fts(messages_fts, rowid, text) VALUES('delete', old.id, old.text);
            END;
            CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE OF text ON messages BEGIN
                INSERT INTO messages_fts(messages_fts, rowid, text) VALUES('delete', old.id, old.text);
                INSERT INTO messages_fts(rowid, text) VALUES (new.id, new.text);
            END;
            CREATE TABLE IF NOT EXISTS watermarks(src TEXT NOT NULL, tbl TEXT NOT NULL, local_id INTEGER NOT NULL,
                PRIMARY KEY(src, tbl));
            CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT);
            CREATE TABLE IF NOT EXISTS contacts(username TEXT PRIMARY KEY, remark TEXT, nick TEXT, alias TEXT, kind TEXT,
                flag INTEGER NOT NULL DEFAULT 0, chat_room_notify INTEGER NOT NULL DEFAULT 1);
            CREATE TABLE IF NOT EXISTS sessions(username TEXT PRIMARY KEY, summary TEXT, last_ts INTEGER, unread INTEGER, hidden INTEGER);
            CREATE TABLE IF NOT EXISTS chat_stats(chat TEXT PRIMARY KEY, count INTEGER, last_ts INTEGER, last_text TEXT);
            CREATE TABLE IF NOT EXISTS analyses(key TEXT PRIMARY KEY, kind TEXT, target TEXT, model TEXT, created INTEGER, json TEXT);
            CREATE INDEX IF NOT EXISTS idx_analyses_target ON analyses(kind, target);
            CREATE TABLE IF NOT EXISTS watchlist(username TEXT PRIMARY KEY);
            """)
        var contactCols = Set<String>()
        try db.query("PRAGMA table_info(contacts)") { r in if let n = r.text(1) { contactCols.insert(n) } }
        if !contactCols.contains("flag") {
            try db.exec("""
                ALTER TABLE contacts ADD COLUMN flag INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE contacts ADD COLUMN chat_room_notify INTEGER NOT NULL DEFAULT 1;
                DELETE FROM kv WHERE k = 'sig:contact';
                """)
        }
        var cols = Set<String>()
        try db.query("PRAGMA table_info(messages)") { r in if let n = r.text(1) { cols.insert(n) } }
        if !cols.contains("recalled_at") {
            try db.exec("""
                ALTER TABLE messages ADD COLUMN recalled_at INTEGER;
                ALTER TABLE messages ADD COLUMN recall_notice TEXT;
                """)
        }
        try db.exec("CREATE INDEX IF NOT EXISTS idx_msg_recalled ON messages(recalled_at) WHERE recalled_at IS NOT NULL")
        // Older builds flattened revokemsg XML into "<notice><revoketime>" text; normalize it.
        try db.exec("""
            UPDATE messages SET kind = '撤回', text = substr(text, 1, length(text) - 1)
            WHERE base_type = 10000 AND kind != '撤回' AND (text LIKE '%recalled a message0' OR text LIKE '%撤回了一条消息0')
            """)
    }

    /// Older builds stored raw `<a …>` markup from service-account texts.
    private func cleanupAnchorsOnce() {
        guard kv("cleanup.anchors") == nil else { return }
        var rows: [(Int64, String)] = []
        try? writer.query("SELECT id, text FROM messages WHERE base_type = 1 AND text LIKE '%</a>%'") { r in
            rows.append((r.int(0), r.text(1) ?? ""))
        }
        _ = try? writer.transaction {
            for (id, t) in rows { try writer.run("UPDATE messages SET text = ? WHERE id = ?", [.text(MessageDecoder.stripTags(t)), .int(id)]) }
        }
        try? refreshChatStats()
        setKV("cleanup.anchors", "1")
    }

    // MARK: - kv / watermarks

    public func kv(_ k: String) -> String? { try? writer.scalarText("SELECT v FROM kv WHERE k = ?", [.text(k)]) }

    public func setKV(_ k: String, _ v: String) {
        _ = try? writer.run("INSERT INTO kv(k, v) VALUES(?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v", [.text(k), .text(v)])
    }

    public func watermarks(src: String) -> [String: Int64] {
        var out: [String: Int64] = [:]
        try? writer.query("SELECT tbl, local_id FROM watermarks WHERE src = ?", [.text(src)]) { r in
            out[r.text(0) ?? ""] = r.int(1)
        }
        return out
    }

    public var hasData: Bool { ((try? writer.scalarInt("SELECT count(*) FROM watermarks")) ?? 0) > 0 }

    // MARK: - writes

    public struct IndexRow {
        public var src: String, tbl: String, localID: Int64, serverID: Int64
        public var chat: String, sender: String?, isSelf: Bool, ts: Int64
        public var decoded: DecodedMessage
        public var sentiment: Double?
    }

    /// Inserts/updates rows and advances the table watermark in one transaction.
    /// Returns the index ids of messages that were recalled since they were indexed: the original
    /// text is kept and the recall is recorded instead of overwriting it.
    @discardableResult
    public func ingest(_ rows: [IndexRow], src: String, tbl: String, watermark: Int64) throws -> [Int64] {
        var recalled: [Int64] = []
        let now = Int64(Date().timeIntervalSince1970)
        try writer.transaction {
            for r in rows {
                if r.decoded.isRevoke {
                    var existing: (id: Int64, base: Int64, done: Bool)?
                    try writer.query("SELECT id, base_type, recalled_at IS NOT NULL FROM messages WHERE src = ? AND tbl = ? AND local_id = ?",
                                     [.text(r.src), .text(r.tbl), .int(r.localID)]) { q in
                        existing = (q.int(0), q.int(1), q.int(2) != 0)
                    }
                    if let e = existing {
                        if e.done { continue }
                        if e.base != 10000 && e.base != 10002 {
                            try writer.run("UPDATE messages SET recalled_at = ?, recall_notice = ? WHERE id = ?",
                                           [.int(now), .text(r.decoded.text), .int(e.id)])
                            recalled.append(e.id)
                            continue
                        }
                    }
                }
                try writer.run("""
                    INSERT INTO messages(src, tbl, local_id, server_id, chat, sender, is_self, ts, base_type, sub_type, kind, text, quote, sentiment)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(src, tbl, local_id) DO UPDATE SET
                        text = excluded.text, kind = excluded.kind, base_type = excluded.base_type,
                        sub_type = excluded.sub_type, quote = excluded.quote, sentiment = excluded.sentiment,
                        sender = excluded.sender, is_self = excluded.is_self
                    WHERE messages.recalled_at IS NULL
                      AND (messages.text IS NOT excluded.text OR messages.base_type IS NOT excluded.base_type)
                    """, [
                        .text(r.src), .text(r.tbl), .int(r.localID), .int(r.serverID), .text(r.chat),
                        r.sender.map { .text($0) } ?? .null, .int(r.isSelf ? 1 : 0), .int(r.ts),
                        .int(Int64(r.decoded.baseType)), .int(Int64(r.decoded.subType)), .text(r.decoded.kind),
                        .text(r.decoded.text), r.decoded.quote.map { .text($0) } ?? .null,
                        r.sentiment.map { .double($0) } ?? .null,
                    ])
            }
            try writer.run("""
                INSERT INTO watermarks(src, tbl, local_id) VALUES(?,?,?)
                ON CONFLICT(src, tbl) DO UPDATE SET local_id = excluded.local_id
                """, [.text(src), .text(tbl), .int(watermark)])
        }
        return recalled
    }

    public func replaceContacts(_ contacts: [Contact], selfUsername: String) throws {
        try writer.transaction {
            try writer.run("DELETE FROM contacts")
            for c in contacts {
                try writer.run("""
                    INSERT OR REPLACE INTO contacts(username, remark, nick, alias, kind, flag, chat_room_notify)
                    VALUES(?,?,?,?,?,?,?)
                    """, [
                        .text(c.username), .text(c.remark), .text(c.nick), .text(c.alias),
                        .text(c.kind.rawValue), .int(c.flag), .int(Int64(c.chatRoomNotify)),
                    ])
            }
        }
        setKV("self_username", selfUsername)
        loadContacts()
    }

    public func replaceSessions(_ sessions: [SessionInfo]) throws {
        try writer.transaction {
            try writer.run("DELETE FROM sessions")
            for s in sessions {
                try writer.run("INSERT OR REPLACE INTO sessions(username, summary, last_ts, unread, hidden) VALUES(?,?,?,?,?)",
                               [.text(s.username), .text(s.summary), .int(s.lastTimestamp), .int(Int64(s.unread)), .int(s.hidden ? 1 : 0)])
            }
        }
    }

    public func refreshChatStats(_ chats: Set<String>? = nil) throws {
        try writer.transaction {
            if let chats {
                for c in chats {
                    try writer.run("""
                        INSERT OR REPLACE INTO chat_stats(chat, count, last_ts, last_text)
                        SELECT chat, count(*), max(ts),
                               (SELECT text FROM messages m2 WHERE m2.chat = ? ORDER BY ts DESC, id DESC LIMIT 1)
                        FROM messages WHERE chat = ? GROUP BY chat
                        """, [.text(c), .text(c)])
                }
            } else {
                try writer.run("DELETE FROM chat_stats")
                try writer.run("INSERT INTO chat_stats(chat, count, last_ts) SELECT chat, count(*), max(ts) FROM messages GROUP BY chat")
                try writer.run("""
                    UPDATE chat_stats SET last_text =
                        (SELECT text FROM messages m WHERE m.chat = chat_stats.chat ORDER BY ts DESC, id DESC LIMIT 1)
                    """)
            }
        }
    }

    // MARK: - contacts

    func loadContacts() {
        var map: [String: Contact] = [:]
        try? writer.query("SELECT username, remark, nick, alias, kind, IFNULL(flag,0), IFNULL(chat_room_notify,1) FROM contacts") { r in
            let u = r.text(0) ?? ""
            map[u] = Contact(username: u, remark: r.text(1) ?? "", nick: r.text(2) ?? "", alias: r.text(3) ?? "",
                             kind: ChatKind(rawValue: r.text(4) ?? "") ?? Contact.kind(of: u),
                             flag: r.int(5), chatRoomNotify: Int(r.int(6)))
        }
        let me = kv("self_username") ?? ""
        lock.lock(); contactMap = map; selfUsername = me; lock.unlock()
    }

    public func contact(_ username: String) -> Contact? {
        lock.lock(); defer { lock.unlock() }
        return contactMap[username]
    }

    public func displayName(_ username: String?) -> String {
        guard let username, !username.isEmpty else { return "未知" }
        if username == selfUsername { return "我" }
        if let c = contact(username) {
            if c.kind == .group && c.remark.isEmpty && c.nick.isEmpty { return "群聊 \(username.prefix(6))" }
            return c.display
        }
        return username
    }

    public var selfDisplayName: String {
        guard let c = contact(selfUsername) else { return "" }
        return c.nick.isEmpty ? c.display : c.nick
    }

    public func allContacts() -> [Contact] {
        lock.lock(); defer { lock.unlock() }
        return Array(contactMap.values)
    }

    // MARK: - reads

    static func message(_ r: SQLRow) -> LensMessage {
        var m = LensMessage(id: r.int(0), chat: r.text(1) ?? "", sender: r.text(2), isSelf: r.int(3) != 0, ts: r.int(4),
                            baseType: Int(r.int(5)), subType: Int(r.int(6)), kind: r.text(7) ?? "", text: r.text(8) ?? "",
                            quote: r.text(9), sentiment: r.isNull(10) ? nil : r.double(10))
        m.recalledAt = r.isNull(11) ? nil : r.int(11)
        m.recallNotice = r.text(12)
        return m
    }

    public func messages(ids: [Int64]) -> [LensMessage] {
        guard !ids.isEmpty else { return [] }
        let list = ids.map(String.init).joined(separator: ",")
        return messages("SELECT \(LensStore.cols) FROM messages WHERE id IN (\(list)) ORDER BY ts, id")
    }

    /// Messages recalled after WeChatLens indexed them, newest recall first.
    public func recalledMessages(limit: Int = 500) -> [LensMessage] {
        messages("SELECT \(LensStore.cols) FROM messages WHERE recalled_at IS NOT NULL ORDER BY recalled_at DESC LIMIT ?",
                 [.int(Int64(limit))])
    }

    public func recalledChatCounts() -> [String: Int] {
        var out: [String: Int] = [:]
        try? reader.query("SELECT chat, count(*) FROM messages WHERE recalled_at IS NOT NULL GROUP BY chat") { r in
            if let chat = r.text(0) { out[chat] = Int(r.int(1)) }
        }
        return out
    }

    public func recalledMessages(chat: String, limit: Int = 300) -> [LensMessage] {
        let rows = messages("""
            SELECT \(LensStore.cols) FROM messages WHERE chat = ? AND recalled_at IS NOT NULL
            ORDER BY ts DESC, id DESC LIMIT ?
            """, [.text(chat), .int(Int64(limit))])
        return rows.reversed()
    }

    public func recalledCount(since ts: Int64) -> Int {
        Int((try? reader.scalarInt("SELECT count(*) FROM messages WHERE recalled_at >= ?", [.int(ts)])) ?? 0)
    }

    private func messages(_ sql: String, _ params: [SQLValue] = []) -> [LensMessage] {
        var out: [LensMessage] = []
        try? reader.query(sql, params) { out.append(LensStore.message($0)) }
        return out
    }

    static let excludeNoise = "chat NOT LIKE 'gh\\_%' ESCAPE '\\' AND chat NOT IN ('filehelper','weixin','fmessage','notifymessage','brandsessionholder','brandservicesessionholder','@placeholder_foldgroup','newsapp','medianote')"
    private static let excludeNoiseM = excludeNoise.replacingOccurrences(of: "chat ", with: "m.chat ")

    public func totalMessages() -> Int { Int((try? reader.scalarInt("SELECT count(*) FROM messages")) ?? 0) }

    public func recent(limit: Int = 200, includeOfficial: Bool = false) -> [LensMessage] {
        let filter = includeOfficial ? "1" : LensStore.excludeNoise
        return messages("SELECT \(LensStore.cols) FROM messages WHERE \(filter) ORDER BY ts DESC, id DESC LIMIT ?", [.int(Int64(limit))])
    }

    public func messages(chat: String, before ts: Int64? = nil, limit: Int = 200) -> [LensMessage] {
        let rows = messages("""
            SELECT \(LensStore.cols) FROM messages WHERE chat = ? AND ts < ? ORDER BY ts DESC, id DESC LIMIT ?
            """, [.text(chat), .int(ts ?? Int64.max), .int(Int64(limit))])
        return rows.reversed()
    }

    public func messages(chat: String, since ts: Int64, limit: Int = 400) -> [LensMessage] {
        let rows = messages("""
            SELECT \(LensStore.cols) FROM messages WHERE chat = ? AND ts >= ? ORDER BY ts DESC, id DESC LIMIT ?
            """, [.text(chat), .int(ts), .int(Int64(limit))])
        return rows.reversed()
    }

    public func message(id: Int64) -> LensMessage? {
        messages("SELECT \(LensStore.cols) FROM messages WHERE id = ?", [.int(id)]).first
    }

    public func context(for m: LensMessage, before: Int = 12, after: Int = 3) -> [LensMessage] {
        let prev = messages("""
            SELECT \(LensStore.cols) FROM messages WHERE chat = ? AND (ts < ? OR (ts = ? AND id < ?))
            ORDER BY ts DESC, id DESC LIMIT ?
            """, [.text(m.chat), .int(m.ts), .int(m.ts), .int(m.id), .int(Int64(before))])
        let next = messages("""
            SELECT \(LensStore.cols) FROM messages WHERE chat = ? AND (ts > ? OR (ts = ? AND id > ?))
            ORDER BY ts, id LIMIT ?
            """, [.text(m.chat), .int(m.ts), .int(m.ts), .int(m.id), .int(Int64(after))])
        return prev.reversed() + [m] + next
    }

    public func messages(since ts: Int64, until: Int64, limit: Int = 4000) -> [LensMessage] {
        messages("""
            SELECT \(LensStore.cols) FROM messages WHERE ts >= ? AND ts < ? AND \(LensStore.excludeNoise)
            ORDER BY ts, id LIMIT ?
            """, [.int(ts), .int(until), .int(Int64(limit))])
    }

    public func search(
        _ query: String,
        chat: String? = nil,
        recalledOnly: Bool = false,
        sender: SearchSender = .all,
        chatKind: ChatKind? = nil,
        since: Int64? = nil,
        limit: Int = 300
    ) -> [LensMessage] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var clauses: [String] = []
        var extraParams: [SQLValue] = []
        if let chat {
            clauses.append("m.chat = ?")
            extraParams.append(.text(chat))
        }
        if recalledOnly {
            clauses.append("m.recalled_at IS NOT NULL")
        }
        switch sender {
        case .all: break
        case .mine: clauses.append("m.is_self = 1")
        case .others: clauses.append("m.is_self = 0")
        }
        if let chatKind {
            switch chatKind {
            case .group: clauses.append("m.chat LIKE '%@chatroom'")
            case .person: clauses.append("m.chat NOT LIKE '%@chatroom' AND \(LensStore.excludeNoiseM)")
            case .official, .system: break
            }
        }
        if let since {
            clauses.append("m.ts >= ?")
            extraParams.append(.int(since))
        }

        if q.isEmpty {
            guard !clauses.isEmpty else { return [] }
            let order = recalledOnly ? "m.recalled_at DESC, m.ts DESC, m.id DESC" : "m.ts DESC, m.id DESC"
            let sql = """
                SELECT \(LensStore.mCols) FROM messages m
                WHERE \(clauses.joined(separator: " AND "))
                ORDER BY \(order) LIMIT ?
                """
            return messages(sql, extraParams + [.int(Int64(limit))])
        }

        let extraSQL = clauses.isEmpty ? "" : " AND " + clauses.joined(separator: " AND ")
        var params: [SQLValue] = []
        let sql: String
        if q.count >= 3 {
            let phrase = "\"" + q.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            sql = """
                SELECT \(LensStore.mCols)
                FROM messages_fts f JOIN messages m ON m.id = f.rowid
                WHERE messages_fts MATCH ?\(extraSQL) ORDER BY m.ts DESC, m.id DESC LIMIT ?
                """
            params.append(.text(phrase))
        } else {
            sql = """
                SELECT \(LensStore.mCols) FROM messages m
                WHERE m.text LIKE ? ESCAPE '\\'\(extraSQL)
                ORDER BY m.ts DESC, m.id DESC LIMIT ?
                """
            let esc = q.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            params.append(.text("%\(esc)%"))
        }
        params.append(contentsOf: extraParams)
        params.append(.int(Int64(limit)))
        return messages(sql, params)
    }

    /// Finds the indexed message whose text matches what the user copied from WeChat.
    public func findMessage(text: String, preferChat: String? = nil, days: Int = 60) -> LensMessage? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let since = Int64(Date().timeIntervalSince1970) - Int64(days * 86400)
        let exact = messages("""
            SELECT \(LensStore.cols) FROM messages WHERE ts >= ? AND text = ? ORDER BY ts DESC LIMIT 20
            """, [.int(since), .text(t)])
        if let preferChat, let m = exact.first(where: { $0.chat == preferChat }) { return m }
        if let m = exact.first { return m }
        guard t.count >= 6 else { return nil }
        let partial = search(String(t.prefix(40)), limit: 10).filter { $0.ts >= since }
        if let preferChat, let m = partial.first(where: { $0.chat == preferChat }) { return m }
        return partial.first
    }

    public func chatList(includeOfficial: Bool = false) -> [ChatSummary] {
        var out: [ChatSummary] = []
        try? reader.query("""
            SELECT cs.chat, cs.count, cs.last_ts, IFNULL(cs.last_text,''), IFNULL(s.unread,0), IFNULL(s.hidden,0)
            FROM chat_stats cs LEFT JOIN sessions s ON s.username = cs.chat
            ORDER BY cs.last_ts DESC
            """) { r in
            let u = r.text(0) ?? ""
            let c = contact(u)
            let kind = c?.kind ?? Contact.kind(of: u)
            if !includeOfficial && (kind == .official || kind == .system) { return }
            out.append(ChatSummary(username: u, display: displayName(u), kind: kind, lastTs: r.int(2),
                                   count: Int(r.int(1)), unread: Int(r.int(4)), lastText: r.text(3) ?? "",
                                   isMuted: c?.isMuted ?? false, isFolded: c?.isFolded ?? false,
                                   isHidden: r.int(5) != 0, isPinned: c?.isPinned ?? false))
        }
        return out
    }

    /// Recent active chats eligible for the MenuBar popover: private and group chats that are
    /// neither muted (免打扰), folded (已折叠), nor hidden in WeChat's session list.
    /// Unread chats always sort to the front so older unread threads are never truncated.
    public func menuBarChats(limit: Int = 30) -> [ChatSummary] {
        let eligible = chatList(includeOfficial: false).filter {
            ($0.kind == .person || $0.kind == .group) && !$0.isMuted && !$0.isFolded && !$0.isHidden
        }
        let sorted = eligible.sorted { a, b in
            if (a.unread > 0) != (b.unread > 0) { return a.unread > 0 }
            return a.lastTs > b.lastTs
        }
        let unreadCount = sorted.prefix(while: { $0.unread > 0 }).count
        return Array(sorted.prefix(max(limit, unreadCount)))
    }

    // MARK: - analysis cache / watchlist

    public func cachedAnalysis(_ key: String) -> String? {
        try? reader.scalarText("SELECT json FROM analyses WHERE key = ?", [.text(key)])
    }

    public func latestAnalysis(kind: String, target: String) -> (json: String, created: Int64)? {
        var out: (String, Int64)?
        try? reader.query("SELECT json, created FROM analyses WHERE kind = ? AND target = ? ORDER BY created DESC LIMIT 1",
                          [.text(kind), .text(target)]) { r in out = (r.text(0) ?? "", r.int(1)) }
        return out
    }

    public func recentAnalyses(kinds: [String]? = nil, limit: Int = 100) -> [AnalysisRecord] {
        var out: [AnalysisRecord] = []
        var params: [SQLValue] = []
        let whereClause: String
        if let kinds, !kinds.isEmpty {
            let placeholders = Array(repeating: "?", count: kinds.count).joined(separator: ",")
            whereClause = "WHERE kind IN (\(placeholders))"
            params.append(contentsOf: kinds.map { .text($0) })
        } else {
            whereClause = ""
        }
        params.append(.int(Int64(limit)))
        let sql = """
            SELECT key, kind, target, model, created, json
            FROM analyses
            \(whereClause)
            ORDER BY created DESC LIMIT ?
            """
        try? reader.query(sql, params) { r in
            out.append(AnalysisRecord(
                key: r.text(0) ?? "",
                kind: r.text(1) ?? "",
                target: r.text(2) ?? "",
                model: r.text(3) ?? "",
                created: r.int(4),
                json: r.text(5) ?? ""
            ))
        }
        return out
    }

    public func saveAnalysis(key: String, kind: String, target: String, model: String, json: String) {
        _ = try? writer.run("INSERT OR REPLACE INTO analyses(key, kind, target, model, created, json) VALUES(?,?,?,?,?,?)",
                            [.text(key), .text(kind), .text(target), .text(model),
                             .int(Int64(Date().timeIntervalSince1970)), .text(json)])
    }

    public func watchlist() -> Set<String> {
        var out = Set<String>()
        try? reader.query("SELECT username FROM watchlist") { r in if let u = r.text(0) { out.insert(u) } }
        return out
    }

    public func setWatched(_ username: String, _ on: Bool) {
        if on {
            _ = try? writer.run("INSERT OR IGNORE INTO watchlist(username) VALUES(?)", [.text(username)])
        } else {
            _ = try? writer.run("DELETE FROM watchlist WHERE username = ?", [.text(username)])
        }
    }
}
