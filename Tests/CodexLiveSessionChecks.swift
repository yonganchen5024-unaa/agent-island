import Foundation
// Compile with every file in Sources/IslandReplica except main.swift. Fictional rollouts only.
struct Fixture: CodexOpenFileDiscovering {
    let files: [CodexOpenFile]
    func discover() throws -> CodexOpenFileSnapshot { CodexOpenFileSnapshot(files: files, complete: true) }
}
@main struct CodexLiveSessionChecks {
    @MainActor static func main() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString)").resolvingSymlinksInPath()
        let root = temp.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        func meta(_ id: String, _ extra: String) -> String { #"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"/fixture/\#(id)-folder"\#(extra)}}"# + "\n" }
        func event(_ type: String, _ turn: String) -> String { #"{"type":"event_msg","payload":{"type":"\#(type)","turn_id":"\#(turn)"}}"# + "\n" }
        func write(_ name: String, _ text: String) throws -> String { let u = root.appendingPathComponent(name); try text.write(to: u, atomically: true, encoding: .utf8); return u.path }
        let desktop = #","originator":"Codex Desktop""#
        let a = try write("a.jsonl", meta("aaaa-1", desktop) + event("task_started", "t1"))
        let b = try write("b.jsonl", meta("bbbb-2", desktop) + event("task_started", "t1") + event("task_complete", "t1"))
        let c = try write("c.jsonl", meta("cccc-3", #","originator":"codex_cli_rs""#))
        let child = try write("d.jsonl", meta("dddd-4", desktop + #","thread_source":"subagent""#) + event("task_started", "t1"))
        let older = try write("e.jsonl", meta("eeee-5", desktop + #","parent_thread_id":"aaaa-1""#))
        let outside = temp.appendingPathComponent("outside.jsonl"); try meta("ffff-6", desktop).write(to: outside, atomically: true, encoding: .utf8)
        let found = Fixture(files: [a, b, c, child, older, outside.path].enumerated().map { CodexOpenFile(pid: 100 + Int32($0.offset), path: $0.element) })
        let observed = try CodexLiveTracker(root: root, discovery: found).snapshot().sessions
        let rows = CodexLiveRows.rows(from: observed, names: ["aaaa-1": "虚构对话名"], now: Date()).sorted { $0.id < $1.id }
        // Subagent threads and files outside the sessions folder are not rows.
        precondition(rows.map(\.id) == ["codex-live:aaaa-1", "codex-live:bbbb-2", "codex-live:cccc-3"], "\(rows.map(\.id))")
        // A turn in progress, a finished one, and a new session with no turn yet.
        precondition(rows[0].status == .working && rows[1].status == .idle && rows[2].status == .idle)
        // The conversation's own name first, then the folder.
        precondition(rows[0].title == "虚构对话名" && rows[0].detail == "aaaa-1-folder" && rows[1].title == "bbbb-2-folder" && rows[1].detail == "")
        // The desktop app opens by link. A CLI session goes through its process.
        precondition(rows[0].jumpURL == "codex://threads/aaaa-1" && rows[2].jumpURL == nil && rows[2].pid == 102)
        // Real events reach the sound layer.
        precondition(rows[1].lifecycle == "task_complete" && rows[1].lifecycleID == "task_complete:t1")
        // The start of a long turn can fall out of the tail. A recent write then still means running.
        var long = CodexLiveObservation(sessionID: "aaaa-1", associatedPIDs: [1], lastRecordedTurn: .unknown)
        long.truncated = true; long.modified = Date()
        precondition(CodexLiveRows.rows(from: [long], names: [:], now: Date())[0].status == .working)
        long.modified = Date().addingTimeInterval(-300)
        precondition(CodexLiveRows.rows(from: [long], names: [:], now: Date())[0].status == .idle)
        // An id that could change the link's meaning gets no link.
        var odd = CodexLiveObservation(sessionID: "aaaa/../x", associatedPIDs: [1], lastRecordedTurn: .unknown); odd.desktop = true
        precondition(CodexLiveRows.rows(from: [odd], names: [:], now: Date())[0].jumpURL == nil)
        // Names come from the last line for an id, and a changed file is reread.
        let index = temp.appendingPathComponent("session_index.jsonl")
        try (#"{"id":"x","thread_name":"旧名"}"# + "\n" + #"{"id":"x","thread_name":"新名"}"# + "\n" + "broken\n").write(to: index, atomically: true, encoding: .utf8)
        var names = CodexThreadNames()
        precondition(names.current(file: index)["x"] == "新名")
        // Rows arrive, are replaced, and leave without touching other agents' rows.
        let store = SessionStore(demo: false)
        store.sessions = [SessionItem(id: "claude:one", title: "c", agent: "Claude Code", status: .idle, detail: "", updatedAt: Date())]
        store.syncCodexLive(rows)
        precondition(store.sessions.count == 4)
        precondition(store.hasWorkInProgress, "a Codex turn counts as work")
        store.syncCodexLive([])
        precondition(store.sessions.map(\.id) == ["claude:one"] && !store.hasWorkInProgress)
        store.sessions[0].status = .waiting
        precondition(store.hasWorkInProgress, "waiting for the user is not done")
        store.sessions[0].status = .idle
        store.sessions[0].activity = SessionActivity(task: nil, step: nil, subagents: [SessionSubagent(id: "s", name: "n", task: "t", step: nil, running: true)])
        precondition(store.hasWorkInProgress, "a running subagent is not done")
        print("CodexLiveSessionChecks passed")
    }
}
