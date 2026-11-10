import Foundation
// Compile with SessionStore.swift and ClaudeLiveSessionReader.swift. Fictional sessions only.
@main struct ClaudeLiveSessionChecks {
    static let a = "aaaaaaaa-0000-4000-8000-000000000001", b = "bbbbbbbb-0000-4000-8000-000000000002"
    @MainActor static func main() async throws {
        let store = SessionStore(demo: false)
        let t0 = Date()
        func rows() -> [SessionItem] { store.sessions.filter { $0.id.hasPrefix("claude:") } }
        func row(_ id: String) -> SessionItem? { store.sessions.first { $0.id == "claude:" + id } }

        // A session opened with no message yet is listed, and stays listed past the old 2-minute expiry.
        store.syncClaudeLive([ClaudeLiveSession(sessionID: a, cwd: "/fictional/示例项目", startedAt: t0)])
        precondition(rows().count == 1 && row(a)?.title == "示例项目" && row(a)?.status == .idle && row(a)?.detail.contains("aaaaaaaa") == true)

        // The conversation's name wins over the folder, and a later /rename follows through.
        store.syncClaudeLive([ClaudeLiveSession(sessionID: a, cwd: "/fictional/示例项目", startedAt: t0, name: "接口重构")])
        precondition(row(a)?.title == "接口重构" && row(a)?.detail.contains("示例项目") == true)
        store.syncClaudeLive([ClaudeLiveSession(sessionID: a, cwd: "/fictional/示例项目", startedAt: t0, name: "界面调整")])
        precondition(row(a)?.title == "界面调整")
        store.syncClaudeLive([ClaudeLiveSession(sessionID: a, cwd: "/fictional/示例项目", startedAt: t0)])
        precondition(row(a)?.title == "示例项目")

        // History never adds "running" rows beyond itself, and a live session is not listed twice.
        let oldPast = SessionItem(id: "claude:" + b, title: "旧项目", agent: "Claude Code", status: .unknown, detail: "历史", updatedAt: t0.addingTimeInterval(-90000))
        let samePast = SessionItem(id: "claude:" + a.uppercased(), title: "历史标题", agent: "Claude Code", status: .unknown, detail: "历史", updatedAt: t0)
        store.mergeClaudeHistory([oldPast, samePast])
        precondition(rows().count == 2 && row(a)?.status == .idle)
        store.mergeClaudeHistory([])
        precondition(rows().count == 1)

        // Hook events drive state, and a long gap between events does not change it.
        store.observeClaude(sessionID: a, event: "UserPromptSubmit", notification: nil, at: t0)
        precondition(row(a)?.status == .working)
        store.observeClaude(sessionID: a, event: "PermissionRequest", notification: nil, at: t0)
        precondition(row(a)?.status == .waiting)
        store.observeClaude(sessionID: a, event: "Interrupted", notification: nil, at: t0)
        precondition(row(a)?.status == .idle && row(a)?.detail.contains("已中断") == true)
        store.observeClaude(sessionID: a, event: "PreToolUse", notification: nil, at: t0)
        store.observeClaude(sessionID: a, event: "Stop", notification: nil, at: t0)
        precondition(row(a)?.status == .idle)
        store.observeClaude(sessionID: a, event: "StopFailure", notification: nil, at: t0)
        precondition(row(a)?.status == .error)

        // Two sessions in one folder stay separate rows, and each keeps its own state.
        store.syncClaudeLive([ClaudeLiveSession(sessionID: a, cwd: "/fictional/示例项目", startedAt: t0), ClaudeLiveSession(sessionID: b, cwd: "/fictional/示例项目", startedAt: t0)])
        precondition(rows().count == 2 && row(b)?.status == .idle && row(a)?.status == .error)

        // The process ending removes the row even when Claude sent no SessionEnd.
        store.syncClaudeLive([ClaudeLiveSession(sessionID: b, cwd: "/fictional/示例项目", startedAt: t0)])
        precondition(row(a) == nil && rows().count == 1)

        // SessionEnd removes it at once. Resuming the same ID in a later process brings it back.
        store.observeClaude(sessionID: b, event: "SessionEnd", notification: nil, at: Date())
        precondition(rows().isEmpty)
        store.syncClaudeLive([ClaudeLiveSession(sessionID: b, cwd: "/fictional/示例项目", startedAt: t0)])
        precondition(rows().isEmpty, "the ended process's own registry entry must not revive the row")
        store.syncClaudeLive([ClaudeLiveSession(sessionID: b, cwd: "/fictional/示例项目", startedAt: Date().addingTimeInterval(5))])
        precondition(rows().count == 1 && row(b) != nil)
        store.syncClaudeLive([])

        // An observation with no registry entry shows, without becoming a permanent row.
        store.observeClaude(sessionID: a, event: "UserPromptSubmit", notification: nil, at: Date())
        precondition(row(a)?.status == .working)

        // The scan: running PID accepted; dead PID, reused PID, bad file and wrong name refused.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let me = ProcessInfo.processInfo.processIdentifier
        func write(_ name: String, _ pid: Int32, _ id: String, startedMS: Double) throws {
            let object: [String: Any] = ["pid": pid, "sessionId": id, "cwd": "/fictional/p", "startedAt": startedMS, "name": "  虚构名称 "]
            try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent(name))
        }
        let nowMS = Date().timeIntervalSince1970 * 1000
        try write("\(me).json", me, a, startedMS: nowMS)
        try write("999999.json", 999999, b, startedMS: nowMS)
        try write("1.json", 1, "reused-pid", startedMS: 1000)
        try write("\(me + 1).json", me, "wrong-name", startedMS: nowMS)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("7.json"))
        try Data("ignored".utf8).write(to: directory.appendingPathComponent("\(me).key"))
        let live = ClaudeLiveScan.scan(directory: directory)
        precondition(live.map(\.sessionID) == [a] && live.first?.name == "虚构名称", "\(live)")
        print("ClaudeLiveSessionChecks passed")
    }
}
