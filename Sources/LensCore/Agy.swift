import Foundation

public struct AgyConfig: Sendable, Equatable {
    public var binary: String
    public var model: String
    public var timeout: TimeInterval

    public init(binary: String, model: String, timeout: TimeInterval = 120) {
        self.binary = binary
        self.model = model
        self.timeout = timeout
    }

    public static let defaultModel = "gemini-3.8-flash-low"
}

public struct AgyError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

public struct AgyResult: Sendable {
    public var json: Data
    public var duration: Double?
    public var model: String
}

/// Runs `agy -p` in print mode with a JSON schema. The agent works in an empty directory with the
/// terminal sandbox on, and the prompt tells it not to use tools; chat text is passed as data only.
public actor AgyClient {
    private var running = 0
    private let maxConcurrent: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(maxConcurrent: Int = 2) {
        self.maxConcurrent = maxConcurrent
    }

    public static func resolveBinary(_ configured: String? = nil) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [configured, "\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
        return candidates.compactMap { $0 }.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static var shellPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }

    private func acquire() async {
        if running < maxConcurrent { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }

    public func run(prompt: String, schema: String, config: AgyConfig) async throws -> AgyResult {
        await acquire()
        defer { release() }
        return try await AgyClient.execute(prompt: prompt, schema: schema, config: config)
    }

    /// Lists `agy models` as (id, display name).
    public static func listModels(binary: String) async -> [(String, String)] {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let r = runProcess(binary, ["models"], timeout: 30)
                let models = String(decoding: r.out, as: UTF8.self).split(separator: "\n").compactMap { line -> (String, String)? in
                    let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                    guard parts.count == 2, !parts[0].contains(" ") else { return nil }
                    return (parts[0], parts[1])
                }
                cont.resume(returning: models)
            }
        }
    }

    static func execute(prompt: String, schema: String, config: AgyConfig) async throws -> AgyResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let args = ["-p", prompt, "--model", config.model, "--output-format", "json", "--json-schema", schema,
                            "--disable-slash-commands", "--sandbox", "--project", "ChatMaster",
                            "--print-timeout", "\(Int(config.timeout))s"]
                let r = runProcess(config.binary, args, timeout: config.timeout + 20)
                do {
                    cont.resume(returning: try parse(out: r.out, err: r.err, status: r.status, timedOut: r.timedOut,
                                                     model: config.model))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    struct ProcessOutput { var out: Data; var err: Data; var status: Int32; var timedOut: Bool }

    static func runProcess(_ binary: String, _ args: [String], timeout: TimeInterval) -> ProcessOutput {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        p.currentDirectoryURL = LensPaths.agyWorkspace
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = shellPath
        env["NO_COLOR"] = "1"
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        var out = Data(), err = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { out = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { err = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        do {
            try p.run()
        } catch {
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            group.wait()
            return ProcessOutput(out: Data(), err: Data("无法启动 agy: \(error.localizedDescription)".utf8), status: -1, timedOut: false)
        }
        var timedOut = false
        let killer = DispatchWorkItem { if p.isRunning { timedOut = true; p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        p.waitUntilExit()
        killer.cancel()
        group.wait()
        return ProcessOutput(out: out, err: err, status: p.terminationStatus, timedOut: timedOut)
    }

    static func parse(out: Data, err: Data, status: Int32, timedOut: Bool, model: String) throws -> AgyResult {
        if timedOut { throw AgyError(message: "agy 超时，请稍后重试或换一个更快的模型") }
        let text = String(decoding: out, as: UTF8.self)
        let errText = String(decoding: err, as: UTF8.self)
        guard let start = text.range(of: "{\"")?.lowerBound,
              let obj = try? JSONSerialization.jsonObject(with: Data(text[start...].utf8)) as? [String: Any] else {
            let tail = (errText + "\n" + text).trimmingCharacters(in: .whitespacesAndNewlines).suffix(400)
            let lower = tail.lowercased()
            if lower.contains("login") || lower.contains("auth") || lower.contains("sign in") {
                throw AgyError(message: "agy 未登录：请在终端运行 `agy` 完成登录。\n\(tail)")
            }
            throw AgyError(message: "agy 没有返回结果（退出码 \(status)）：\(tail)")
        }
        let statusText = obj["status"] as? String ?? ""
        let duration = obj["duration_seconds"] as? Double
        if let structured = obj["structured_output"], !(structured is NSNull),
           let data = try? JSONSerialization.data(withJSONObject: structured) {
            return AgyResult(json: data, duration: duration, model: model)
        }
        let response = obj["response"] as? String ?? ""
        if let data = extractLastJSONObject(response) {
            return AgyResult(json: data, duration: duration, model: model)
        }
        throw AgyError(message: "agy 返回状态 \(statusText.isEmpty ? "未知" : statusText)，没有结构化结果：\(response.prefix(300))")
    }

    /// Finds the last balanced top-level `{...}` that parses as JSON.
    static func extractLastJSONObject(_ s: String) -> Data? {
        let chars = Array(s)
        var end = chars.count - 1
        while end >= 0 {
            guard let close = (0...end).reversed().first(where: { chars[$0] == "}" }) else { return nil }
            var depth = 0
            var inString = false
            var i = close
            while i >= 0 {
                let c = chars[i]
                if c == "\"" && (i == 0 || chars[i - 1] != "\\") { inString.toggle() }
                if !inString {
                    if c == "}" { depth += 1 }
                    if c == "{" {
                        depth -= 1
                        if depth == 0 {
                            let candidate = Data(String(chars[i...close]).utf8)
                            if (try? JSONSerialization.jsonObject(with: candidate)) is [String: Any] { return candidate }
                            break
                        }
                    }
                }
                i -= 1
            }
            end = close - 1
        }
        return nil
    }
}
