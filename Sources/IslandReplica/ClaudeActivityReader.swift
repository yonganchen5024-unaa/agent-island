import Foundation

/// What a live Claude session is doing, read from the tail of its local transcript. It stays in memory
/// for display and is never written or sent anywhere. Parsing only looks at tool calls, the plan and
/// the last prompt; assistant text and tool output are skipped.
enum ClaudeActivityParser {
    struct Parsed: Equatable {
        var task: String?
        var step: String?
        var todos: [SessionTodo] = []
        var openAgents: Set<String> = []
    }

    static func parse(_ data: Data, startsMidFile: Bool) -> Parsed {
        var parsed = Parsed()
        var open: [(id: String, name: String, input: [String: Any])] = []
        var lines = data.split(separator: 10, omittingEmptySubsequences: true)
        if startsMidFile, !lines.isEmpty { lines.removeFirst() }
        for line in lines {
            guard let record = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], let type = record["type"] as? String else { continue }
            if record["isSidechain"] as? Bool == true { continue }
            if type == "last-prompt", let prompt = record["lastPrompt"] as? String { parsed.task = clip(prompt); continue }
            guard type == "assistant" || type == "user", let message = record["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks {
                switch block["type"] as? String {
                case "tool_use":
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                    let input = block["input"] as? [String: Any] ?? [:]
                    open.append((id, name, input))
                    if name == "TodoWrite", let todos = input["todos"] as? [[String: Any]] { parsed.todos = todos.compactMap(todo) }
                case "tool_result":
                    if let id = block["tool_use_id"] as? String { open.removeAll { $0.id == id } }
                default: break
                }
            }
        }
        // Long-running subagent launches stay open, so the step is the newest call that is not one.
        parsed.openAgents = Set(open.filter { $0.name == "Agent" || $0.name == "Task" }.map(\.id))
        if let last = open.last(where: { $0.name != "TodoWrite" }) { parsed.step = describe(tool: last.name, input: last.input) }
        return parsed
    }

    private static func todo(_ value: [String: Any]) -> SessionTodo? {
        guard let content = value["content"] as? String else { return nil }
        let state = value["status"] as? String ?? "pending"
        let active = value["activeForm"] as? String
        return SessionTodo(text: clip(state == "in_progress" ? (active ?? content) : content), state: state)
    }

    static func describe(tool: String, input: [String: Any]) -> String {
        func file() -> String { ((input["file_path"] as? String) ?? (input["notebook_path"] as? String)).map { ($0 as NSString).lastPathComponent } ?? "" }
        let text: String
        switch tool {
        case "Bash":
            let command = (input["command"] as? String)?.split(separator: "\n").first.map(String.init)
            text = "运行 " + ((input["description"] as? String) ?? command ?? "命令")
        case "Read": text = "读取 " + file()
        case "Write": text = "写入 " + file()
        case "Edit", "MultiEdit", "NotebookEdit": text = "编辑 " + file()
        case "Grep", "Glob": text = "搜索 " + ((input["pattern"] as? String) ?? "")
        case "WebFetch": text = "打开 " + ((input["url"] as? String) ?? "网页")
        case "WebSearch": text = "搜索 " + ((input["query"] as? String) ?? "网页")
        case "Agent", "Task": text = "启动子 Agent：" + ((input["description"] as? String) ?? "")
        case "AskUserQuestion": text = "提问"
        case "ExitPlanMode": text = "提交计划"
        default: text = "使用 " + tool
        }
        return clip(text)
    }

    static func clip(_ value: String, limit: Int = 90) -> String {
        let flat = value.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}

