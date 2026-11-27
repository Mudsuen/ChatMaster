import Foundation
import LensCore

// chatmasterctl: headless checks for the ChatMaster data path and analysis engine.
//   chatmasterctl sync            incremental sync (first run imports everything)
//   chatmasterctl status          index totals and data-source state
//   chatmasterctl menubar         anonymized breakdown of muted/folded/eligible MenuBar chats
//   chatmasterctl recent [n]      newest messages (metadata + length only)
//   chatmasterctl analyze <id>    run the single-message analysis through agy

func out(_ s: String) { print(s); fflush(stdout) }

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "status"

do {
    let source = try WeChatSource()
    let store = try LensStore()
    let sync = SyncEngine(source: source, store: store)
    switch cmd {
    case "sync":
        let t0 = Date()
        var lastPhase = ""
        let r = sync.sync(force: args.contains("--force")) { p in
            if p.phase != lastPhase { lastPhase = p.phase; out("  [\(p.done)/\(p.total)] \(p.phase)") }
        }
        out("inserted: \(r.inserted) | new (live): \(r.newMessages.count) | chats touched: \(r.touchedChats.count) | \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        for e in r.errors { out("ERROR \(e)") }
    case "status":
        let o = store.overview()
        out("self: \(source.selfUsername) | message dbs: \(source.messageDBs.count) | missing keys: \(source.missingKeyDBs)")
        out("index total: \(store.totalMessages()) | filtered: \(o.total) | today: \(o.today) | week: \(o.week) | contacts: \(o.contacts) groups: \(o.groups)")
        out("chats: \(store.chatList().count) | menubar: \(store.menuBarChats(limit: 40).count) | pending replies: \(store.pendingReplies().count)")
    case "menubar":
        let all = store.chatList(includeOfficial: false)
        let muted = all.filter(\.isMuted).count
        let folded = all.filter(\.isFolded).count
        let hidden = all.filter(\.isHidden).count
        let eligible = store.menuBarChats(limit: 40)
        let unread = eligible.reduce(0) { $0 + $1.unread }
        let now = Int64(Date().timeIntervalSince1970)
        out("chats=\(all.count) muted=\(muted) folded=\(folded) hidden=\(hidden) eligible=\(eligible.count) unread=\(unread)")
        for c in eligible.prefix(10) {
            out("  \(c.kind.rawValue) unread=\(c.unread) pinned=\(c.isPinned) age=\(max(0, now - c.lastTs))s")
        }
    case "sessions":
        // Diagnostics for current-chat detection: unread clears per session (no content).
        let db = try source.connection("session/session.db")
        let now = Int64(Date().timeIntervalSince1970)
        try db.query("""
            SELECT username, unread_count, last_timestamp, last_clear_unread_timestamp FROM SessionTable
            ORDER BY max(last_timestamp, IFNULL(last_clear_unread_timestamp,0)) DESC LIMIT 12
            """) { r in
            out("\((r.text(0) ?? "").prefix(8))… unread=\(r.int(1)) last=\(now - r.int(2))s clear=\(r.isNull(3) || r.int(3) == 0 ? "-" : String(now - r.int(3)) + "s")")
        }
    case "recent":
        let n = Int(args.dropFirst().first ?? "") ?? 10
        for m in store.recent(limit: n) {
            out("#\(m.id) \(m.date) chat=\(m.chat.prefix(10))… self=\(m.isSelf) kind=\(m.kind) len=\(m.text.count) senti=\(m.sentiment.map { String(format: "%.2f", $0) } ?? "-")")
        }
    case "analyze":
        guard let id = Int64(args.dropFirst().first ?? ""), let m = store.message(id: id) else {
            out("usage: lensctl analyze <message id>"); exit(2)
        }
        guard let bin = AgyClient.resolveBinary() else { out("agy not found"); exit(2) }
        let engine = AnalysisEngine(store: store, config: AgyConfig(binary: bin, model: AgyConfig.defaultModel))
        let sem = DispatchSemaphore(value: 0)
        let t0 = Date()
        Task {
            do {
                let a = try await engine.analyze(message: m, force: args.contains("--force"))
                out("emotion=\(a.emotion) \(a.emoji) valence=\(a.valence) intensity=\(a.intensity) intent=\(a.intent) urgency=\(a.urgency) needsReply=\(a.needsReply) replies=\(a.replySuggestions.count) conf=\(a.confidence)")
            } catch {
                out("ERROR \(error.localizedDescription)")
            }
            sem.signal()
        }
        sem.wait()
        out(String(format: "%.1fs", Date().timeIntervalSince(t0)))
    case "conv", "rel", "brief":
        guard let bin = AgyClient.resolveBinary() else { out("agy not found"); exit(2) }
        let engine = AnalysisEngine(store: store, config: AgyConfig(binary: bin, model: AgyConfig.defaultModel))
        let target = args.dropFirst().first ?? ""
        let sem = DispatchSemaphore(value: 0)
        let t0 = Date()
        Task {
            do {
                switch cmd {
                case "conv":
                    let a = try await engine.analyzeConversation(chat: target, limit: 40)
                    out("mood=\(a.overallMood) topics=\(a.topics.count) todos=\(a.myTodos.count) replies=\(a.replySuggestions.count) summaryLen=\(a.summary.count)")
                case "rel":
                    let r = try await engine.relationshipReport(chat: target)
                    out("closeness=\(r.closeness) label=\(r.closenessLabel) strengths=\(r.strengths.count) suggestions=\(r.suggestions.count)")
                default:
                    let b = try await engine.dailyBriefing(day: Date())
                    out("highlights=\(b.highlights.count) needReply=\(b.needReply.count) promises=\(b.myPromises.count) headlineLen=\(b.headline.count)")
                }
            } catch {
                out("ERROR \(error.localizedDescription)")
            }
            sem.signal()
        }
        sem.wait()
        out(String(format: "%.1fs", Date().timeIntervalSince(t0)))
    default:
        out("unknown command \(cmd)")
        exit(2)
    }
} catch {
    out("ERROR \(error)")
    exit(1)
}
