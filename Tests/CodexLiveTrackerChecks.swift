import Foundation
struct FixtureDiscovery: CodexOpenFileDiscovering {
    let files: [CodexOpenFile]; let complete: Bool
    func discover() throws -> CodexOpenFileSnapshot { CodexOpenFileSnapshot(files:files,complete:complete) }
}
@main struct Check {
    static func main() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = temp.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:temp) }
        func file(_ dir: URL, _ name: String, _ data: String) throws -> String {
            let path = dir.appendingPathComponent(name); try data.write(to:path,atomically:true,encoding:.utf8); return path.path
        }
        let meta = #"{"type":"session_meta","payload":{"id":"fixture","cwd":"/private/not-displayed"}}"# + "\n"
        let start = #"{"type":"event_msg","payload":{"type":"task_started"}}"# + "\n"
        let finish = #"{"type":"event_msg","payload":{"type":"task_complete"}}"# + "\n"
        let path = try file(root,"one.jsonl",meta+start+finish+#"{"type":"event_msg","payload":{"type":"task_started"}}"#)
        let outsider = try file(temp,"outside.jsonl",meta+start)
        let fixture = FixtureDiscovery(files:[CodexOpenFile(pid:10,path:path),CodexOpenFile(pid:11,path:path),CodexOpenFile(pid:12,path:outsider)],complete:true)
        let snap = try CodexLiveTracker(root:root,discovery:fixture).snapshot()
        precondition(snap.sessions.count == 1 && snap.sessions[0].sessionID == "fixture")
        precondition(snap.sessions[0].associatedPIDs == Set([10,11]) && snap.sessions[0].lastRecordedTurn == .completed)
        precondition(snap.sessions[0].currentState == .unknown && snap.openFileDiscoveryComplete && !snap.lifecycleCoverageComplete)
        let failed = FixtureDiscovery(files:[CodexOpenFile(pid:10,path:root.appendingPathComponent("missing.jsonl").path)],complete:true)
        let partial = try CodexLiveTracker(root:root,discovery:failed).snapshot()
        precondition(!partial.openFileDiscoveryComplete && partial.sessions.isEmpty)
        print("fixture discovery, root boundary, duplicate holders, partial event, unknown state: PASS")
    }
}