/// Reads activity for the running sessions. Only files that changed are read again, and only their tail.
actor ClaudeActivityScanner {
    private struct Cached { let modified: Date; let size: UInt64; let parsed: ClaudeActivityParser.Parsed }
    private let projects: URL
    private var paths: [String: URL] = [:]
    private var cache: [String: Cached] = [:]
    private let tail: UInt64 = 1_572_864
    static let subagentRunningWindow: TimeInterval = 45
    static let subagentKeepWindow: TimeInterval = 600

    init(projects: URL) { self.projects = projects }

    func scan(_ sessions: [ClaudeLiveSession]) -> [String: SessionActivity] {
        var result: [String: SessionActivity] = [:]
        for session in sessions {
            guard let url = transcript(for: session) else { continue }
            var activity = SessionActivity()
            if let parsed = parsed(url, id: session.sessionID) {
                activity.task = parsed.task; activity.step = parsed.step; activity.todos = parsed.todos
            }
            activity.subagents = subagents(of: url)
            result[session.sessionID] = activity
        }
        let live = Set(sessions.map(\.sessionID))
        cache = cache.filter { live.contains($0.key) }
        paths = paths.filter { live.contains($0.key) }
        return result
    }

    private func transcript(for session: ClaudeLiveSession) -> URL? {
        if let known = paths[session.sessionID], FileManager.default.fileExists(atPath: known.path) { return known }
        let name = session.sessionID + ".jsonl"
        guard let folders = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        for folder in folders.prefix(5000) {
            let candidate = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { paths[session.sessionID] = candidate; return candidate }
        }
        return nil
    }

    private func parsed(_ url: URL, id: String) -> ClaudeActivityParser.Parsed? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = values.contentModificationDate, let size = values.fileSize.map(UInt64.init) else { return nil }
        if let old = cache[id], old.modified == modified, old.size == size { return old.parsed }
        guard var parsed = readTail(url, size: size) else { return cache[id]?.parsed }
        // The prompt record is not always inside the tail, so an older one stays valid.
        if parsed.task == nil { parsed.task = cache[id]?.parsed.task }
        cache[id] = Cached(modified: modified, size: size, parsed: parsed)
        return parsed
    }

    private func readTail(_ url: URL, size: UInt64) -> ClaudeActivityParser.Parsed? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let offset = size > tail ? size - tail : 0
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.read(upToCount: Int(tail)) else { return nil }
        return ClaudeActivityParser.parse(data, startsMidFile: offset > 0)
    }

    private func subagents(of transcript: URL) -> [SessionSubagent] {
        let folder = transcript.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        let now = Date()
        var found: [(modified: Date, agent: SessionSubagent)] = []
        for file in files.prefix(512) where file.pathExtension == "jsonl" {
            guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  now.timeIntervalSince(modified) < Self.subagentKeepWindow else { continue }
            let meta = file.deletingPathExtension().appendingPathExtension("meta.json")
            let object = (try? Data(contentsOf: meta)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let running = now.timeIntervalSince(modified) < Self.subagentRunningWindow
            var step: String?
            if running, let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(UInt64.init), let handle = try? FileHandle(forReadingFrom: file) {
                let offset = size > 262_144 ? size - 262_144 : 0
                if (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.read(upToCount: 262_144) {
                    step = Self.subagentStep(data, startsMidFile: offset > 0)
                }
                try? handle.close()
            }
            found.append((modified, SessionSubagent(id: file.deletingPathExtension().lastPathComponent, name: object?["agentType"] as? String ?? "子 Agent",
                                                    task: ClaudeActivityParser.clip(object?["description"] as? String ?? ""), step: step, running: running)))
        }
        // Running first, newest first. A subagent's own transcript has every record marked sidechain.
        return found.sorted { ($0.agent.running ? 1 : 0, $0.modified) > ($1.agent.running ? 1 : 0, $1.modified) }.map(\.agent)
    }

    private static func subagentStep(_ data: Data, startsMidFile: Bool) -> String? {
        var lines = data.split(separator: 10, omittingEmptySubsequences: true)
        if startsMidFile, !lines.isEmpty { lines.removeFirst() }
        var last: String?
        for line in lines {
            guard let record = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], record["type"] as? String == "assistant",
                  let message = record["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks where block["type"] as? String == "tool_use" {
                if let name = block["name"] as? String { last = ClaudeActivityParser.describe(tool: name, input: block["input"] as? [String: Any] ?? [:]) }
            }
        }
        return last
    }
}
