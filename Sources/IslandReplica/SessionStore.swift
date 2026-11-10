import Foundation
import Combine
import CoreGraphics

/// A compact presentation state, not an exhaustive model of every agent protocol.
enum SessionStatus: String, Codable {
    case working, waiting, idle, error, unknown
}

struct SessionTodo: Codable, Equatable {
    let text: String
    /// pending, in_progress or completed, as Claude reports them.
    let state: String
}

struct SessionSubagent: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let task: String
    let step: String?
    let running: Bool
}

/// What a session is doing now. Display only; it is never stored.
struct SessionActivity: Codable, Equatable {
    var task: String?
    var step: String?
    var todos: [SessionTodo] = []
    var subagents: [SessionSubagent] = []
}

struct SessionItem: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var agent: String
    var status: SessionStatus
    var detail: String
    var updatedAt: Date
    var lifecycle: String? = nil
    var lifecycleID: String? = nil
    var activity: SessionActivity? = nil
    /// The session's process, where known. Clicking the row uses it to find the terminal.
    var pid: Int32? = nil
    /// A link that opens this very conversation, where its app has one.
    var jumpURL: String? = nil

    /// Height this row needs in the expanded island, so the island can size itself to the content.
    var expandedHeight: CGFloat {
        var height: CGFloat = 52
        guard let activity else { return height }
        if activity.task != nil { height += 17 }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "showTasks") as? Bool ?? true { height += CGFloat(min(activity.todos.count, 5)) * 16 }
        if !activity.subagents.isEmpty {
            height += 20
            if defaults.object(forKey: "showSubagents") as? Bool ?? true { height += CGFloat(min(activity.subagents.count, 3)) * 16 }
        }
        return height
    }
}

/// A Claude session whose process is running now.
struct ClaudeLiveSession: Equatable {
    let sessionID: String
    let cwd: String
    let startedAt: Date
    var name: String? = nil
    /// Claude's own busy or idle flag from its session registry.
    var status: String? = nil
    var statusUpdatedAt: Date? = nil
    var pid: Int32? = nil
}

/// Normalized local event. Adapters are responsible for translating provider payloads.
struct SessionEvent: Codable {
    var sessionId: String
    var event: String
    var agent: String?
    var title: String?
    var detail: String?
}

@MainActor
final class SessionStore: ObservableObject {
    /// Bound the event receiver's additions. Direct adapter updates have their own limits.
    private static let eventSessionLimit = 512
    @Published var sessions: [SessionItem] { didSet { refreshVisible() } }
    /// What the island shows: `sessions` minus those idle for longer than the chosen time.
    /// They come back on their next activity. State, names and sounds still use `sessions`.
    @Published private(set) var visibleSessions: [SessionItem] = []
    /// Seconds without activity before an idle Claude session is hidden; 0 never hides. Default 2 hours, as the original.
    static let idleTimeoutKey = "idleSessionTimeout"
    static let idleTimeoutDefault: Double = 7200
    /// Every other agent, at the user's request. Not a setting.
    nonisolated static let otherAgentIdleTimeout: TimeInterval = 600
    private var idleTimer: Timer?
    private var agentPIDs: [String: Int32] = [:]
    private var codexLiveRows: [SessionItem] = []
    private var codexWaiting: Set<String> = []
    private var defaultsObserver: NSObjectProtocol?
    private struct ClaudeObservation { let status: SessionStatus; let detail: String; let time: Date }
    private var claudeObservations: [String: ClaudeObservation] = [:]
    private var claudeEnded: [String: Date] = [:]
    private var claudeLive: [String: ClaudeLiveSession] = [:]
    private var claudeHistory: [SessionItem] = []
    private var claudeActivity: [String: SessionActivity] = [:]

