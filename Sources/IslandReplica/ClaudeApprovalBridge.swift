import Foundation
import Combine

func agentDisplayName(_ source: String) -> String {
    switch source {
    case "claude": return "Claude Code"
    case "codex": return "Codex"
    case "kimi": return "Kimi"
    case "opencode": return "OpenCode"
    case "dsh": return "DSH"
    case "gemini": return "Gemini"
    default: return source
    }
}

/// One question inside an AskUserQuestion request.
struct ClaudeApprovalQuestion: Equatable {
    struct Option: Equatable { let label: String; let detail: String }
    let question: String
    let header: String
    let options: [Option]
    let multiSelect: Bool
}

/// A rule Claude itself suggested, which the user may explicitly adopt with "始终允许".
struct ClaudeApprovalSuggestion: Equatable {
    let index: Int
    let label: String
}

/// One pending request. Tool input is retained in memory only, until the request ends.
struct ClaudeApprovalRequest: Identifiable, Equatable {
    let id: String
    let source: String
    let sessionID: String
    let toolName: String
    /// The complete input, exactly as the hook received it, pretty-printed by the broker.
    let toolInputText: String
    let command: String?
    let filePath: String?
    let summary: String?
    let cwd: String
    let agentType: String?
    let isSubagent: Bool
    let permissionMode: String?
    let questions: [ClaudeApprovalQuestion]
    let suggestions: [ClaudeApprovalSuggestion]
    /// The island's own reading of what a shell script deletes. Display only.
    let hint: ClaudeApprovalHint?
    var isSubmitting = false

    var isQuestion: Bool { toolName == "AskUserQuestion" && !questions.isEmpty }
    /// Claude ignores a plain hook "allow" for this tool, so offering the button would lie.
    /// Measured on 2.1.316: the native dialog simply stays open.
    var allowIsIgnoredByClaude: Bool { toolName == "ExitPlanMode" || (toolName == "AskUserQuestion" && questions.isEmpty) }
    var projectName: String { cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent }
    var agentName: String { agentDisplayName(source) }
}

/// What the island may truthfully say about a request after it stops being pending.
struct ClaudeApprovalOutcome: Identifiable, Equatable {
    enum Kind { case success, info, warning }
    let id = UUID()
    let text: String
    let kind: Kind
}

/// One agent lifecycle event from the broker: identifiers only, never tool input or output.
struct ClaudeApprovalLifecycle {
    let source: String
    let name: String
    let sessionID: String
    let cwd: String?
    let isSubagent: Bool
    let notification: String?
    var toolName: String? = nil
    /// The agent's process, from adapters whose agent has no session registry.
    var pid: Int32? = nil
}

/// Runs the approval broker. It never installs hooks and never decides on its own: a decision
/// only ever comes from `decide` or `answer`, which the card's buttons call.
@MainActor
final class ClaudeApprovalBridge: ObservableObject {
    enum State: Equatable { case stopped, starting, ready, failed(String) }
    struct Endpoint: Equatable { let socket: String; let secretFile: String }
    @Published private(set) var state: State = .stopped
    @Published private(set) var endpoint: Endpoint?
    @Published private(set) var pending: [ClaudeApprovalRequest] = []
    @Published private(set) var lastOutcome: ClaudeApprovalOutcome?

    /// A new request arrived.
    var onRequest: ((ClaudeApprovalRequest) -> Void)?
    /// A lifecycle hook event arrived (identifiers only). Observation, never authority.
    var onLifecycle: ((ClaudeApprovalLifecycle) -> Void)?
    /// A pending request ended without an island click: (source, session, reason).
    var onRequestEnded: ((String, String, String) -> Void)?
    /// When true, requests are handed straight back without showing a card. Claude applies a hook's
    /// decision only after every PermissionRequest hook has finished (measured on 2.1.316), so
    /// holding a request here would block another running approver's decision, and vice versa.
    /// Takes the agent's source, and returns the name of the other app handling its requests, if any.
    var shouldYieldRequests: ((String) -> String?)?

    private let script: URL
    private let arguments: [String]
    private let python: URL
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var generation = UUID()
    private var buffer = Data()
    private var names: [String: String] = [:]
    private var owners: [String: (source: String, session: String)] = [:]
    private var outcomeExpiry: DispatchWorkItem?
    private let limit = 32 * 1024 * 1024
    private let auditLog: URL?

    /// `auditLog` records what happened to each request: tool name, session prefix and outcome.
    /// Tool input is never written, so the file can be read while verifying a real session.
    init(script: URL, python: URL = URL(fileURLWithPath: "/usr/bin/python3"), arguments: [String] = [], auditLog: URL? = nil) {
        self.script = script; self.python = python; self.arguments = arguments; self.auditLog = auditLog
    }

