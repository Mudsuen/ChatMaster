import Foundation

public enum LensPaths {
    /// User-supplied directory containing `all_keys.json` for already-decrypted local databases.
    public static var decryptHome: URL {
        if let env = ProcessInfo.processInfo.environment["WXDEC_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".wechat-decrypt")
    }

    public static var keysFile: URL { decryptHome.appendingPathComponent("all_keys.json") }

    /// Private app data (index with plaintext chat history, analysis cache). Kept at 700.
    /// Automatically migrates data from the legacy `WeChatLens` directory on first launch.
    public static var appSupport: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ChatMaster", isDirectory: true)
        let legacy = base.appendingPathComponent("WeChatLens", isDirectory: true)
        if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacy.path) {
            try? fm.moveItem(at: legacy, to: dir)
        }
        ensurePrivateDir(dir)
        return dir
    }

    public static var indexDB: URL { appSupport.appendingPathComponent("lens.sqlite") }

    /// Empty working directory for agy so the agent has no files to look at.
    public static var agyWorkspace: URL {
        let dir = appSupport.appendingPathComponent("agy-workspace", isDirectory: true)
        ensurePrivateDir(dir)
        return dir
    }

    public static func ensurePrivateDir(_ url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    public static func makePrivate(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
