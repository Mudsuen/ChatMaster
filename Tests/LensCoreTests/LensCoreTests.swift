import Foundation
@testable import LensCore
import XCTest

final class DecoderTests: XCTestCase {
    func raw(_ type: Int64, _ text: String, sender: String? = nil) -> RawMessage {
        RawMessage(localID: 1, serverID: 0, localType: type, senderUsername: sender, createTime: 0, content: nil,
                   contentText: text, compression: 0)
    }

    func testGroupPrefixIsStrippedAndSenderRecovered() {
        let d = MessageDecoder.decode(raw(1, "wxid_abc123:\n晚上一起吃饭吗"), chat: "123@chatroom")
        XCTAssertEqual(d.text, "晚上一起吃饭吗")
        XCTAssertEqual(d.sender, "wxid_abc123")
    }

    func testPrivateTextUntouched() {
        let d = MessageDecoder.decode(raw(1, "a:\nb", sender: "wxid_x"), chat: "wxid_x")
        XCTAssertEqual(d.text, "a:\nb")
    }

    func testQuoteReply() {
        let xml = """
            <msg><appmsg><title>好的，没问题</title><type>57</type>
            <refermsg><type>1</type><displayname>小王</displayname><content>明天十点开会</content></refermsg>
            </appmsg></msg>
            """
        let d = MessageDecoder.decode(raw((57 << 32) | 49, xml), chat: "wxid_x")
        XCTAssertEqual(d.kind, "引用")
        XCTAssertEqual(d.text, "好的，没问题")
        XCTAssertEqual(d.quote, "小王: 明天十点开会")
    }

    func testZstdContent() throws {
        // "hello" compressed with zstd (frame with content size)
        let bytes: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x05, 0x29, 0x00, 0x00, 0x68, 0x65, 0x6C, 0x6C, 0x6F]
        let data = Data(bytes)
        XCTAssertTrue(Zstd.isCompressed(data))
        XCTAssertEqual(Zstd.decompress(data).map { String(decoding: $0, as: UTF8.self) }, "hello")
    }

    func testSelfUsername() {
        XCTAssertEqual(WeChatSource.selfUsername(fromDBDir: "/x/xwechat_files/wxid_example12345_f3eb/db_storage"),
                       "wxid_example12345")
    }
}

final class SentimentTests: XCTestCase {
    func testPolarity() {
        XCTAssertGreaterThan(Sentiment.score("太好了，谢谢你！")!, 0.3)
        XCTAssertLessThan(Sentiment.score("气死我了，又迟到")!, -0.3)
        XCTAssertLessThan(Sentiment.score("行吧，你忙你的，不用管我了")!, -0.2)
        XCTAssertEqual(Sentiment.score("明天开会")!, 0)
        XCTAssertGreaterThan(Sentiment.score("我不累")!, 0)
    }
}

final class AgyParsingTests: XCTestCase {
    func testStructuredOutputPreferred() throws {
        let out = #"{"conversation_id":"x","status":"SUCCESS","response":"blah","structured_output":{"emotion":"开心","intensity":4}}"#
        let r = try AgyClient.parse(out: Data(out.utf8), err: Data(), status: 0, timedOut: false, model: "m")
        let a = try JSONDecoder().decode(MessageAnalysis.self, from: r.json)
        XCTAssertEqual(a.emotion, "开心")
        XCTAssertEqual(a.intensity, 4)
        XCTAssertEqual(a.intent, "其他")  // tolerant default
    }

    func testFallsBackToLastJSONInResponse() throws {
        let resp = "### 分析\\n一些文字 {不是json}\\n{\\\"emotion\\\":\\\"委屈\\\",\\\"valence\\\":-0.6}"
        let out = "warning: x\n{\"status\":\"SUCCESS\",\"response\":\"\(resp)\"}"
        let r = try AgyClient.parse(out: Data(out.utf8), err: Data(), status: 0, timedOut: false, model: "m")
        let a = try JSONDecoder().decode(MessageAnalysis.self, from: r.json)
        XCTAssertEqual(a.emotion, "委屈")
        XCTAssertEqual(a.valence, -0.6)
    }

    func testLoginHint() {
        XCTAssertThrowsError(try AgyClient.parse(out: Data(), err: Data("Please login first".utf8), status: 1,
                                                 timedOut: false, model: "m")) { e in
            XCTAssertTrue((e as? AgyError)?.message.contains("未登录") == true)
        }
    }
}

