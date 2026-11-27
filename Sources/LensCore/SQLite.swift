import CLensNative
import Foundation

public enum SQLValue: Sendable {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null
}

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public var description: String { message }
}

/// Thin wrapper around the statically linked SQLCipher build. One instance = one connection,
/// serialized by an internal lock so it can be shared between threads.
public final class SQLiteDB: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let path: String

    public init(path: String, readonly: Bool, hexKey: String? = nil) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = readonly
            ? (SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX)
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            if let db { sqlite3_close_v2(db) }
            throw SQLiteError(message: "open \(path): \(msg)")
        }
        handle = db
        sqlite3_busy_timeout(db, 3000)
        if let hexKey {
            try exec("PRAGMA key = \"x'\(hexKey)'\";")
            // Touch the schema so a wrong key fails here instead of on first use.
            _ = try scalarInt("SELECT count(*) FROM sqlite_master")
        }
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    private var errmsg: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed" }

    public func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errmsg
            sqlite3_free(err)
            throw SQLiteError(message: "\(msg) — \(sql.prefix(120))")
        }
    }

    public func query(_ sql: String, _ params: [SQLValue] = [], _ body: (SQLRow) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &st, nil) == SQLITE_OK, let st else {
            throw SQLiteError(message: "prepare: \(errmsg) — \(sql.prefix(160))")
        }
        defer { sqlite3_finalize(st) }
        try bind(st, params)
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW {
                try body(SQLRow(st: st))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw SQLiteError(message: "step: \(errmsg) — \(sql.prefix(160))")
            }
        }
    }

    @discardableResult
    public func run(_ sql: String, _ params: [SQLValue] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &st, nil) == SQLITE_OK, let st else {
            throw SQLiteError(message: "prepare: \(errmsg) — \(sql.prefix(160))")
        }
        defer { sqlite3_finalize(st) }
        try bind(st, params)
        let rc = sqlite3_step(st)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError(message: "step: \(errmsg) — \(sql.prefix(160))")
        }
        return Int(sqlite3_changes(handle))
    }

    public func scalarInt(_ sql: String, _ params: [SQLValue] = []) throws -> Int64? {
        var v: Int64?
        try query(sql, params) { row in v = row.isNull(0) ? nil : row.int(0) }
        return v
    }

    public func scalarText(_ sql: String, _ params: [SQLValue] = []) throws -> String? {
        var v: String?
        try query(sql, params) { row in v = row.text(0) }
        return v
    }

    public var lastInsertRowID: Int64 {
        lock.lock(); defer { lock.unlock() }
        return sqlite3_last_insert_rowid(handle)
    }

    /// Runs `body` inside BEGIN IMMEDIATE / COMMIT, rolling back on error.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE")
        do {
            let v = try body()
            try exec("COMMIT")
            return v
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func bind(_ st: OpaquePointer, _ params: [SQLValue]) throws {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch p {
            case .int(let v): rc = sqlite3_bind_int64(st, idx, v)
            case .double(let v): rc = sqlite3_bind_double(st, idx, v)
            case .text(let v): rc = lens_bind_text(st, idx, v)
            case .blob(let v):
                rc = v.withUnsafeBytes { lens_bind_blob(st, idx, $0.baseAddress, Int32(v.count)) }
            case .null: rc = sqlite3_bind_null(st, idx)
            }
            if rc != SQLITE_OK { throw SQLiteError(message: "bind \(i): \(errmsg)") }
        }
    }
}

public struct SQLRow {
    let st: OpaquePointer

    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(st, i) == SQLITE_NULL }
    public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(st, i) }
    public func double(_ i: Int32) -> Double { sqlite3_column_double(st, i) }
    public func isBlob(_ i: Int32) -> Bool { sqlite3_column_type(st, i) == SQLITE_BLOB }

    public func text(_ i: Int32) -> String? {
        guard let p = sqlite3_column_text(st, i) else { return nil }
        let n = Int(sqlite3_column_bytes(st, i))
        return String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)
    }

    public func blob(_ i: Int32) -> Data? {
        let n = Int(sqlite3_column_bytes(st, i))
        guard let p = sqlite3_column_blob(st, i) else { return n == 0 && !isNull(i) ? Data() : nil }
        return Data(bytes: p, count: n)
    }
}

public enum Zstd {
    public static let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    public static func isCompressed(_ data: Data) -> Bool {
        data.count >= 4 && Array(data.prefix(4)) == magic
    }

    public static func decompress(_ data: Data) -> Data? {
        data.withUnsafeBytes { raw -> Data? in
            var outLen = 0
            guard let p = lens_zstd_decompress(raw.baseAddress, raw.count, &outLen) else { return nil }
            defer { lens_free(p) }
            return Data(bytes: p, count: outLen)
        }
    }
}