    init(demo: Bool = true) {
        if demo {
            let now = Date()
            sessions = [
                SessionItem(id: "demo-1", title: "优化搜索体验", agent: "Codex", status: .working, detail: "正在分析项目结构", updatedAt: now),
                SessionItem(id: "demo-2", title: "实现通知面板", agent: "Claude Code", status: .waiting, detail: "需要确认操作", updatedAt: now.addingTimeInterval(-65)),
                SessionItem(id: "demo-3", title: "整理文档", agent: "Gemini", status: .idle, detail: "任务已完成", updatedAt: now.addingTimeInterval(-180))
            ]
        } else {
            sessions = []
        }
        refreshVisible()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor in self?.removeRowsOfDeadAgents(); self?.refreshVisible() } }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshVisible() }
        }
    }

    /// Only an idle or failed session hides. Working, waiting for approval, or with a subagent
    /// still running, it stays whatever its age. `timeout` is the setting, which applies to Claude only.
    nonisolated static func hidesWhenIdle(_ item: SessionItem, now: Date, timeout: TimeInterval) -> Bool {
        let limit = item.id.hasPrefix("claude:") || item.agent == "Claude Code" ? timeout : otherAgentIdleTimeout
        guard limit > 0, !item.id.hasPrefix("demo-"), item.status == .idle || item.status == .error else { return false }
        if item.activity?.subagents.contains(where: \.running) == true { return false }
        return now.timeIntervalSince(item.updatedAt) > limit
    }

    func refreshVisible(now: Date = Date()) {
        let stored = UserDefaults.standard.object(forKey: Self.idleTimeoutKey) as? Double
        let timeout = stored ?? Self.idleTimeoutDefault
        let next = sessions.filter { !Self.hidesWhenIdle($0, now: now, timeout: timeout) }
        if next != visibleSessions { visibleSessions = next }
    }

    /// Updates only explicit data supplied by the caller; does not read agent files or install hooks.
    func ingest(_ event: SessionEvent) {
        let id = event.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        let normalizedEvent = event.event.lowercased().filter { $0.isLetter || $0.isNumber }
        if normalizedEvent == "sessionend" {
            sessions.removeAll { $0.id == id }
            return
        }
        let state = Self.status(for: event.event)
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            var item = sessions[index]
            if let state { item.status = state }
            if let agent = Self.nonempty(event.agent) { item.agent = agent }
            if let title = Self.nonempty(event.title) { item.title = title }
            if let detail = event.detail { item.detail = detail }
            item.updatedAt = Date()
            var updated = sessions
            updated.remove(at: index)
            updated.insert(item, at: 0)
            sessions = updated
        } else {
            // Unknown lifecycle events do not establish a session state.
            guard let state else { return }
            // Keep active and waiting sessions, and never evict the Codex adapter's
            // rows. If all slots are in use, drop the new event instead of
            // incorrectly presenting a live session as finished.
            while sessions.count >= Self.eventSessionLimit {
                guard let victim = sessions.indices
                    .filter({ !sessions[$0].id.hasPrefix("codex:") && (sessions[$0].status == .idle || sessions[$0].status == .error) })
                    .min(by: { sessions[$0].updatedAt < sessions[$1].updatedAt }) else { return }
                sessions.remove(at: victim)
            }
            let item = SessionItem(
                id: id,
                title: Self.nonempty(event.title) ?? "新会话",
                agent: Self.nonempty(event.agent) ?? "Agent",
                status: state,
                detail: event.detail ?? "",
                updatedAt: Date()
            )
            sessions.insert(item, at: 0)
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A lifecycle event from an agent hook other than Claude. Rows carry the session's own state.
    func observeAgent(source: String, name: String, sessionID: String, event: String, cwd: String?, at: Date = Date(), pid: Int32? = nil) {
        let id = source + ":" + sessionID
        if event == "SessionEnd" { sessions.removeAll { $0.id == id }; agentPIDs.removeValue(forKey: id); return }
        if let pid { agentPIDs[id] = pid }
        let state: SessionStatus, detail: String
        switch event {
        case "SessionStart": state = .idle; detail = "会话已开始"
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact": state = .working; detail = "处理中"
        case "PermissionRequest": state = .waiting; detail = "需要审批"
        case "Notification": state = .waiting; detail = "等待处理"
        case "Stop": state = .idle; detail = "本轮已结束"
        case "StopFailure": state = .error; detail = "本轮异常结束"
        default: return
        }
        let title = cwd.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? (name + " 会话")
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].status = state; sessions[index].detail = detail; sessions[index].updatedAt = at
            if sessions[index].title.hasSuffix(" 会话") { sessions[index].title = title }
        } else if sessions.count < Self.eventSessionLimit {
            sessions.insert(SessionItem(id: id, title: title, agent: name, status: state, detail: detail, updatedAt: at), at: 0)
        }
    }

    /// A local observation, not an approval decision or proof that a process is alive.
    func observeClaude(sessionID: String, event: String, notification: String?, at: Date) {
        let id = "claude:" + sessionID.lowercased()
        guard !sessionID.isEmpty, abs(at.timeIntervalSinceNow) < 60 else { return }
        if event == "SessionEnd" {
            if claudeEnded.count >= Self.eventSessionLimit, let oldest = claudeEnded.min(by: { $0.value < $1.value })?.key { claudeEnded.removeValue(forKey: oldest) }
            claudeObservations.removeValue(forKey: id); claudeEnded[id] = at
            rebuildClaudeRows(); return
        }
        let state: SessionStatus, detail: String
        switch event {
        case "SessionStart": state = .idle; detail = "会话已开始"
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure": state = .working; detail = "处理中"
        case "PermissionRequest": state = .waiting; detail = "需要审批"
        case "Notification" where notification == "permission_prompt" || notification == "elicitation_dialog" || notification == "elicitation_url_dialog" || notification == "agent_needs_input": state = .waiting; detail = "等待处理"
        case "Notification" where notification == "idle_prompt": state = .idle; detail = "等待输入"
        case "Stop": state = .idle; detail = "本轮已结束"
        case "StopFailure": state = .error; detail = "本轮异常结束"
        case "Interrupted": state = .idle; detail = "已中断"
        case "PreCompact": state = .working; detail = "压缩中"
        default: return
        }
        claudeEnded.removeValue(forKey: id)
        if claudeObservations.count >= Self.eventSessionLimit, claudeObservations[id] == nil,
           let oldest = claudeObservations.min(by: { $0.value.time < $1.value.time })?.key { claudeObservations.removeValue(forKey: oldest) }
        claudeObservations[id] = ClaudeObservation(status: state, detail: detail, time: at)
        rebuildClaudeRows()
    }

    /// The running Claude processes. A session is listed while its process lives, whatever its state.
    static let codexLivePrefix = "codex-live:"

    /// Whether anyone is still at it: running, waiting for an answer, or with a subagent running.
    var hasWorkInProgress: Bool {
        sessions.contains { $0.status == .working || $0.status == .waiting || $0.activity?.subagents.contains(where: \.running) == true }
    }

    func syncCodexLive(_ rows: [SessionItem]) {
        codexLiveRows = rows
        applyCodexRows()
    }

    /// Codex does not log a pending approval, so the rows learn it from the island's own cards.
    func setCodexWaiting(_ sessionIDs: Set<String>) {
        guard sessionIDs != codexWaiting else { return }
        codexWaiting = sessionIDs
        applyCodexRows()
    }

    private func applyCodexRows() {
        let rows = codexLiveRows.map { row -> SessionItem in
            guard codexWaiting.contains(String(row.id.dropFirst(Self.codexLivePrefix.count))) else { return row }
            var waiting = row
            waiting.status = .waiting; waiting.detail = "等待审批"
            return waiting
        }
        let next = sessions.filter { !$0.id.hasPrefix(Self.codexLivePrefix) } + rows
        if next != sessions { sessions = next }
    }

    /// A hook-fed agent that is killed sends no SessionEnd. A process that has gone takes its rows with it.
    func removeRowsOfDeadAgents() {
        let dead = agentPIDs.filter { kill($0.value, 0) != 0 && errno == ESRCH }.map(\.key)
        guard !dead.isEmpty else { return }
        for id in dead { agentPIDs.removeValue(forKey: id) }
        sessions.removeAll { dead.contains($0.id) }
    }

    func syncClaudeLive(_ live: [ClaudeLiveSession]) {
        let next = Dictionary(live.map { ("claude:" + $0.sessionID.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        // A process that has gone takes its state with it, even if Claude sent no SessionEnd.
        for key in claudeLive.keys where next[key] == nil { claudeObservations.removeValue(forKey: key) }
        claudeLive = next
        // Resuming a session starts a new process with the same ID, which undoes its earlier end.
        for (key, session) in claudeLive { if let ended = claudeEnded[key], session.startedAt > ended { claudeEnded.removeValue(forKey: key) } }
        rebuildClaudeRows()
    }

    /// What each running session is doing, keyed by session ID.
    func updateClaudeActivity(_ activity: [String: SessionActivity]) {
        guard activity != claudeActivity else { return }
        claudeActivity = activity
        rebuildClaudeRows()
    }

    /// Past sessions from the optional history reader. They never count as running.
    func mergeClaudeHistory(_ history: [SessionItem]) {
        claudeHistory = history
        rebuildClaudeRows()
    }

    func clearClaudeObservations() {
        claudeObservations.removeAll(); claudeEnded.removeAll()
        rebuildClaudeRows()
    }

    /// One row per Claude session: live processes first, then recent observations with no registry
    /// entry (they expire after two minutes), then history if it is switched on.
    private func rebuildClaudeRows() {
        let now = Date()
        claudeObservations = claudeObservations.filter { claudeLive[$0.key] != nil || now.timeIntervalSince($0.value.time) < 120 }
        claudeEnded = claudeEnded.filter { now.timeIntervalSince($0.value) < 7200 }
        var rows: [SessionItem] = []
        var seen = Set<String>()
        for (key, live) in claudeLive.sorted(by: { $0.value.startedAt > $1.value.startedAt }) where claudeEnded[key] == nil {
            let observed = claudeObservations[key]
            let activity = claudeActivity[live.sessionID]
            // Whichever spoke last wins: a hook event, or Claude's own busy/idle flag. A pending
            // permission only ends with a later event, because Claude may report idle during it.
            var status = observed?.status ?? .idle
            var label = observed?.detail ?? "等待输入"
            var time = observed?.time ?? live.startedAt
            if let flagged = live.statusUpdatedAt, flagged > (observed?.time ?? .distantPast) {
                time = flagged
                if live.status == "busy" { status = .working; label = "处理中" }
                else if live.status == "idle" { status = .idle; label = "等待输入" }
            }
            if status == .working && label != "压缩中" { label = activity?.step ?? "思考中" }
            let folder = (live.cwd as NSString).lastPathComponent
            // The conversation's own name first. The folder is then context; without a name it is the title.
            let title = live.name ?? (folder.isEmpty ? "Claude 会话" : folder)
            let showProject = UserDefaults.standard.object(forKey: "showProjectName") as? Bool ?? true
            let place = !showProject ? "" : live.name != nil && !folder.isEmpty ? folder : String(live.sessionID.prefix(8))
            let repeatsStatus = ["等待输入", "思考中", "处理中", "需要审批", "压缩中"].contains(label)
            rows.append(SessionItem(id: key, title: title, agent: "Claude Code", status: status, detail: repeatsStatus && label != "压缩中" ? place : place.isEmpty ? label : label + " · " + place,
                                    updatedAt: time, activity: activity, pid: live.pid))
            seen.insert(key)
        }
        let history = Dictionary(claudeHistory.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for (key, observed) in claudeObservations where !seen.contains(key) && claudeEnded[key] == nil {
            let past = history[key]
            rows.append(SessionItem(id: past?.id ?? key, title: past?.title ?? "Claude 会话", agent: "Claude Code", status: observed.status, detail: observed.detail, updatedAt: observed.time))
            seen.insert(key)
        }
        for row in claudeHistory where !seen.contains(row.id.lowercased()) && claudeEnded[row.id.lowercased()] == nil { rows.append(row) }
        let next = sessions.filter { !$0.id.hasPrefix("claude:") && !$0.id.hasPrefix("demo-") } + rows
        if next != sessions { sessions = next }
    }

    /// Accept normalized states and unambiguous lifecycle hook names.
    /// Ambiguous events, including generic notifications, leave state unchanged.
    private static func status(for raw: String) -> SessionStatus? {
        let name = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        switch name {
        case "working", "running", "userpromptsubmit", "pretooluse", "posttooluse", "posttoolusefailure", "taskstart", "turnstart":
            return .working
        case "waiting", "permissionrequest", "question", "inputrequired", "approvalrequired":
            return .waiting
        case "idle", "sessionstart", "stop", "turncompleted":
            return .idle
        case "error", "failure", "taskfailed", "turnfailed", "stopfailure":
            return .error
        default:
            return nil
        }
    }
}
