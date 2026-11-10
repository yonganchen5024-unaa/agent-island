import Foundation
import Combine

/// One quota window. Percent is what is left, which is the question the island answers.
struct UsageWindow: Equatable {
    let label: String
    let remainingPercent: Int
    let resetsAt: Date?
}

struct AgentUsage: Equatable, Identifiable {
    let id: String
    let name: String
    var windows: [UsageWindow] = []
    var problem: String? = nil
    var updatedAt: Date? = nil
}

/// Pure parsers for each provider's reply. Internal so that tests can feed them fictional replies.
enum UsageParsing {
    static func date(_ value: Any?) -> Date? {
        if let seconds = (value as? NSNumber)?.doubleValue { return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds) }
        if let text = value as? String {
            let plain = ISO8601DateFormatter()
            if let parsed = plain.date(from: text) { return parsed }
            let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: text)
        }
        return nil
    }
    static func remaining(used: Double) -> Int { Int(max(0, min(100, 100 - used)).rounded()) }

    /// Claude's get_usage: rate_limits.five_hour / seven_day, each with utilization and resets_at.
    static func claude(_ reply: [String: Any]) -> [UsageWindow] {
        guard let limits = reply["rate_limits"] as? [String: Any] else { return [] }
        var windows: [UsageWindow] = []
        for (key, label) in [("five_hour", "5H"), ("seven_day", "7D")] {
            guard let window = limits[key] as? [String: Any], let used = (window["utilization"] as? NSNumber)?.doubleValue ?? (window["used_percentage"] as? NSNumber)?.doubleValue else { continue }
            windows.append(UsageWindow(label: label, remainingPercent: remaining(used: used), resetsAt: date(window["resets_at"])))
        }
        return windows
    }

    /// Codex's account/rateLimits/read: primary and secondary windows, named by their duration.
    static func codex(_ result: [String: Any]) -> [UsageWindow] {
        let byID = result["rateLimitsByLimitId"] as? [String: Any]
        guard let limits = (byID?["codex"] as? [String: Any]) ?? (result["rateLimits"] as? [String: Any]) else { return [] }
        return ["primary", "secondary"].compactMap { key in
            guard let window = limits[key] as? [String: Any], let used = (window["usedPercent"] as? NSNumber)?.doubleValue else { return nil }
            let minutes = (window["windowDurationMins"] as? NSNumber)?.intValue
            return UsageWindow(label: durationLabel(minutes: minutes, fallback: key == "primary" ? "5H" : "7D"), remainingPercent: remaining(used: used), resetsAt: date(window["resetsAt"]))
        }
    }

    /// Kimi's /coding/v1/usages: limits[] with a window and its counts, plus an overall usage block.
    static func kimi(_ reply: [String: Any]) -> [UsageWindow] {
        func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init) }
        func percent(_ block: [String: Any]) -> Int? {
            guard let limit = number(block["limit"]), limit > 0 else { return nil }
            if let left = number(block["remaining"]) { return Int((left / limit * 100).rounded()) }
            if let used = number(block["used"]) { return remaining(used: used / limit * 100) }
            return nil
        }
        var windows: [UsageWindow] = []
        for item in reply["limits"] as? [[String: Any]] ?? [] {
            let detail = item["detail"] as? [String: Any] ?? item
            guard let left = percent(detail) else { continue }
            let window = item["window"] as? [String: Any]
            var minutes = (window?["duration"] as? NSNumber)?.intValue
            if let unit = window?["timeUnit"] as? String, let value = minutes {
                if unit.contains("HOUR") { minutes = value * 60 } else if unit.contains("DAY") { minutes = value * 1440 } else if unit.contains("SECOND") { minutes = value / 60 }
            }
            windows.append(UsageWindow(label: durationLabel(minutes: minutes, fallback: "限额"), remainingPercent: left, resetsAt: date(detail["resetTime"] ?? detail["reset_at"])))
        }
        if let overall = reply["usage"] as? [String: Any], let left = percent(overall) {
            windows.append(UsageWindow(label: "7D", remainingPercent: left, resetsAt: date(overall["resetTime"] ?? overall["reset_at"])))
        }
        return windows
    }

    static func durationLabel(minutes: Int?, fallback: String) -> String {
        guard let minutes, minutes > 0 else { return fallback }
        if minutes % 1440 == 0 { return "\(minutes / 1440)D" }
        if minutes % 60 == 0 { return "\(minutes / 60)H" }
        return "\(minutes)M"
    }
}

