import CryptoKit
import Foundation

public struct KeyFile: Sendable {
    public let dbDir: String
    public let keys: [String: String]

    public static func load(from url: URL = LensPaths.keysFile) throws -> KeyFile {
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SQLiteError(message: "all_keys.json 格式不对")
        }
        var keys: [String: String] = [:]
        for (k, v) in obj where !k.hasPrefix("_") {
            if let d = v as? [String: Any], let key = d["enc_key"] as? String, key.count == 64 { keys[k] = key }
        }
        guard let dir = obj["_db_dir"] as? String else { throw SQLiteError(message: "all_keys.json 缺少 _db_dir") }
        return KeyFile(dbDir: dir, keys: keys)
    }
}

/// Read-only access to the live (encrypted, WAL) WeChat databases.
public final class WeChatSource: @unchecked Sendable {
    public let keyFile: KeyFile
    public let selfUsername: String
    private var connections: [String: SQLiteDB] = [:]
    private let lock = NSLock()

    public init(keyFile: KeyFile? = nil) throws {
        let kf = try keyFile ?? KeyFile.load()
        self.keyFile = kf
        self.selfUsername = WeChatSource.selfUsername(fromDBDir: kf.dbDir)
    }

    /// `.../xwechat_files/wxid_abc_f3eb/db_storage` -> `wxid_abc`.
    public static func selfUsername(fromDBDir dir: String) -> String {
        let folder = URL(fileURLWithPath: dir).deletingLastPathComponent().lastPathComponent
        if let r = folder.range(of: "_[0-9a-f]{4}$", options: .regularExpression) {
            return String(folder[folder.startIndex..<r.lowerBound])
        }
        return folder
    }

    public var messageDBs: [String] {
        keyFile.keys.keys.filter {
            $0.range(of: #"^message/(biz_)?message_\d+\.db$"#, options: .regularExpression) != nil
        }.sorted { a, b in
            // newest slices last so live data wins ties
            let na = Int(a.filter(\.isNumber)) ?? 0, nb = Int(b.filter(\.isNumber)) ?? 0
            let ba = a.contains("biz") ? 1 : 0, bb = b.contains("biz") ? 1 : 0
            return (ba, na) < (bb, nb)
        }
    }

    /// Live databases present on disk without a verified key (e.g. a new yearly message slice).
    public var missingKeyDBs: [String] {
        let root = URL(fileURLWithPath: keyFile.dbDir)
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [String] = []
        for case let url as URL in en where url.pathExtension == "db" {
            let rel = String(url.path.dropFirst(root.path.count + 1))
            if keyFile.keys[rel] == nil, rel.hasPrefix("message/message_") || rel.hasPrefix("message/biz_message_"),
               rel.range(of: #"^message/(biz_)?message_\d+\.db$"#, options: .regularExpression) != nil {
                out.append(rel)
            }
        }
        return out.sorted()
    }

    public func path(_ rel: String) -> String { (keyFile.dbDir as NSString).appendingPathComponent(rel) }

    public func connection(_ rel: String) throws -> SQLiteDB {
        lock.lock(); defer { lock.unlock() }
        if let c = connections[rel] { return c }
        guard let key = keyFile.keys[rel] else { throw SQLiteError(message: "没有 \(rel) 的密钥") }
        let c = try SQLiteDB(path: path(rel), readonly: true, hexKey: key)
        connections[rel] = c
        return c
    }

    public func dropConnection(_ rel: String) {
        lock.lock(); connections[rel] = nil; lock.unlock()
    }

    /// Changes whenever the database or its write-ahead log receives data.
    public func signature(_ rel: String) -> String {
        let fm = FileManager.default
        func info(_ p: String) -> String {
            guard let a = try? fm.attributesOfItem(atPath: p) else { return "-" }
            let m = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let s = (a[.size] as? NSNumber)?.int64Value ?? 0
            return "\(Int64(m * 1000)):\(s)"
        }
        let p = path(rel)
        return info(p) + "|" + info(p + "-wal")
    }

    public func loadContacts() throws -> [Contact] {
        let db = try connection("contact/contact.db")
        var out: [Contact] = []
        try db.query("""
            SELECT username, IFNULL(remark,''), IFNULL(nick_name,''), IFNULL(alias,''),
                   IFNULL(flag,0), IFNULL(chat_room_notify,1)
            FROM contact
            """) { r in
            let u = r.text(0) ?? ""
            guard !u.isEmpty else { return }
            out.append(Contact(username: u, remark: r.text(1) ?? "", nick: r.text(2) ?? "", alias: r.text(3) ?? "",
                               kind: Contact.kind(of: u), flag: r.int(4), chatRoomNotify: Int(r.int(5))))
        }
        return out
    }

    public func loadSessions() throws -> [SessionInfo] {
        let db = try connection("session/session.db")
        var out: [SessionInfo] = []
        try db.query("""
            SELECT username, IFNULL(summary,''), IFNULL(last_timestamp,0), IFNULL(unread_count,0), IFNULL(is_hidden,0),
                   IFNULL(last_clear_unread_timestamp,0)
            FROM SessionTable
            """) { r in
            out.append(SessionInfo(username: r.text(0) ?? "", summary: r.text(1) ?? "", lastTimestamp: r.int(2),
                                   unread: Int(r.int(3)), hidden: r.int(4) != 0, lastClearUnread: r.int(5)))
        }
        return out
    }

    public func avatar(for username: String) -> Data? {
        guard let db = try? connection("head_image/head_image.db") else { return nil }
        var data: Data?
        try? db.query("SELECT image_buffer FROM head_image WHERE username = ?", [.text(username)]) { r in data = r.blob(0) }
        return data
    }

    public static func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