    private func audit(_ type: String, _ event: [String: Any]) {
        guard let auditLog else { return }
        var record: [String: Any] = ["time": Date().timeIntervalSince1970, "type": type]
        for key in ["decision", "reason", "is_error", "name"] { if let value = event[key] { record[key] = value } }
        if let nonce = event["nonce"] as? String {
            record["request"] = String(nonce.prefix(12))
            if let name = names[nonce] { record["tool"] = name }
        }
        if let tool = event["tool_name"] as? String { record["tool"] = tool }
        if let sid = event["session_id"] as? String { record["session"] = String(sid.prefix(8)) }
        guard var line = try? JSONSerialization.data(withJSONObject: record) else { return }
        line.append(10)
        let manager = FileManager.default
        if let size = (try? manager.attributesOfItem(atPath: auditLog.path))?[.size] as? Int, size > 1_048_576 {
            let old = auditLog.appendingPathExtension("1")
            try? manager.removeItem(at: old); try? manager.moveItem(at: auditLog, to: old)
        }
        if !manager.fileExists(atPath: auditLog.path) {
            manager.createFile(atPath: auditLog.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        if let handle = try? FileHandle(forWritingTo: auditLog) {
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: line); try? handle.close()
        }
    }

    func start() {
        guard process == nil else { return }
        guard FileManager.default.isReadableFile(atPath: script.path), FileManager.default.isExecutableFile(atPath: python.path) else {
            state = .failed("审批服务文件不可用"); return
        }
        let id = UUID(); generation = id; buffer = Data(); pending = []; names = [:]; endpoint = nil; state = .starting
        let p = Process(); let inputPipe = Pipe(); let outputPipe = Pipe()
        p.executableURL = python; p.arguments = ["-I", "-u", script.path] + arguments
        p.standardInput = inputPipe; p.standardOutput = outputPipe; p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.ended(id: id) }
        }
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { [weak self] in self?.receive(data, id: id) }
        }
        do {
            try p.run(); process = p; stdin = inputPipe.fileHandleForWriting; stdout = outputPipe.fileHandleForReading
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            try? inputPipe.fileHandleForWriting.close(); try? outputPipe.fileHandleForReading.close()
            state = .failed("审批服务无法启动")
        }
    }

    /// Explicit one-shot allow or deny from a button. Nothing calls this automatically.
    func decide(nonce: String, allow: Bool) {
        send(nonce: nonce, fields: ["decision": allow ? "allow" : "deny"])
    }

    /// Explicit "始终允许", adopting exactly one rule Claude itself suggested for this request.
    func decideAlways(nonce: String, suggestion: Int) {
        send(nonce: nonce, fields: ["decision": "allow", "suggestion": suggestion])
    }

    /// Explicit answer to a question card. Keys are the question texts, as Claude expects.
    func answer(nonce: String, answers: [String: String]) {
        guard !answers.isEmpty else { return }
        send(nonce: nonce, fields: ["decision": "answer", "answers": answers])
    }

    /// The user chose to answer in the agent's own interface. Codex shows its prompt only once the hook ends.
    func handBack(nonce: String) {
        guard state == .ready, pending.contains(where: { $0.id == nonce && !$0.isSubmitting }) else { return }
        release(nonce: nonce)
    }

    /// Hand a request back with no decision. The hook prints nothing.
    private func release(nonce: String) {
        guard let input = stdin, var line = try? JSONSerialization.data(withJSONObject: ["op": "release", "nonce": nonce]) else { return }
        line.append(10)
        try? input.write(contentsOf: line)
    }

    private func send(nonce: String, fields: [String: Any]) {
        guard state == .ready, let index = pending.firstIndex(where: { $0.id == nonce }), !pending[index].isSubmitting, let input = stdin else { return }
        var command = fields; command["op"] = "decision"; command["nonce"] = nonce
        guard var line = try? JSONSerialization.data(withJSONObject: command) else { return }
        line.append(10)
        do {
            try input.write(contentsOf: line)
            pending[index].isSubmitting = true
        } catch {
            show("发送失败，请在终端中审批", .warning)
            stop()
        }
    }

    func stop() {
        generation = UUID()
        stdout?.readabilityHandler = nil
        try? stdin?.close(); try? stdout?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil; stdin = nil; stdout = nil; endpoint = nil; pending = []; names = [:]; buffer = Data(); state = .stopped
    }

    private func ended(id: UUID) {
        guard id == generation else { return }
        stdout?.readabilityHandler = nil
        try? stdin?.close(); try? stdout?.close()
        process = nil; stdin = nil; stdout = nil; endpoint = nil; pending = []; names = [:]; buffer = Data()
        state = .failed("审批服务已停止，请求回到终端审批")
    }

    /// A line on the island that is not about a request, such as a jump that could not finish.
    func notice(_ text: String) { show(text, .warning) }

    private func show(_ text: String, _ kind: ClaudeApprovalOutcome.Kind) {
        lastOutcome = ClaudeApprovalOutcome(text: text, kind: kind)
        outcomeExpiry?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.lastOutcome = nil }
        outcomeExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func receive(_ data: Data, id: UUID) {
        guard id == generation, !data.isEmpty else { return }
        buffer.append(data)
        guard buffer.count <= limit else { stop(); state = .failed("审批服务消息过大"); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            guard let value = try? JSONSerialization.jsonObject(with: line), let event = value as? [String: Any], let type = event["type"] as? String else { continue }
            handle(type, event)
        }
    }

    private func handle(_ type: String, _ event: [String: Any]) {
        let nonce = event["nonce"] as? String
        if type != "lifecycle" { audit(type, event) }
        switch type {
        case "ready":
            guard let socket = event["socket"] as? String, let secret = event["secret_file"] as? String, socket.hasPrefix("/"), secret.hasPrefix("/") else { return }
            endpoint = Endpoint(socket: socket, secretFile: secret); state = .ready
        case "request":
            guard state == .ready, let request = Self.parse(event), pending.count < 256, !pending.contains(where: { $0.id == request.id }) else { return }
            if let other = shouldYieldRequests?(request.source) {
                release(nonce: request.id)
                show("\(other) 正在运行，\(request.toolName) 的审批交给它处理", .info)
                return
            }
            pending.append(request)
            names[request.id] = request.toolName
            owners[request.id] = (request.source, request.sessionID)
            if names.count > 1024 { names.removeAll(); owners.removeAll() }
            onRequest?(request)
        case "delivered":
            guard let nonce else { return }
            pending.removeAll { $0.id == nonce }
            let name = names[nonce] ?? "工具", agent = agentName(of: nonce)
            // Codex reports no outcome, so "handed over" is all that is known.
            let codex = owners[nonce]?.source == "codex"
            switch event["decision"] as? String {
            case "allow": show(codex ? "已允许 \(name)，已交给 Codex" : "已允许 \(name)，等待 \(agent) 执行", .info)
            case "answer": show("回答已交给 \(agent)", .info)
            default: show(codex ? "已拒绝 \(name)，已交给 Codex" : "已拒绝 \(name)，等待 \(agent) 确认", .info)
            }
        case "confirmed":
            let name = nonce.flatMap { names[$0] } ?? "工具"
            let outcome = Self.confirmedOutcome(decision: event["decision"] as? String ?? "", isError: event["is_error"] as? Bool ?? false, name: name, agent: agentName(of: nonce))
            show(outcome.text, outcome.kind)
        case "unconfirmed":
            let agent = agentName(of: nonce)
            show("没有收到 \(agent) 的结果事件，请到\(Self.place(agent))确认", .warning)
        case "resolved":
            guard let nonce, pending.contains(where: { $0.id == nonce }) else { return }
            pending.removeAll { $0.id == nonce }
            let name = names[nonce] ?? "工具"
            if let owner = owners[nonce], let reason = event["reason"] as? String { onRequestEnded?(owner.source, owner.session, reason) }
            let place = Self.place(agentName(of: nonce))
            switch event["reason"] as? String {
            case "released": show("\(name) 已交回 \(agentName(of: nonce))，请到那边处理", .info)
            case "answered-elsewhere": show("\(name) 已在其他地方处理", .info)
            case "turn-ended": show("这一轮已结束，\(name) 的请求已失效", .info)
            case "timeout": show("\(name) 等待超时，请在\(place)中审批", .warning)
            case "delivery-failed": show("决定没有送达，请在\(place)中审批", .warning)
            case "shutdown": show("审批服务已停止，请在\(place)中审批", .warning)
            default: show("\(name) 的请求已取消", .info)
            }
        case "rejected":
            if let nonce { pending.removeAll { $0.id == nonce } }
            show("这次点击没有生效：请求已经结束", .warning)
        case "lifecycle":
            if let name = event["name"] as? String, let sid = event["session_id"] as? String {
                onLifecycle?(ClaudeApprovalLifecycle(source: event["source"] as? String ?? "claude", name: name, sessionID: sid, cwd: event["cwd"] as? String, isSubagent: event["agent_id"] is String, notification: event["notification_type"] as? String, toolName: event["tool_name"] as? String, pid: (event["pid"] as? NSNumber)?.int32Value))
            }
        case "oversize":
            show("有一个请求过大，无法完整显示，请在终端中审批", .warning)
        default:
            break
        }
    }

    private func agentName(of nonce: String?) -> String {
        guard let source = nonce.flatMap({ owners[$0]?.source }), source != "claude" else { return "Claude" }
        return agentDisplayName(source)
    }

    private static func place(_ agent: String) -> String { agent == "Claude" ? "终端" : " \(agent) " }

    /// What may truthfully be said once Claude reports the call's result. Another approver can have
    /// answered first, and the first decision stands, so the result can differ from the click.
    static func confirmedOutcome(decision: String, isError: Bool, name: String, agent: String = "Claude") -> (text: String, kind: ClaudeApprovalOutcome.Kind) {
        let place = Self.place(agent)
        switch (decision, isError) {
        case ("allow", false): return ("\(agent) 已执行 \(name)", .success)
        case ("allow", true): return ("\(name) 没有成功：工具出错，或另一个审批方先拒绝了，请到\(place)查看", .warning)
        case ("answer", false): return ("\(agent) 已收到回答", .success)
        case ("answer", true): return ("回答没有生效，请到\(place)查看", .warning)
        case (_, true): return ("\(agent) 已按拒绝处理 \(name)", .success)
        default: return ("拒绝没有生效：另一个审批方先允许了，\(name) 已执行", .warning)
        }
    }

    /// Pure conversion from a broker event. Internal so that tests can exercise it.
    static func parse(_ event: [String: Any]) -> ClaudeApprovalRequest? {
        guard let nonce = event["nonce"] as? String,
              nonce.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let sid = event["session_id"] as? String, let name = event["tool_name"] as? String,
              let input = event["tool_input"] as? [String: Any], let text = event["tool_input_text"] as? String else { return nil }
        var questions: [ClaudeApprovalQuestion] = []
        if name == "AskUserQuestion", let list = input["questions"] as? [[String: Any]] {
            questions = list.compactMap { item in
                guard let question = item["question"] as? String, let options = item["options"] as? [[String: Any]] else { return nil }
                return ClaudeApprovalQuestion(
                    question: question, header: item["header"] as? String ?? "",
                    options: options.compactMap { o in (o["label"] as? String).map { .init(label: $0, detail: o["description"] as? String ?? "") } },
                    multiSelect: item["multiSelect"] as? Bool ?? false)
            }
        }
        let suggestions = (event["permission_suggestions"] as? [[String: Any]] ?? []).enumerated().compactMap { index, value in
            describe(suggestion: value).map { ClaudeApprovalSuggestion(index: index, label: $0) }
        }
        return ClaudeApprovalRequest(
            id: nonce, source: event["source"] as? String ?? "claude", sessionID: sid, toolName: name, toolInputText: text,
            command: input["command"] as? String,
            filePath: (input["file_path"] as? String) ?? (input["notebook_path"] as? String) ?? (input["url"] as? String),
            summary: input["description"] as? String,
            cwd: event["cwd"] as? String ?? "",
            agentType: event["agent_type"] as? String,
            isSubagent: event["agent_id"] is String,
            permissionMode: event["permission_mode"] as? String,
            questions: questions, suggestions: suggestions,
            hint: ClaudeApprovalHint.make(toolName: name, command: input["command"] as? String, permissionMode: event["permission_mode"] as? String))
    }

    /// Spells out what adopting a suggestion would do. A suggestion that cannot be described is not offered.
    static func describe(suggestion value: [String: Any]) -> String? {
        let place: String
        switch value["destination"] as? String {
        case "session": place = "本次会话"
        case "localSettings": place = "本项目（本机）"
        case "projectSettings": place = "本项目"
        case "userSettings": place = "所有项目"
        default: return nil
        }
        switch value["type"] as? String {
        case "addRules":
            guard value["behavior"] as? String == "allow", let rules = value["rules"] as? [[String: Any]], !rules.isEmpty else { return nil }
            let text = rules.compactMap { rule -> String? in
                guard let tool = rule["toolName"] as? String else { return nil }
                if let content = rule["ruleContent"] as? String { return "\(tool)(\(content))" }
                return tool
            }.joined(separator: "、")
            return text.isEmpty ? nil : "始终允许 \(text) · \(place)"
        case "addDirectories":
            guard let directories = value["directories"] as? [String], !directories.isEmpty else { return nil }
            return "始终允许访问 \(directories.joined(separator: "、")) · \(place)"
        default:
            return nil
        }
    }
}