final class StoreTests: XCTestCase {
    func testIngestSearchAndFind() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lens-test-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + s) } }
        let store = try LensStore(url: url)
        let rows = ["今天晚上一起吃火锅吗", "好呀，几点？", "七点老地方"].enumerated().map { i, t in
            LensStore.IndexRow(src: "message/message_0.db", tbl: "abc", localID: Int64(i + 1), serverID: 0, chat: "wxid_a",
                               sender: i == 1 ? "me" : "wxid_a", isSelf: i == 1, ts: Int64(Date().timeIntervalSince1970) - 100 + Int64(i),
                               decoded: DecodedMessage(sender: nil, baseType: 1, subType: 0, kind: "文本", text: t, quote: nil),
                               sentiment: Sentiment.score(t))
        }
        try store.ingest(rows, src: "message/message_0.db", tbl: "abc", watermark: 3)
        try store.refreshChatStats()
        XCTAssertEqual(store.totalMessages(), 3)
        XCTAssertEqual(store.search("吃火锅").count, 1)
        XCTAssertEqual(store.search("几点").count, 1)  // short query -> LIKE path
        XCTAssertEqual(store.findMessage(text: " 七点老地方 ")?.text, "七点老地方")
        XCTAssertEqual(store.watermarks(src: "message/message_0.db")["abc"], 3)
        XCTAssertEqual(store.chatList(includeOfficial: true).first?.count, 3)
        // Re-ingesting the same rows is idempotent.
        try store.ingest(rows, src: "message/message_0.db", tbl: "abc", watermark: 3)
        XCTAssertEqual(store.totalMessages(), 3)

        store.saveAnalysis(key: "msg:1", kind: "msg", target: "wxid_a", model: "m1", json: #"{"emotion":"开心"}"#)
        store.saveAnalysis(key: "conv:wxid_a:1:80", kind: "conv", target: "wxid_a", model: "m1", json: #"{"summary":"ok"}"#)
        XCTAssertEqual(store.recentAnalyses(kinds: nil).count, 2)
        XCTAssertEqual(store.recentAnalyses(kinds: ["msg", "text"]).map(\.key), ["msg:1"])
        XCTAssertEqual(store.recentAnalyses(kinds: ["conv"]).map(\.key), ["conv:wxid_a:1:80"])
    }
}

final class RecallTests: XCTestCase {
    func testRevokeDecoding() {
        let xml = #"<?xml version="1.0"?><sysmsg type="revokemsg"><revokemsg><content>"小王" recalled a message</content><revoketime>0</revoketime></revokemsg></sysmsg>"#
        let d = MessageDecoder.decode(RawMessage(localID: 1, serverID: 0, localType: 10000, senderUsername: nil, createTime: 0,
                                                 content: nil, contentText: xml, compression: 0), chat: "wxid_x")
        XCTAssertTrue(d.isRevoke)
        XCTAssertEqual(d.kind, "撤回")
        XCTAssertEqual(d.text, "\"小王\" recalled a message")
    }

