import Foundation

public struct Overview: Sendable {
    public var total = 0
    public var today = 0
    public var week = 0
    public var activeChatsToday = 0
    public var sentByMe = 0
    public var firstTs: Int64 = 0
    public var lastTs: Int64 = 0
    public var contacts = 0
    public var groups = 0

    public init() {}
}

public struct DayCount: Identifiable, Sendable {
    public var id: Date { date }
    public var date: Date
    public var total: Int
    public var mine: Int
}

public struct HeatCell: Identifiable, Sendable {
    public var id: Int { weekday * 24 + hour }
    public var weekday: Int  // 0 = Monday
    public var hour: Int
    public var count: Int
}

public struct KindCount: Identifiable, Sendable {
    public var id: String { kind }
    public var kind: String
    public var count: Int

    public init(kind: String, count: Int) {
        self.kind = kind
        self.count = count
    }
}

public struct ChatCount: Identifiable, Sendable {
    public var id: String { chat }
    public var chat: String
    public var display: String
    public var count: Int
    public var mine: Int
}

public struct MonthPoint: Identifiable, Sendable {
    public var id: Date { month }
    public var month: Date
    public var mine: Int
    public var theirs: Int
    public var mySentiment: Double?
    public var theirSentiment: Double?
}

public struct RelationshipStats: Sendable {
    public var chat: String
    public var total = 0
    public var mine = 0
    public var firstTs: Int64 = 0
    public var lastTs: Int64 = 0
    public var months: [MonthPoint] = []
    public var myInitiations = 0
    public var theirInitiations = 0
    public var myMedianReply: Double?
    public var theirMedianReply: Double?
    public var hourlyMine = Array(repeating: 0, count: 24)
    public var hourlyTheirs = Array(repeating: 0, count: 24)
    public var activeDays = 0
    public var topSenders: [ChatCount] = []
}

public struct PendingReply: Identifiable, Sendable {
    public var id: String { chat }
    public var chat: String
    public var display: String
    public var kind: ChatKind
    public var lastTs: Int64
    public var waiting: TimeInterval
    public var recent: [LensMessage]
    public var score: Double
    public var reasons: [String]
}

extension LensStore {
    private func int(_ sql: String, _ params: [SQLValue] = []) -> Int {
        Int((try? reader.scalarInt(sql, params)) ?? 0)
    }

