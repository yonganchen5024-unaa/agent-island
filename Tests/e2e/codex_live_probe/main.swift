// Runs the real Codex locator on this Mac. Prints only status and shape, never names, paths or text.
import Foundation
var names = CodexThreadNames()
let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
let observed = try CodexLiveTracker(root: home.appendingPathComponent("sessions"), discovery: CodexProcessDiscovery()).snapshot().sessions
let rows = CodexLiveRows.rows(from: observed, names: names.current(file: home.appendingPathComponent("session_index.jsonl")), now: Date())
print("held rollouts:", observed.count, "children skipped:", observed.filter(\.isChild).count, "rows:", rows.count)
for row in rows {
    print("status:", row.status.rawValue, "pid:", row.pid != nil, "named:", names.current(file: home.appendingPathComponent("session_index.jsonl"))[String(row.id.dropFirst(CodexLiveRows.prefix.count))] != nil, "jump:", row.jumpURL != nil ? "codex://threads" : "terminal")
}