    func testRecallKeepsOriginalText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lens-recall-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + s) } }
        let store = try LensStore(url: url)
        let ts = Int64(Date().timeIntervalSince1970) - 30
        func row(_ d: DecodedMessage) -> LensStore.IndexRow {
            LensStore.IndexRow(src: "message/message_0.db", tbl: "t", localID: 7, serverID: 99, chat: "wxid_a", sender: "wxid_a",
                               isSelf: false, ts: ts, decoded: d, sentiment: nil)
        }
        try store.ingest([row(DecodedMessage(sender: nil, baseType: 1, subType: 0, kind: "文本", text: "其实我有点生气", quote: nil))],
                         src: "message/message_0.db", tbl: "t", watermark: 7)
        let revoke = DecodedMessage(sender: nil, baseType: 10000, subType: 0, kind: "撤回", text: "\"A\" recalled a message",
                                    quote: nil, isRevoke: true)
        let ids = try store.ingest([row(revoke)], src: "message/message_0.db", tbl: "t", watermark: 7)
        XCTAssertEqual(ids.count, 1)
        // A second pass over the same recall is a no-op.
        XCTAssertTrue(try store.ingest([row(revoke)], src: "message/message_0.db", tbl: "t", watermark: 7).isEmpty)
        let m = try XCTUnwrap(store.recalledMessages().first)
        XCTAssertEqual(m.text, "其实我有点生气")
        XCTAssertEqual(m.baseType, 1)
        XCTAssertEqual(m.recallNotice, "\"A\" recalled a message")
        XCTAssertNotNil(m.recallDelay)
        XCTAssertEqual(store.search("有点生气").first?.isRecalled, true)
        XCTAssertEqual(store.recalledChatCounts(), ["wxid_a": 1])
        XCTAssertEqual(store.recalledMessages(chat: "wxid_a").map(\.text), ["其实我有点生气"])
        XCTAssertTrue(store.recalledMessages(chat: "wxid_other").isEmpty)
        XCTAssertEqual(store.search("", recalledOnly: true).map(\.text), ["其实我有点生气"])
        XCTAssertTrue(store.search("").isEmpty)
    }

    func testFilteredSearch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lens-search-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + s) } }
        let store = try LensStore(url: url)
        let now = Int64(Date().timeIntervalSince1970)
        let rows: [LensStore.IndexRow] = [
            LensStore.IndexRow(src: "message/message_0.db", tbl: "a", localID: 1, serverID: 1, chat: "wxid_a",
                               sender: "wxid_a", isSelf: false, ts: now - 3600,
                               decoded: DecodedMessage(sender: nil, baseType: 1, subType: 0, kind: "文本", text: "今天喝奶茶吗", quote: nil),
                               sentiment: nil),
            LensStore.IndexRow(src: "message/message_0.db", tbl: "a", localID: 2, serverID: 2, chat: "wxid_a",
                               sender: "me", isSelf: true, ts: now - 60,
                               decoded: DecodedMessage(sender: nil, baseType: 1, subType: 0, kind: "文本", text: "喝呀，奶茶安排上", quote: nil),
                               sentiment: nil),
            LensStore.IndexRow(src: "message/message_0.db", tbl: "g", localID: 3, serverID: 3, chat: "100@chatroom",
                               sender: "wxid_b", isSelf: false, ts: now - 7200,
                               decoded: DecodedMessage(sender: nil, baseType: 1, subType: 0, kind: "文本", text: "群里喝奶茶", quote: nil),
                               sentiment: nil),
        ]
        try store.ingest(rows, src: "message/message_0.db", tbl: "a", watermark: 3)
        // Mark message 3 as recalled.
        try store.ingest([
            LensStore.IndexRow(src: "message/message_0.db", tbl: "g", localID: 3, serverID: 3, chat: "100@chatroom",
                               sender: "wxid_b", isSelf: false, ts: now - 7200,
                               decoded: DecodedMessage(sender: nil, baseType: 10000, subType: 0, kind: "撤回", text: "\"B\" recalled a message", quote: nil, isRevoke: true),
                               sentiment: nil),
        ], src: "message/message_0.db", tbl: "g", watermark: 3)

        XCTAssertEqual(store.search("奶茶").count, 3)
        XCTAssertEqual(store.search("奶茶", sender: .mine).map(\.text), ["喝呀，奶茶安排上"])
        XCTAssertEqual(store.search("奶茶", sender: .others).count, 2)
        XCTAssertEqual(store.search("奶茶", chatKind: .group).map(\.text), ["群里喝奶茶"])
        XCTAssertEqual(store.search("奶茶", chatKind: .person).count, 2)
        XCTAssertEqual(store.search("奶茶", recalledOnly: true).map(\.text), ["群里喝奶茶"])
        XCTAssertEqual(store.search("奶茶", since: now - 120).map(\.text), ["喝呀，奶茶安排上"])
        // Short query (< 3 chars -> LIKE path) with filters.
        XCTAssertEqual(store.search("喝", recalledOnly: true, chatKind: .group).map(\.text), ["群里喝奶茶"])
        // Empty query with filter-only browse.
        XCTAssertEqual(store.search("", chat: "wxid_a", sender: .mine).map(\.text), ["喝呀，奶茶安排上"])
        XCTAssertEqual(store.search("", recalledOnly: true, chatKind: .group).map(\.text), ["群里喝奶茶"])
    }
}

