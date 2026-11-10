import Foundation

@main struct CodexRolloutReaderChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("island-rollout-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ name: String, _ content: String) throws {
            try content.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let meta = #"{"type":"session_meta","payload":{"id":"alpha","cwd":"/tmp/demo","extra":""# + String(repeating:"x",count:70000) + #""}}"#
        try write("alpha.jsonl", meta + "\n" + #"{"type":"event_msg","payload":{"type":"task_started"}}"# + "\n" + #"{"type":"event_msg","payload":{"type":"task_complete"}}"# + "\n" + #"{"type":"event_msg","payload":{"type":"task_started"}}"#)
        try write("beta.jsonl", #"{"type":"session_meta","payload":{"id":"beta"}}"# + "\n" + #"{"type":"event_msg","payload":{"type":"task_started"}}"# + "\n")
        try write("child.jsonl", #"{"type":"session_meta","payload":{"id":"child","parent_thread_id":"alpha"}}"# + "\n")
        try write("incomplete.jsonl", #"{"type":"session_meta","payload":{"id":"partial"}}"# + "\n" + #"{"type":"event_msg","payload":{"type":"task_started"}}"#)
        let store = SessionStore(demo: false)
        let reader = CodexRolloutReader(store: store, root: root)
        reader.start()
        for _ in 0..<60 { if store.sessions.count == 3 { break }; try await Task.sleep(nanoseconds:100_000_000) }
        precondition(store.sessions.count == 3, "expected 3 rows, got \(store.sessions.count)")
        let alpha = store.sessions.first { $0.id == "rollout:alpha" }!
        let beta = store.sessions.first { $0.id == "rollout:beta" }!
        let partial = store.sessions.first { $0.id == "rollout:partial" }!
        precondition(alpha.status == .unknown && alpha.detail.contains("已结束"), "must ignore incomplete trailing task_started")
        precondition(beta.status == .unknown && beta.detail.contains("已开始"), "recent logs do not establish a live process")
        precondition(partial.status == .unknown && !partial.detail.contains("已开始"), "ignore partial trailing event")
        precondition(!store.sessions.contains { $0.id == "rollout:child" })
        reader.stop(); precondition(store.sessions.isEmpty)
        print("Codex rollout isolated lifecycle, partial records, long header, stop: PASS")
    }
}
