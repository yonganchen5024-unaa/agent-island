// Runs the real locator on the real Claude sessions and prints only the terminal device and the host
// app. It reads the pid from the registry's file names, and switches nothing.
import AppKit
let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
for file in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where file.hasSuffix(".json") {
    guard let pid = Int32(file.dropLast(5)), ProcessLookup.system.parent(pid) != nil else { continue }
    let host = SessionJump.host(of: pid)
    print(host.tty ?? "no-tty", host.bundleID ?? "no-host", SessionJump.script(for: host.bundleID ?? "") != nil ? "precise" : "app-only")
}
