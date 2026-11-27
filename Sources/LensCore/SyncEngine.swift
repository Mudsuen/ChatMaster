import Foundation

/// Incremental, read-only copy from the live WeChat databases into the Lens index.
public final class SyncEngine: @unchecked Sendable {
    public let source: WeChatSource
    public let store: LensStore
    private let lock = NSLock()
    private var lastMetaSignature = ""
    private var lastClears: [String: Int64] = [:]
    private var pendingOpened: [String] = []

    public struct Progress: Sendable {
        public var phase: String
        public var done: Int
        public var total: Int
    }

    public struct Result: Sendable {
        public var inserted = 0
        public var newMessages: [LensMessage] = []
        public var recalled: [LensMessage] = []
        /// Chats the user opened in WeChat since the previous sync (oldest first).
        public var openedChats: [String] = []
        public var touchedChats: Set<String> = []
        public var errors: [String] = []
        public var metaChanged = false
    }

    public init(source: WeChatSource, store: LensStore) {
        self.source = source
        self.store = store
    }

    /// Contacts + sessions. Cheap; runs when contact/session databases change.
    @discardableResult
    public func syncMeta(force: Bool = false) throws -> Bool {
        let sig = source.signature("contact/contact.db") + "#" + source.signature("session/session.db")
        guard force || sig != lastMetaSignature else { return false }
        if force || source.signature("contact/contact.db") != store.kv("sig:contact") || store.allContacts().isEmpty {
            try store.replaceContacts(try source.loadContacts(), selfUsername: source.selfUsername)
            store.setKV("sig:contact", source.signature("contact/contact.db"))
        }
        let sessions = try source.loadSessions()
        if !lastClears.isEmpty {
            // A newer unread-clear timestamp means the user just opened that chat in WeChat.
            let opened = sessions.filter { $0.lastClearUnread > (lastClears[$0.username] ?? 0) && lastClears[$0.username] != nil }
                .sorted { $0.lastClearUnread < $1.lastClearUnread }.map(\.username)
            pendingOpened.append(contentsOf: opened)
        }
        lastClears = Dictionary(sessions.map { ($0.username, $0.lastClearUnread) }, uniquingKeysWith: max)
        try store.replaceSessions(sessions)
        lastMetaSignature = sig
        return true
    }

    public func sync(force: Bool = false, progress: ((Progress) -> Void)? = nil) -> Result {
        lock.lock(); defer { lock.unlock() }
        var result = Result()
        do { result.metaChanged = try syncMeta(force: force) } catch { result.errors.append("联系人/会话: \(error)") }
        result.openedChats = pendingOpened
        pendingOpened = []
        let initial = !store.hasData
        let dbs = source.messageDBs
        let contactHashes = Dictionary(store.allContacts().map { (WeChatSource.md5($0.username), $0.username) },
                                       uniquingKeysWith: { a, _ in a })
        for (i, rel) in dbs.enumerated() {
            let sig = source.signature(rel)
            if !force && store.kv("sig:\(rel)") == sig { continue }
            progress?(Progress(phase: rel, done: i, total: dbs.count))
            do {
                try syncDB(rel, initial: initial, contactHashes: contactHashes, result: &result) { done, total in
                    progress?(Progress(phase: "\(rel) \(done)/\(total)", done: i, total: dbs.count))
                }
                store.setKV("sig:\(rel)", sig)
            } catch {
                result.errors.append("\(rel): \(error)")
                source.dropConnection(rel)
            }
        }
        if result.inserted > 0 || initial || !result.recalled.isEmpty {
            try? store.refreshChatStats(initial ? nil : result.touchedChats)
        }
        store.setKV("last_sync", String(Int(Date().timeIntervalSince1970)))
        progress?(Progress(phase: "完成", done: dbs.count, total: dbs.count))
        return result
    }