/// Reads each agent's quota the way that agent itself exposes it. Claude and Codex are asked through
/// their own CLI, so this code never touches their credentials. Nothing here retries in a tight loop
/// or writes a token anywhere.
@MainActor final class AgentUsageReader: ObservableObject {
    @Published private(set) var usages: [AgentUsage] = []
    private var task: Task<Void, Never>?
    private var lastRefresh: Date?
    private let debugLog: URL?
    static let interval: UInt64 = 300_000_000_000

    init(debugLog: URL? = nil) { self.debugLog = debugLog }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(nanoseconds: Self.interval) } catch { break }
            }
        }
    }
    func stop() { task?.cancel(); task = nil }

    /// For the moment the panel opens, without hammering anything.
    func refreshIfStale() {
        guard let lastRefresh, Date().timeIntervalSince(lastRefresh) > 60 else { return }
        Task { await refresh() }
    }

    private func refresh() async {
        lastRefresh = Date()
        async let claude = Task.detached(priority: .utility) { UsageProbes.claude() }.value
        async let codex = Task.detached(priority: .utility) { UsageProbes.codex() }.value
        async let kimi = Task.detached(priority: .utility) { await UsageProbes.kimi() }.value
        let results = await [claude, codex, kimi]
        // A failed read keeps the last good numbers visible rather than blanking them.
        usages = results.compactMap { result -> AgentUsage? in
            guard let result else { return nil }
            if result.windows.isEmpty, let old = usages.first(where: { $0.id == result.id }), !old.windows.isEmpty { return old }
            return result
        }
        writeDebug(results.compactMap { $0 })
    }

    private func writeDebug(_ results: [AgentUsage]) {
        guard let debugLog else { return }
        let manager = FileManager.default
        if let size = (try? manager.attributesOfItem(atPath: debugLog.path))?[.size] as? Int, size > 262_144 { try? manager.removeItem(at: debugLog) }
        if !manager.fileExists(atPath: debugLog.path) { manager.createFile(atPath: debugLog.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let record: [String: Any] = ["time": Date().timeIntervalSince1970, "results": results.map { usage in
            ["agent": usage.id, "problem": usage.problem as Any, "windows": usage.windows.map { "\($0.label)=\($0.remainingPercent)" }] as [String: Any]
        }]
        guard var line = try? JSONSerialization.data(withJSONObject: record), let handle = try? FileHandle(forWritingTo: debugLog) else { return }
        line.append(10)
        _ = try? handle.seekToEnd(); try? handle.write(contentsOf: line); try? handle.close()
    }
}

/// Claude processes started only to read usage, by this app or by Agent HUD. `disableAllHooks` in
/// --settings does not switch off managed hooks (measured on 2.1.318), so each probe still sends
/// SessionStart and SessionEnd. Those are not conversations: no row, no sound, no push.
/// Never used to filter approval requests.
enum ClaudeProbeSessions {
    static let entrypoints: Set<String> = ["agent-island", "agent-hud"]
    private static let lock = NSLock()
    private static var probes: [String: Date] = [:]
    private static var conversations: [String: Date] = [:]
    static var registry = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions", isDirectory: true)

    static func mark(_ id: String) { remember(id.lowercased(), probe: true) }

    /// Known probe IDs first; otherwise Claude's own registry entry for that session decides.
    /// A session with no entry yet is treated as a conversation and asked about again next time.
    static func isProbe(_ id: String) -> Bool {
        let key = id.lowercased()
        lock.lock()
        if probes[key] != nil { lock.unlock(); return true }
        if conversations[key] != nil { lock.unlock(); return false }
        lock.unlock()
        guard let entrypoint = registryEntrypoint(of: key) else { return false }
        let probe = entrypoints.contains(entrypoint)
        remember(key, probe: probe)
        return probe
    }

    private static func remember(_ key: String, probe: Bool) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        probes = probes.filter { now.timeIntervalSince($0.value) < 3600 }
        if conversations.count > 512 { conversations.removeAll() }
        if probe { probes[key] = now } else { conversations[key] = now }
    }

    private static func registryEntrypoint(of key: String) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: registry, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return nil }
        for url in entries.prefix(4096) where url.pathExtension == "json" {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
                  let data = try? Data(contentsOf: url),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (object["sessionId"] as? String)?.lowercased() == key else { continue }
            return object["entrypoint"] as? String ?? ""
        }
        return nil
    }
}

