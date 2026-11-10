import Foundation
// Compile with SessionStore.swift and ClaudeActivityReader.swift. Fictional transcript only.
@main struct ClaudeActivityChecks {
    static func line(_ object: [String: Any]) -> Data {
        var data = try! JSONSerialization.data(withJSONObject: object); data.append(10); return data
    }
    static func use(_ id: String, _ name: String, _ input: [String: Any]) -> Data {
        line(["type": "assistant", "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]]])
    }
    static func result(_ id: String) -> Data {
        line(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": id, "content": "FICTIONAL_OUTPUT"]]]])
    }
    @MainActor static func main() {
        var data = line(["type": "last-prompt", "lastPrompt": "把虚构页面改好\n第二行"])
        data += line(["type": "assistant", "message": ["content": [["type": "text", "text": "FICTIONAL_ASSISTANT_TEXT"]]]])
        data += use("t1", "TodoWrite", ["todos": [["content": "看代码", "status": "completed", "activeForm": "正在看代码"],
                                                  ["content": "改页面", "status": "in_progress", "activeForm": "正在改页面"],
                                                  ["content": "跑测试", "status": "pending", "activeForm": "正在跑测试"]]])
        data += result("t1")
        data += use("t2", "Read", ["file_path": "/fictional/dir/page.swift"])
        data += result("t2")
        var parsed = ClaudeActivityParser.parse(data, startsMidFile: false)
        precondition(parsed.task == "把虚构页面改好 第二行")
        precondition(parsed.step == nil, "a finished call is not the current step")
        precondition(parsed.todos.map(\.state) == ["completed", "in_progress", "pending"] && parsed.todos[1].text == "正在改页面" && parsed.todos[0].text == "看代码")
        data += use("t3", "Bash", ["command": "npm test\nrm -rf nothing", "description": "跑虚构测试"])
        parsed = ClaudeActivityParser.parse(data, startsMidFile: false)
        precondition(parsed.step == "运行 跑虚构测试")
        data += result("t3")
        data += use("t4", "Agent", ["description": "查虚构资料", "subagent_type": "Explore"])
        parsed = ClaudeActivityParser.parse(data, startsMidFile: false)
        precondition(parsed.step == "启动子 Agent：查虚构资料" && parsed.openAgents == ["t4"])
        // A sidechain record belongs to a subagent, not to this session's own step.
        data += result("t4")
        data += line(["type": "assistant", "isSidechain": true, "message": ["content": [["type": "tool_use", "id": "x", "name": "Bash", "input": ["command": "side"]]]]])
        parsed = ClaudeActivityParser.parse(data, startsMidFile: false)
        precondition(parsed.step == nil)
        // A tail that starts mid-record, and garbage, are skipped rather than fatal.
        let cut = Data("{\"type\":\"assist".utf8) + Data([10]) + Data("not json".utf8) + Data([10]) + use("t9", "Grep", ["pattern": "foo"])
        precondition(ClaudeActivityParser.parse(cut, startsMidFile: true).step == "搜索 foo")
        // Assistant text and tool output are never carried into what the island shows.
        let shown = String(describing: parsed)
        precondition(!shown.contains("FICTIONAL_OUTPUT") && !shown.contains("FICTIONAL_ASSISTANT_TEXT"))
        precondition(ClaudeActivityParser.clip(String(repeating: "长", count: 200)).count == 91)

        // Claude's own flag and hook events: the later of the two sets the state.
        let store = SessionStore(demo: false)
        let id = "aaaaaaaa-0000-4000-8000-000000000001", now = Date()
        func row() -> SessionItem { store.sessions.first { $0.id == "claude:" + id }! }
        func sync(_ status: String, _ at: Date) { store.syncClaudeLive([ClaudeLiveSession(sessionID: id, cwd: "/fictional/p", startedAt: now.addingTimeInterval(-60), name: "虚构", status: status, statusUpdatedAt: at)]) }
        sync("busy", now)
        precondition(row().status == .working && row().detail == "p")
        store.updateClaudeActivity([id: SessionActivity(task: "虚构任务", step: "运行 虚构命令")])
        precondition(row().detail.hasPrefix("运行 虚构命令") && row().activity?.task == "虚构任务")
        store.observeClaude(sessionID: id, event: "PermissionRequest", notification: nil, at: now.addingTimeInterval(1))
        precondition(row().status == .waiting, "a hook event newer than the flag wins")
        sync("idle", now.addingTimeInterval(2))
        precondition(row().status == .idle, "Claude's later idle flag ends the wait, covering an Esc with no hook event")
        // The row reports how tall it needs to be.
        var activity = SessionActivity(task: "虚构")
        activity.todos = [SessionTodo(text: "a", state: "pending")]
        activity.subagents = [SessionSubagent(id: "s", name: "Explore", task: "t", step: nil, running: true)]
        store.updateClaudeActivity([id: activity])
        precondition(row().expandedHeight > 68 + 17)
        print("ClaudeActivityChecks passed")
    }
}
