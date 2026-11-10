// Compile with SessionStore.swift, ClaudeLiveSessionReader.swift, ClaudeActivityReader.swift, PixelActivity.swift
// and AgentUsageReader.swift. Fictional sessions only.
import Foundation

@main struct Check {
    @MainActor static func main() {
        var failures = 0
        func expect(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL", what) } }
        let now = Date(), hour: TimeInterval = 3600
        func item(_ id: String, _ status: SessionStatus, ago: TimeInterval, subagent: Bool = false) -> SessionItem {
            var row = SessionItem(id: id, title: "虚构会话", agent: id.hasPrefix("claude:") ? "Claude Code" : "Codex", status: status, detail: "", updatedAt: now.addingTimeInterval(-ago))
            if subagent { row.activity = SessionActivity(subagents: [SessionSubagent(id: "a", name: "general-purpose", task: "虚构任务", step: nil, running: true)]) }
            return row
        }
        let hides = { (row: SessionItem, timeout: TimeInterval) in SessionStore.hidesWhenIdle(row, now: now, timeout: timeout) }
        expect(hides(item("claude:a", .idle, ago: 3 * hour), 2 * hour), "Claude idle past the setting hides")
        expect(!hides(item("claude:b", .idle, ago: 1 * hour), 2 * hour), "Claude idle inside the setting stays, even past 10 minutes")
        // Everyone else: ten minutes, whatever the setting says.
        expect(hides(item("codex-live:i", .idle, ago: 11 * 60), 2 * hour), "Codex idle past 10 minutes hides")
        expect(!hides(item("codex-live:j", .idle, ago: 9 * 60), 2 * hour), "Codex idle inside 10 minutes stays")
        expect(hides(item("gemini:k", .error, ago: 11 * 60), 2 * hour), "another agent's failed turn hides too")
        expect(hides(item("codex-live:l", .idle, ago: 11 * 60), 0), "永不清理 is about Claude only")
        expect(!hides(item("codex-live:m", .working, ago: 30 * hour), 2 * hour), "a working Codex never hides")
        expect(!hides(item("codex-live:n", .waiting, ago: 30 * hour), 2 * hour), "a waiting Codex never hides")
        expect(!hides(item("codex-live:o", .idle, ago: 30 * hour, subagent: true), 2 * hour), "a Codex with a running subagent stays")
        expect(hides(item("claude:c", .error, ago: 3 * hour), 2 * hour), "a failed turn past the limit hides")
        expect(!hides(item("claude:d", .working, ago: 30 * hour), 2 * hour), "working never hides")
        expect(!hides(item("claude:e", .waiting, ago: 30 * hour), 2 * hour), "waiting for approval never hides")
        expect(!hides(item("claude:f", .unknown, ago: 30 * hour), 2 * hour), "unknown state is not called idle")
        expect(!hides(item("claude:g", .idle, ago: 30 * hour, subagent: true), 2 * hour), "a running subagent keeps it")
        expect(!hides(item("claude:h", .idle, ago: 30 * hour), 0), "永不清理 hides nothing")
        expect(!hides(item("demo-1", .idle, ago: 30 * hour), 2 * hour), "demo rows are left alone")

        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: SessionStore.idleTimeoutKey)
        let store = SessionStore(demo: false)
        store.sessions = [item("claude:old", .idle, ago: 3 * hour), item("claude:new", .idle, ago: 60), item("codex-live:quiet", .idle, ago: 11 * 60)]
        expect(store.visibleSessions.map(\.id) == ["claude:new"], "default 2 hours hides the old row; got \(store.visibleSessions.map(\.id))")
        expect(store.sessions.count == 3, "the hidden rows stay in the store")
        // Its next activity brings it back.
        store.sessions[0].status = .working; store.sessions[0].updatedAt = now
        expect(store.visibleSessions.count == 2, "new activity shows it again")
        store.sessions[2].updatedAt = now
        expect(store.visibleSessions.count == 3, "a hidden Codex comes back on activity too")
        store.sessions[2].updatedAt = now.addingTimeInterval(-11 * 60)
        store.sessions[0].status = .idle; store.sessions[0].updatedAt = now.addingTimeInterval(-31 * 60)
        defaults.set(1800.0, forKey: SessionStore.idleTimeoutKey); store.refreshVisible()
        expect(store.visibleSessions.map(\.id) == ["claude:new"], "a shorter limit applies on refresh")
        defaults.set(0.0, forKey: SessionStore.idleTimeoutKey); store.refreshVisible()
        expect(store.visibleSessions.count == 2, "永不清理 shows everything")
        defaults.removeObject(forKey: SessionStore.idleTimeoutKey)

        // Codex rows are rebuilt from its logs every few seconds, and must keep showing a pending card.
        let cx = SessionStore(demo: false)
        cx.syncCodexLive([SessionItem(id: SessionStore.codexLivePrefix + "t1", title: "虚构", agent: "Codex", status: .working, detail: "", updatedAt: now)])
        cx.setCodexWaiting(["t1"])
        expect(cx.sessions.first?.status == .waiting && cx.sessions.first?.detail == "等待审批", "a Codex row shows its pending card")
        cx.syncCodexLive([SessionItem(id: SessionStore.codexLivePrefix + "t1", title: "虚构", agent: "Codex", status: .working, detail: "", updatedAt: now.addingTimeInterval(-30 * 60))])
        expect(cx.sessions.first?.status == .waiting, "the next log scan does not overwrite it")
        expect(cx.visibleSessions.count == 1, "waiting never hides, however old the log")
        cx.setCodexWaiting([])
        expect(cx.sessions.first?.status == .working, "the card ending restores what the log says")
        // A killed agent sends no SessionEnd; its process going away must remove the row.
        let live = SessionStore(demo: false)
        live.observeAgent(source: "dsh", name: "DSH", sessionID: "a", event: "UserPromptSubmit", cwd: nil, pid: getpid())
        live.observeAgent(source: "dsh", name: "DSH", sessionID: "b", event: "UserPromptSubmit", cwd: nil, pid: 2_000_000_000)
        live.observeAgent(source: "opencode", name: "OpenCode", sessionID: "c", event: "UserPromptSubmit", cwd: nil)
        live.removeRowsOfDeadAgents()
        expect(Set(live.sessions.map(\.id)) == ["dsh:a", "opencode:c"], "only the dead process's row goes; got \(live.sessions.map(\.id))")

        print(failures == 0 ? "idle session hide checks passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