    private func syncDB(_ rel: String, initial: Bool, contactHashes: [String: String], result: inout Result,
                        tick: (Int, Int) -> Void) throws {
        let db = try source.connection(rel)
        var senders: [Int64: String] = [:]
        var tables: [String: String] = contactHashes
        try db.query("SELECT rowid, user_name FROM Name2Id") { r in
            let u = r.text(1) ?? ""
            senders[r.int(0)] = u
            tables[WeChatSource.md5(u)] = u
        }
        var names: [String] = []
        try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Msg_%'") { r in
            if let n = r.text(0), n.count == 36 { names.append(n) }
        }
        let wms = store.watermarks(src: rel)
        let me = source.selfUsername
        // WeChat allows recalls for 2 minutes; recheck system rows of the last 10 minutes.
        let recallCutoff = (Int64(Date().timeIntervalSince1970) - 600) * 1000
        for (ti, t) in names.enumerated() {
            if ti % 50 == 0 { tick(ti, names.count) }
            let hash = String(t.dropFirst(4))
            guard let chat = tables[hash] else { continue }
            let maxID = try db.scalarInt("SELECT max(local_id) FROM \"\(t)\"") ?? 0
            let wm = wms[hash] ?? 0
            if maxID <= wm {
                // No new rows; only look for messages rewritten into recall notices.
                if initial { continue }
                let revoked = try db.scalarInt(
                    "SELECT count(*) FROM \"\(t)\" WHERE sort_seq >= ? AND local_type = 10000", [.int(recallCutoff)]) ?? 0
                guard revoked > 0 else { continue }
            }
            // Re-read a small overlap so edits of the newest rows are picked up.
            let from = initial || wm == 0 ? wm : max(0, wm - 5)
            var rows: [LensStore.IndexRow] = []
            let sql = """
                SELECT local_id, IFNULL(server_id,0), local_type, real_sender_id, create_time, message_content,
                       IFNULL(WCDB_CT_message_content,0)
                FROM "\(t)" WHERE local_id > ? OR (sort_seq >= ? AND local_type = 10000) ORDER BY local_id
                """
            try db.query(sql, [.int(from), .int(initial ? Int64.max : recallCutoff)]) { r in
                let isBlob = r.isBlob(5)
                let raw = RawMessage(localID: r.int(0), serverID: r.int(1), localType: r.int(2),
                                     senderUsername: senders[r.int(3)], createTime: r.int(4),
                                     content: isBlob ? r.blob(5) : nil, contentText: isBlob ? nil : r.text(5),
                                     compression: r.int(6))
                let d = MessageDecoder.decode(raw, chat: chat)
                var sender = d.sender
                if sender == nil || sender?.isEmpty == true { sender = chat.hasSuffix("@chatroom") ? nil : chat }
                let isSelf = sender == me
                let textual = d.baseType == 1 || (d.baseType == 49 && d.subType == 57)
                rows.append(LensStore.IndexRow(src: rel, tbl: hash, localID: raw.localID, serverID: raw.serverID,
                                               chat: chat, sender: sender, isSelf: isSelf, ts: raw.createTime,
                                               decoded: d, sentiment: textual ? Sentiment.score(d.text) : nil))
            }
            let recalledIDs = try store.ingest(rows, src: rel, tbl: hash, watermark: max(maxID, wm))
            if !recalledIDs.isEmpty {
                result.recalled.append(contentsOf: store.messages(ids: recalledIDs))
                result.touchedChats.insert(chat)
            }
            let fresh = rows.filter { $0.localID > wm }
            result.inserted += fresh.count
            if !fresh.isEmpty { result.touchedChats.insert(chat) }
            if !initial && wm > 0 && !fresh.isEmpty && result.newMessages.count < 500 {
                var found: [LensMessage] = []
                try? store.reader.query("""
                    SELECT \(LensStore.cols) FROM messages WHERE src = ? AND tbl = ? AND local_id > ? ORDER BY ts, id
                    """, [.text(rel), .text(hash), .int(wm)]) { found.append(LensStore.message($0)) }
                result.newMessages.append(contentsOf: found)
            }
        }
    }
}