final class MuteFoldTests: XCTestCase {
    func testContactFlags() {
        let normalPerson = Contact(username: "wxid_a", remark: "A", nick: "", alias: "", kind: .person, flag: 0x3, chatRoomNotify: 0)
        XCTAssertFalse(normalPerson.isMuted)
        XCTAssertFalse(normalPerson.isFolded)
        XCTAssertFalse(normalPerson.isPinned)

        let mutedPerson = Contact(username: "wxid_b", remark: "B", nick: "", alias: "", kind: .person, flag: 0x203, chatRoomNotify: 0)
        XCTAssertTrue(mutedPerson.isMuted)
        XCTAssertFalse(mutedPerson.isFolded)

        let pinnedPerson = Contact(username: "wxid_c", remark: "C", nick: "", alias: "", kind: .person, flag: 0x803, chatRoomNotify: 0)
        XCTAssertTrue(pinnedPerson.isPinned)
        XCTAssertFalse(pinnedPerson.isMuted)

        let normalGroup = Contact(username: "1@chatroom", remark: "", nick: "G1", alias: "", kind: .group, flag: 0x2, chatRoomNotify: 1)
        XCTAssertFalse(normalGroup.isMuted)
        XCTAssertFalse(normalGroup.isFolded)

        let mutedGroup = Contact(username: "2@chatroom", remark: "", nick: "G2", alias: "", kind: .group, flag: 0x2, chatRoomNotify: 0)
        XCTAssertTrue(mutedGroup.isMuted)
        XCTAssertFalse(mutedGroup.isFolded)

        let foldedGroup = Contact(username: "3@chatroom", remark: "", nick: "G3", alias: "", kind: .group, flag: 0x1000_0002, chatRoomNotify: 0)
        XCTAssertTrue(foldedGroup.isMuted)
        XCTAssertTrue(foldedGroup.isFolded)
    }

    func testMenuBarChatsFilterAndSchemaMigration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lens-menubar-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + s) } }

        // Simulate a legacy DB lacking `contacts.flag` and `contacts.chat_room_notify`, with cached `sig:contact`.
        do {
            let legacy = try SQLiteDB(path: url.path, readonly: false)
            try legacy.exec("""
                CREATE TABLE contacts(username TEXT PRIMARY KEY, remark TEXT, nick TEXT, alias TEXT, kind TEXT);
                CREATE TABLE kv(k TEXT PRIMARY KEY, v TEXT);
                INSERT INTO kv(k, v) VALUES('sig:contact', 'cached-sig');
                """)
        }

        let store = try LensStore(url: url)
        // Migration must have added the new columns and cleared `sig:contact`.
        XCTAssertNil(store.kv("sig:contact"))

        let contacts: [Contact] = [
            Contact(username: "wxid_ok", remark: "正常好友", nick: "", alias: "", kind: .person, flag: 0x3, chatRoomNotify: 0),
            Contact(username: "wxid_muted", remark: "免打扰好友", nick: "", alias: "", kind: .person, flag: 0x203, chatRoomNotify: 0),
            Contact(username: "wxid_hidden", remark: "隐藏会话", nick: "", alias: "", kind: .person, flag: 0x3, chatRoomNotify: 0),
            Contact(username: "g_ok@chatroom", remark: "", nick: "普通群", alias: "", kind: .group, flag: 0x2, chatRoomNotify: 1),
            Contact(username: "g_muted@chatroom", remark: "", nick: "免打扰群", alias: "", kind: .group, flag: 0x2, chatRoomNotify: 0),
            Contact(username: "g_folded@chatroom", remark: "", nick: "折叠群", alias: "", kind: .group, flag: 0x1000_0002, chatRoomNotify: 0),
            Contact(username: "gh_123", remark: "", nick: "公众号", alias: "", kind: .official, flag: 0x3, chatRoomNotify: 0),
            Contact(username: "@placeholder_foldgroup", remark: "", nick: "折叠的群聊", alias: "", kind: .system, flag: 0x2, chatRoomNotify: 1),
        ]
        try store.replaceContacts(contacts, selfUsername: "wxid_me")

        let now = Int64(Date().timeIntervalSince1970)
        try store.replaceSessions([
            SessionInfo(username: "wxid_ok", summary: "hi", lastTimestamp: now - 10, unread: 2, hidden: false),
            SessionInfo(username: "wxid_hidden", summary: "hid", lastTimestamp: now - 5, unread: 1, hidden: true),
            SessionInfo(username: "g_ok@chatroom", summary: "hi", lastTimestamp: now - 20, unread: 1, hidden: false),
        ])

        for (idx, c) in contacts.enumerated() {
            let row = LensStore.IndexRow(
                src: "message/message_0.db", tbl: c.username, localID: Int64(idx + 1), serverID: 0,
                chat: c.username, sender: c.username, isSelf: false, ts: now - Int64(idx),
                decoded: DecodedMessage(sender: nil, baseType: 1, subType: 0, kind: "文本", text: "msg \(idx)", quote: nil),
                sentiment: nil
            )
            try store.ingest([row], src: "message/message_0.db", tbl: c.username, watermark: Int64(idx + 1))
        }
        try store.refreshChatStats()

        let menu = store.menuBarChats()
        XCTAssertEqual(menu.map(\.username), ["wxid_ok", "g_ok@chatroom"])

        // An older eligible chat with unread > 0 must sort ahead of a newer read chat,
        // while muted/folded/hidden chats with unread > 0 remain excluded.
        try store.replaceSessions([
            SessionInfo(username: "wxid_ok", summary: "ok", lastTimestamp: now, unread: 0, hidden: false),
            SessionInfo(username: "g_ok@chatroom", summary: "g", lastTimestamp: now - 20, unread: 3, hidden: false),
            SessionInfo(username: "wxid_muted", summary: "m", lastTimestamp: now, unread: 9, hidden: false),
            SessionInfo(username: "g_folded@chatroom", summary: "f", lastTimestamp: now, unread: 99, hidden: false),
            SessionInfo(username: "wxid_hidden", summary: "h", lastTimestamp: now, unread: 5, hidden: true),
        ])
        let prioritized = store.menuBarChats(limit: 1)
        XCTAssertEqual(prioritized.map(\.username), ["g_ok@chatroom"])
    }
}