enum UsageProbes {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// Runs a CLI, writes the given lines, and returns the first stdout JSON object `pick` accepts.
    private static func exchange(executable: String, arguments: [String], environment: [String: String] = [:], lines: [String], timeout: TimeInterval, cwd: URL? = nil, pick: @escaping ([String: Any]) -> [String: Any]?) -> (reply: [String: Any]?, problem: String?) {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return (nil, "未安装") }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = home.path + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for (key, value) in environment { env[key] = value }
        process.environment = env
        if let cwd { process.currentDirectoryURL = cwd }
        do { try process.run() } catch { return (nil, "无法启动") }
        for line in lines { try? input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8)) }
        let deadline = Date().addingTimeInterval(timeout)
        let lock = NSLock()
        var found: [String: Any]?
        var buffer = Data()
        let done = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); defer { lock.unlock() }
            if chunk.isEmpty { handle.readabilityHandler = nil; done.signal(); return }
            guard found == nil else { return }
            buffer.append(chunk)
            if buffer.count > 8_388_608 { buffer.removeAll() }
            while let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[buffer.startIndex..<end]); buffer.removeSubrange(buffer.startIndex...end)
                if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let hit = pick(object) { found = hit; done.signal(); return }
            }
        }
        _ = done.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow))
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        lock.lock(); let reply = found; lock.unlock()
        return (reply, reply == nil ? "没有返回" : nil)
    }

    static func claude() -> AgentUsage? {
        // The native installer's location first: if the user wraps the CLI there, the wrapper is what they meant to run.
        let candidates = [".local/bin/claude", ".claude/local/claude", ".npm-global/bin/claude", ".bun/bin/claude"].map { home.appendingPathComponent($0).path }
            + ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        guard let wrapper = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let folder = home.appendingPathComponent("Library/Application Support/Agent Island/usage-probe", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let request = #"{"type":"control_request","request_id":"agent-island-usage","request":{"subtype":"get_usage","skip_behaviors":true}}"#
        // A known ID, so the island can drop the managed hooks' events from this process (see ClaudeProbeSessions).
        let probeID = UUID().uuidString.lowercased()
        ClaudeProbeSessions.mark(probeID)
        let answer = exchange(executable: wrapper, arguments: ["--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--session-id", probeID, "--settings", #"{"disableAllHooks":true}"#],
                              environment: ["CLAUDE_CODE_ENTRYPOINT": "agent-island"], lines: [request], timeout: 40, cwd: folder) { object in
            guard object["type"] as? String == "control_response", let response = object["response"] as? [String: Any] else { return nil }
            return response["response"] as? [String: Any] ?? response
        }
        var usage = AgentUsage(id: "claude", name: "Claude", problem: answer.problem, updatedAt: Date())
        if let reply = answer.reply {
            usage.windows = UsageParsing.claude(reply)
            if usage.windows.isEmpty { usage.problem = "无用量数据" }
        }
        return usage
    }

    static func codex() -> AgentUsage? {
        let candidates = ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "/Applications/Codex.app/Contents/Resources/codex",
                          "/opt/homebrew/bin/codex", "/usr/local/bin/codex"] + [".local/bin/codex", ".npm-global/bin/codex", ".bun/bin/codex"].map { home.appendingPathComponent($0).path }
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let lines = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"agent_island","title":"Agent Island","version":"0.1.0"}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"account/rateLimits/read"}"#,
        ]
        let answer = exchange(executable: binary, arguments: ["app-server", "--listen", "stdio://"], lines: lines, timeout: 25) { object in
            guard (object["id"] as? NSNumber)?.intValue == 2 else { return nil }
            return object["result"] as? [String: Any] ?? ["error": object["error"] as Any]
        }
        var usage = AgentUsage(id: "codex", name: "Codex", problem: answer.problem, updatedAt: Date())
        if let reply = answer.reply {
            usage.windows = UsageParsing.codex(reply)
            if usage.windows.isEmpty { usage.problem = "无用量数据" }
        }
        return usage
    }

    /// Uses the login Kimi Code already keeps. It reads the token only to make this one request, and
    /// never refreshes it, because rotating a token here could log the CLI out.
    static func kimi() async -> AgentUsage? {
        let file = home.appendingPathComponent(".kimi-code/credentials/kimi-code.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        var usage = AgentUsage(id: "kimi", name: "Kimi", updatedAt: Date())
        guard let data = try? Data(contentsOf: file), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let token = (object["access_token"] as? String) ?? (object["accessToken"] as? String) else { usage.problem = "未登录"; return usage }
        var request = URLRequest(url: URL(string: "https://api.kimi.ai/coding/v1/usages")!, timeoutInterval: 20)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        guard let (body, response) = try? await URLSession(configuration: .ephemeral).data(for: request), let http = response as? HTTPURLResponse else { usage.problem = "网络错误"; return usage }
        guard http.statusCode == 200 else { usage.problem = http.statusCode == 401 ? "登录已过期，请打开一次 Kimi" : "HTTP \(http.statusCode)"; return usage }
        guard let reply = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { usage.problem = "格式未知"; return usage }
        usage.windows = UsageParsing.kimi(reply)
        if usage.windows.isEmpty { usage.problem = "格式未知" }
        return usage
    }
}
