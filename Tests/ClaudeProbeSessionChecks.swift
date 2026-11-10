// Compile with AgentUsageReader.swift. Fictional registry entries in a temporary folder only.
import Foundation

@main struct Check {
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-checks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        ClaudeProbeSessions.registry = dir
        func entry(_ pid: Int, _ id: String, _ entrypoint: String?) throws {
            var object: [String: Any] = ["pid": pid, "sessionId": id, "startedAt": 0]
            if let entrypoint { object["entrypoint"] = entrypoint }
            try JSONSerialization.data(withJSONObject: object).write(to: dir.appendingPathComponent("\(pid).json"))
        }
        var failures = 0
        func expect(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL", what) } }

        let own = UUID().uuidString.lowercased()
        ClaudeProbeSessions.mark(own)
        expect(ClaudeProbeSessions.isProbe(own.uppercased()), "own probe marked before its registry entry exists")

        let hud = "11111111-1111-4111-8111-111111111111", cli = "22222222-2222-4222-8222-222222222222"
        let late = "33333333-3333-4333-8333-333333333333", bare = "44444444-4444-4444-8444-444444444444"
        try entry(101, hud, "agent-hud"); try entry(102, cli, "cli"); try entry(103, bare, nil)
        expect(ClaudeProbeSessions.isProbe(hud), "Agent HUD probe found in the registry")
        expect(!ClaudeProbeSessions.isProbe(cli), "an interactive session is a conversation")
        expect(!ClaudeProbeSessions.isProbe(bare), "an entry without entrypoint is a conversation")
        expect(!ClaudeProbeSessions.isProbe(late), "no entry yet: treated as a conversation")
        try entry(104, late, "agent-island")
        expect(ClaudeProbeSessions.isProbe(late), "a missing entry is not remembered, so a later probe entry is seen")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("101.json"))
        expect(ClaudeProbeSessions.isProbe(hud), "a probe stays known after its process exits, so its SessionEnd is dropped too")

        print(failures == 0 ? "probe session checks passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