    static func startOfToday() -> Int64 { Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970) }

    public func overview() -> Overview {
        var o = Overview()
        let today = LensStore.startOfToday()
        let f = LensStore.excludeNoise
        try? reader.query("SELECT count(*), IFNULL(sum(is_self),0), IFNULL(min(ts),0), IFNULL(max(ts),0) FROM messages WHERE \(f)") { r in
            o.total = Int(r.int(0)); o.sentByMe = Int(r.int(1)); o.firstTs = r.int(2); o.lastTs = r.int(3)
        }
        o.today = int("SELECT count(*) FROM messages WHERE ts >= ? AND \(f)", [.int(today)])
        o.week = int("SELECT count(*) FROM messages WHERE ts >= ? AND \(f)", [.int(today - 6 * 86400)])
        o.activeChatsToday = int("SELECT count(DISTINCT chat) FROM messages WHERE ts >= ? AND \(f)", [.int(today)])
        let cs = allContacts()
        o.contacts = cs.filter { $0.kind == .person }.count
        o.groups = cs.filter { $0.kind == .group }.count
        return o
    }

    public func dailyCounts(days: Int = 90) -> [DayCount] {
        let since = LensStore.startOfToday() - Int64(days - 1) * 86400
        var map: [String: (Int, Int)] = [:]
        try? reader.query("""
            SELECT date(ts, 'unixepoch', 'localtime') d, count(*), sum(is_self) FROM messages
            WHERE ts >= ? AND \(LensStore.excludeNoise) GROUP BY d
            """, [.int(since)]) { r in map[r.text(0) ?? ""] = (Int(r.int(1)), Int(r.int(2))) }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return (0..<days).map { i in
            let d = Date(timeIntervalSince1970: TimeInterval(since + Int64(i) * 86400))
            let v = map[fmt.string(from: d)] ?? (0, 0)
            return DayCount(date: d, total: v.0, mine: v.1)
        }
    }

    public func heatmap(days: Int = 365, chat: String? = nil) -> [HeatCell] {
        let since = LensStore.startOfToday() - Int64(days) * 86400
        var grid = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        let chatFilter = chat == nil ? LensStore.excludeNoise : "chat = ?"
        var params: [SQLValue] = [.int(since)]
        if let chat { params.append(.text(chat)) }
        try? reader.query("""
            SELECT CAST(strftime('%w', ts, 'unixepoch', 'localtime') AS INTEGER),
                   CAST(strftime('%H', ts, 'unixepoch', 'localtime') AS INTEGER), count(*)
            FROM messages WHERE ts >= ? AND \(chatFilter) GROUP BY 1, 2
            """, params) { r in
            let w = (Int(r.int(0)) + 6) % 7  // Sunday=0 -> Monday-first
            grid[w][Int(r.int(1))] = Int(r.int(2))
        }
        var out: [HeatCell] = []
        for w in 0..<7 { for h in 0..<24 { out.append(HeatCell(weekday: w, hour: h, count: grid[w][h])) } }
        return out
    }

    public func kindCounts(days: Int = 365) -> [KindCount] {
        let since = LensStore.startOfToday() - Int64(days) * 86400
        var out: [KindCount] = []
        try? reader.query("""
            SELECT kind, count(*) FROM messages WHERE ts >= ? AND \(LensStore.excludeNoise)
            GROUP BY kind ORDER BY 2 DESC
            """, [.int(since)]) { r in out.append(KindCount(kind: r.text(0) ?? "?", count: Int(r.int(1)))) }
        return out
    }

    public func topChats(days: Int = 30, limit: Int = 12, kind: ChatKind? = nil) -> [ChatCount] {
        let since = LensStore.startOfToday() - Int64(days) * 86400
        var out: [ChatCount] = []
        try? reader.query("""
            SELECT chat, count(*), sum(is_self) FROM messages WHERE ts >= ? AND \(LensStore.excludeNoise)
            GROUP BY chat ORDER BY 2 DESC LIMIT ?
            """, [.int(since), .int(Int64(limit * 3))]) { r in
            let c = r.text(0) ?? ""
            let k = contact(c)?.kind ?? Contact.kind(of: c)
            if let kind, k != kind { return }
            out.append(ChatCount(chat: c, display: displayName(c), count: Int(r.int(1)), mine: Int(r.int(2))))
        }
        return Array(out.prefix(limit))
    }

    public func relationship(chat: String) -> RelationshipStats {
        var s = RelationshipStats(chat: chat)
        try? reader.query("SELECT count(*), IFNULL(sum(is_self),0), IFNULL(min(ts),0), IFNULL(max(ts),0), count(DISTINCT date(ts,'unixepoch','localtime')) FROM messages WHERE chat = ?",
                          [.text(chat)]) { r in
            s.total = Int(r.int(0)); s.mine = Int(r.int(1)); s.firstTs = r.int(2); s.lastTs = r.int(3); s.activeDays = Int(r.int(4))
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        try? reader.query("""
            SELECT strftime('%Y-%m', ts, 'unixepoch', 'localtime') m,
                   sum(is_self), sum(1 - is_self),
                   avg(CASE WHEN is_self = 1 AND sentiment != 0 THEN sentiment END), avg(CASE WHEN is_self = 0 AND sentiment != 0 THEN sentiment END)
            FROM messages WHERE chat = ? AND base_type != 10000 GROUP BY m ORDER BY m
            """, [.text(chat)]) { r in
            guard let d = fmt.date(from: r.text(0) ?? "") else { return }
            s.months.append(MonthPoint(month: d, mine: Int(r.int(1)), theirs: Int(r.int(2)),
                                       mySentiment: r.isNull(3) ? nil : r.double(3),
                                       theirSentiment: r.isNull(4) ? nil : r.double(4)))
        }
        // Initiations (first message after a 6h gap) and reply latency (sender switch within 12h).
        var prevTs: Int64 = 0
        var prevSelf: Bool?
        var mine: [Double] = [], theirs: [Double] = []
        try? reader.query("""
            SELECT ts, is_self, CAST(strftime('%H', ts, 'unixepoch', 'localtime') AS INTEGER)
            FROM messages WHERE chat = ? AND base_type != 10000 ORDER BY ts, id
            """, [.text(chat)]) { r in
            let ts = r.int(0), me = r.int(1) != 0, h = Int(r.int(2))
            if me { s.hourlyMine[h] += 1 } else { s.hourlyTheirs[h] += 1 }
            let gap = ts - prevTs
            if prevSelf == nil || gap > 6 * 3600 {
                if me { s.myInitiations += 1 } else { s.theirInitiations += 1 }
            } else if let ps = prevSelf, ps != me, gap <= 12 * 3600 {
                if me { mine.append(Double(gap)) } else { theirs.append(Double(gap)) }
            }
            prevTs = ts
            prevSelf = me
        }
        s.myMedianReply = LensStore.median(mine)
        s.theirMedianReply = LensStore.median(theirs)
        if chat.hasSuffix("@chatroom") {
            try? reader.query("""
                SELECT sender, count(*) FROM messages WHERE chat = ? AND sender IS NOT NULL AND base_type != 10000
                GROUP BY sender ORDER BY 2 DESC LIMIT 10
                """, [.text(chat)]) { r in
                let u = r.text(0) ?? ""
                s.topSenders.append(ChatCount(chat: u, display: displayName(u), count: Int(r.int(1)), mine: 0))
            }
        }
        return s
    }

    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static let questionMarkers = ["?", "？", "吗", "呢", "么", "怎么", "什么", "能不能", "可不可以", "是否", "有没有", "几点", "哪", "要不要", "好不好"]
    static let requestMarkers = ["帮", "麻烦", "请", "能否", "记得", "需要你", "辛苦", "尽快", "急", "等你", "回复", "确认"]

    /// Conversations where the other side is waiting for me.
    public func pendingReplies(days: Int = 7, limit: Int = 40) -> [PendingReply] {
        let now = Int64(Date().timeIntervalSince1970)
        let since = now - Int64(days) * 86400
        var chats: [(String, Int, Int64)] = []
        try? reader.query("SELECT chat, count, last_ts FROM chat_stats WHERE last_ts >= ? ORDER BY last_ts DESC LIMIT 150",
                          [.int(since)]) { r in chats.append((r.text(0) ?? "", Int(r.int(1)), r.int(2))) }
        let myName = selfDisplayName
        var out: [PendingReply] = []
        for (chat, count, lastTs) in chats {
            let kind = contact(chat)?.kind ?? Contact.kind(of: chat)
            guard kind == .person || kind == .group else { continue }
            let recent = messages(chat: chat, limit: 12).filter { !$0.isSystem }
            guard let last = recent.last, !last.isSelf else { continue }
            // Skip merchants / broadcasters: I must have replied in this chat recently.
            let mine = int("SELECT count(*) FROM messages WHERE chat = ? AND is_self = 1 AND ts >= ?",
                           [.text(chat), .int(now - 180 * 86400)])
            guard mine >= 3 else { continue }
            let waitingMsgs = Array(recent.reversed().prefix { !$0.isSelf }.reversed())
            guard waitingMsgs.contains(where: { $0.isTextual }) else { continue }
            let joined = waitingMsgs.filter(\.isTextual).map(\.text).joined(separator: "\n")
            var score = 0.0
            var reasons: [String] = []
            if kind == .group {
                guard !myName.isEmpty, joined.contains("@\(myName)") else { continue }
                score += 3; reasons.append("群里 @ 了你")
            }
            if LensStore.questionMarkers.contains(where: { joined.contains($0) }) { score += 2; reasons.append("有提问") }
            if LensStore.requestMarkers.contains(where: { joined.contains($0) }) { score += 1.5; reasons.append("有请求") }
            if waitingMsgs.count >= 3 { score += 1; reasons.append("连发 \(waitingMsgs.count) 条") }
            let waiting = TimeInterval(now - lastTs)
            score += min(3, log2(1 + waiting / 1800))
            score += min(2, log10(Double(max(count, 1))) / 1.5)
            if let s = waitingMsgs.compactMap(\.sentiment).min(), s < -0.35 { score += 1; reasons.append("情绪偏消极") }
            if reasons.isEmpty && waiting < 600 { continue }
            out.append(PendingReply(chat: chat, display: displayName(chat), kind: kind, lastTs: lastTs, waiting: waiting,
                                    recent: Array(recent.suffix(6)), score: score, reasons: reasons))
        }
        return Array(out.sorted { $0.score > $1.score }.prefix(limit))
    }
}