final class AnalyticsTests: XCTestCase {
    func testPeriodStatsAndHeatmapSlot() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lens-analytics-\(UUID().uuidString).sqlite")
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + s) } }

        let store = try LensStore(url: url)
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let todayTs = Int64(todayStart.addingTimeInterval(10 * 3600 + 300).timeIntervalSince1970)
        let oldTs = Int64(cal.date(byAdding: .day, value: -10, to: todayStart)!.addingTimeInterval(15 * 3600 + 60).timeIntervalSince1970)

        let rows: [LensStore.IndexRow] = [
            LensStore.IndexRow(
                src: "message/message_0.db", tbl: "a", localID: 1, serverID: 0,
                chat: "wxid_a", sender: "wxid_a", isSelf: false, ts: todayTs,
                decoded: DecodedMessage(sender: nil, baseType: 1, subType: 0, kind: "文本", text: "今天早上的消息", quote: nil),
                sentiment: 0.2
            ),
            LensStore.IndexRow(
                src: "message/message_0.db", tbl: "a", localID: 2, serverID: 0,
                chat: "wxid_a", sender: "wxid_me", isSelf: true, ts: todayTs + 10,
                decoded: DecodedMessage(sender: nil, baseType: 1, subType: 0, kind: "文本", text: "我回复一下", quote: nil),
                sentiment: 0.3
            ),
            LensStore.IndexRow(
                src: "message/message_0.db", tbl: "b", localID: 3, serverID: 0,
                chat: "wxid_b", sender: "wxid_b", isSelf: false, ts: oldTs,
                decoded: DecodedMessage(sender: nil, baseType: 1, subType: 0, kind: "文本", text: "十天前下午的消息", quote: nil),
                sentiment: 0.0
            ),
        ]
        try store.ingest(rows, src: "message/message_0.db", tbl: "a", watermark: 3)

        let todayStats = store.periodStats(days: 1)
        XCTAssertEqual(todayStats.total, 2)
        XCTAssertEqual(todayStats.sentByMe, 1)
        XCTAssertEqual(todayStats.activeChats, 1)

        let allStats = store.periodStats(days: nil)
        XCTAssertEqual(allStats.total, 3)
        XCTAssertEqual(allStats.sentByMe, 1)
        XCTAssertEqual(allStats.activeChats, 2)

        // Monday-first weekday index for todayTs
        let appleW = cal.component(.weekday, from: Date(timeIntervalSince1970: TimeInterval(todayTs))) // 1=Sun...7=Sat
        let monFirstW = (appleW + 5) % 7
        let heat = store.heatmap()
        let cell = heat.first { $0.weekday == monFirstW && $0.hour == 10 }
        XCTAssertEqual(cell?.count, 2)

        let slot = store.heatmapSlot(weekday: monFirstW, hour: 10)
        XCTAssertEqual(slot.total, 2)
        XCTAssertEqual(slot.topChats.first?.chat, "wxid_a")
        XCTAssertEqual(slot.messages.count, 2)
    }
}
