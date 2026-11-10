import Foundation
struct FakeClaudeProcesses: ClaudeProcessDiscovering {
    let paths: Set<String>
    func discover() throws -> ClaudeFileAssociations { ClaudeFileAssociations(paths:paths,complete:false) }
}
@main struct Check {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), dir = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let id = "6A23744F-577F-4DA6-9C19-66035CD2A001", path = dir.appendingPathComponent(id+".jsonl")
        let metadata = "{\"sessionId\":\"\(id)\",\"type\":\"user\",\"cwd\":\"/tmp/demo-project\",\"message\":\"private-do-not-copy\"}\n"
        let assistant = "{\"sessionId\":\"\(id)\",\"type\":\"assistant\"}\n"
        try (metadata+assistant+"{\"type\":\"user\"").write(to:path,atomically:true,encoding:.utf8)
        try "not json".write(to:dir.appendingPathComponent("random.jsonl"),atomically:true,encoding:.utf8)
        let store = SessionStore(demo:false)
        let reader = ClaudeSessionReader(store:store,root:root,discovery:FakeClaudeProcesses(paths:[path.path]))
        reader.start()
        for _ in 0..<60 { if store.sessions.count == 1 { break }; try await Task.sleep(nanoseconds:100_000_000) }
        precondition(store.sessions.count == 1)
        let row = store.sessions[0]
        precondition(row.id == "claude:"+id && row.title == "demo-project" && row.status == .unknown)
        precondition(row.detail.contains("助手输出") && row.detail.contains("关联进程") && !row.detail.contains("private-do-not-copy"))
        try (metadata+assistant+"{\"sessionId\":\"\(id)\",\"type\":\"system\"}\n").write(to:path,atomically:true,encoding:.utf8)
        for _ in 0..<75 { if store.sessions.first?.detail.contains("系统事件") == true { break }; try await Task.sleep(nanoseconds:100_000_000) }
        precondition(store.sessions.first?.detail.contains("系统事件") == true, "cache must invalidate when file changes")
        reader.stop(); precondition(store.sessions.isEmpty)
        try await Task.sleep(nanoseconds:200_000_000); precondition(store.sessions.isEmpty)
        print("Claude fixture: bounds, identity, private text exclusion, state, cache refresh, stop PASS")
    }
}
