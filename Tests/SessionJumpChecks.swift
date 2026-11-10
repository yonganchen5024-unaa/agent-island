import AppKit
// Compile with SessionJump.swift. Fictional processes. With a directory argument it also writes the
// scripts there, for osacompile to check their grammar against the real terminals' dictionaries.
@main struct SessionJumpChecks {
    static func table(_ rows: [Int32: (parent: Int32, name: String, app: String?)], tty: String? = "/dev/ttys001") -> ProcessLookup {
        ProcessLookup(parent: { rows[$0]?.parent }, name: { rows[$0]?.name }, tty: { rows[$0] == nil ? nil : tty }, app: { rows[$0]?.app })
    }
    static func main() {
        // The chain seen on the user's real sessions: claude < zsh < login < iTermServer < iTerm2.
        let normal = table([500: (400, "claude", nil), 400: (300, "zsh", nil), 300: (200, "login", nil), 200: (100, "iTermServer-3.7.7", nil), 100: (1, "iTerm2", SessionJump.iTerm)])
        precondition(SessionJump.host(of: 500, lookup: normal) == SessionHost(tty: "/dev/ttys001", bundleID: SessionJump.iTerm))
        // Also seen: a helper from an older iTerm2, whose parent is launchd.
        let orphan = table([500: (400, "claude", nil), 400: (300, "zsh", nil), 300: (200, "login", nil), 200: (1, "iTermServer-3.7.4", nil)])
        precondition(SessionJump.host(of: 500, lookup: orphan).bundleID == SessionJump.iTerm)
        // Terminal.app, and an app that cannot be scripted.
        let plain = table([500: (400, "claude", nil), 400: (100, "zsh", nil), 100: (1, "Terminal", SessionJump.terminal)])
        precondition(SessionJump.host(of: 500, lookup: plain).bundleID == SessionJump.terminal)
        let ghostty = table([500: (100, "claude", nil), 100: (1, "ghostty", "com.mitchellh.ghostty")])
        precondition(SessionJump.host(of: 500, lookup: ghostty).bundleID == "com.mitchellh.ghostty" && SessionJump.script(for: "com.mitchellh.ghostty") == nil)
        // tmux: the chain ends at launchd with no app. The device is still known.
        let tmux = table([500: (400, "claude", nil), 400: (1, "tmux", nil)])
        precondition(SessionJump.host(of: 500, lookup: tmux) == SessionHost(tty: "/dev/ttys001", bundleID: nil))
        // A vanished process, and a loop in a broken table, end cleanly.
        precondition(SessionJump.host(of: 999, lookup: normal) == SessionHost(tty: nil, bundleID: nil))
        let loop = table([500: (500, "claude", nil)])
        precondition(SessionJump.host(of: 500, lookup: loop).bundleID == nil)
        // The device goes to AppleScript as an argument, never into the script text, and only in this shape.
        precondition(SessionJump.ttyPath("ttys012") == "/dev/ttys012")
        for bad in ["??", "tty", "console", "ttys0\"; do shell", "../ttys001", "ttys 1"] { precondition(SessionJump.ttyPath(bad) == nil, bad) }
        for id in [SessionJump.iTerm, SessionJump.terminal] {
            let script = SessionJump.script(for: id)!
            precondition(script.contains("item 1 of argv") && !script.contains("/dev/") && script.contains(id))
            precondition(!script.contains("do shell script") && !script.contains("write text"), "only selects, never types")
        }
        // Results of the script.
        precondition(SessionJump.classify(status: 0, output: "found\n", errors: "") == .found)
        precondition(SessionJump.classify(status: 0, output: "missing\n", errors: "") == .missing)
        precondition(SessionJump.classify(status: 1, output: "", errors: "execution error: Not authorized (-1743)") == .denied)
        precondition(SessionJump.classify(status: 1, output: "", errors: "execution error: (-600)") == .failed)
        if CommandLine.arguments.count > 1 {
            for (name, id) in [("iterm", SessionJump.iTerm), ("terminal", SessionJump.terminal)] {
                try! SessionJump.script(for: id)!.write(toFile: CommandLine.arguments[1] + "/" + name + ".applescript", atomically: true, encoding: .utf8)
            }
        }
        print("SessionJumpChecks passed")
    }
}
