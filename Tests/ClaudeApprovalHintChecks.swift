// Compile with ClaudeApprovalHint.swift. Fictional commands only.
@main struct ClaudeApprovalHintChecks {
    static func hint(_ command: String, mode: String? = "bypassPermissions", tool: String = "Bash") -> ClaudeApprovalHint? {
        ClaudeApprovalHint.make(toolName: tool, command: command, permissionMode: mode)
    }
    static func statements(_ command: String) -> [String] { hint(command)?.removals.map(\.statement) ?? [] }

    static func main() {
        // The shape behind the real requests: a variable built from another, in a multi-line script.
        let script = """
        bash -c '
        S=/private/tmp/demo/scratch
        C=~/build/demo; K=$C/key.tmp
        rm -f "$K"
        W=$S/diff; rm -rf $W; mkdir -p $W/a; cd $W; git init -q .
        '
        grep -c x ~/build/demo/log | head -1
        """
        let found = hint(script)!
        precondition(found.askedDespiteBypass && found.title.contains("小岛推断"))
        precondition(found.removals.map(\.statement) == ["rm -f \"$K\"", "rm -rf $W"], "\(found.removals)")
        precondition(found.removals[0].values == ["K=~/build/demo/key.tmp"], "\(found.removals[0].values)")
        precondition(found.removals[1].values == ["W=/private/tmp/demo/scratch/diff"], "\(found.removals[1].values)")

        // It says nothing when the condition does not hold.
        precondition(hint("rm -rf build") == nil, "no inline script")
        precondition(hint("bash -c 'echo hello'") == nil, "no deletion")
        precondition(hint("bash ./run.sh") == nil, "a script file cannot be read from here")
        precondition(hint("bash -c 'rm -rf x'", tool: "Write") == nil, "other tools")
        precondition(ClaudeApprovalHint.make(toolName: "Bash", command: nil, permissionMode: nil) == nil)
        precondition(hint("bash -c 'echo \"please rm -rf nothing\"'") == nil, "words inside a string run nothing")
        precondition(hint("bash -c 'echo rm x'") == nil, "an argument named rm")
        precondition(hint("bash -c 'cat <<EOF\nrm -rf /\nEOF\necho done'") == nil, "heredoc body runs nothing")
        precondition(hint("bash -c '# rm -rf /\necho done'") == nil, "comment")
        precondition(hint("echo 'bash -c rm' > note.txt") == nil, "text about it")

        // Every way of writing it that was seen or is common.
        for shell in ["bash -c", "sh -c", "zsh -c", "bash -lc", "bash -e -c", "/bin/bash -c", "env bash -c"] {
            precondition(statements("\(shell) 'rm -rf x'") == ["rm -rf x"], shell)
        }
        precondition(statements("bash -c \"rm -rf x\"") == ["rm -rf x"])
        precondition(statements("bash -c $'rm -rf x\\nls'") == ["rm -rf x"])
        precondition(statements("cd /tmp/demo && bash -c 'ls; rm -f a && echo b' | tail -1") == ["rm -f a"])
        precondition(statements("bash -c 'if true; then rm -f a; fi'") == ["rm -f a"])
        precondition(statements("bash -c 'for f in a b; do rm \"$f\"; done'") == ["rm \"$f\""])
        precondition(statements("bash -c 'ls | xargs rm -f'") == ["xargs rm -f"])
        precondition(statements("bash -c 'find . -name a -delete'") == ["find . -name a -delete"])
        precondition(statements("bash -c 'find . -exec rm {} +'") == ["find . -exec rm {} +"])
        precondition(statements("bash -c 'X=$(rm -f a; pwd); echo $X'") == ["rm -f a"])
        precondition(statements("bash -c 'echo \"$(rm -f a)\"'") == ["rm -f a"])
        precondition(statements("bash -c 'rm -f a 2>&1'") == ["rm -f a 2>&1"])
        precondition(statements("bash -c 'bash -c \"rm -f a\"'") == ["rm -f a"], "nested")
        precondition(statements("bash -c 'cat <<EOF\nnothing\nEOF\nrm -f a'") == ["rm -f a"], "after a heredoc")
        precondition(statements("bash -c 'echo \"it'\\''s\"; rm -f a'") == ["rm -f a"], "the usual quote trick")
        // A deletion outside the script belongs in the list once the script deletes too.
        precondition(statements("rm -f out; bash -c 'rm -f in'") == ["rm -f out", "rm -f in"])

        // Variables: what the person needs in order to judge.
        let variable = { (command: String) in hint(command)!.removals[0].values }
        precondition(variable("bash -c 'rm -rf \"$NOPE\"'") == ["NOPE 未在脚本中赋值"])
        precondition(variable("bash -c 'A=/x; B=${A}/y; C=\"$B/z\"; rm -rf \"${C:?}\"'") == ["C=/x/y/z"])
        precondition(variable("bash -c 'D=$(mktemp -d); rm -rf $D'") == ["D=$(mktemp -d)"], "unknown until it runs")
        precondition(variable("bash -c 'for f in a b; do rm \"$f\"; done'") == ["f=（for 循环的值）"])
        precondition(variable("bash -c 'A=/one; rm -f $A; A=/two'") == ["A=/one"], "the value at that point")
        precondition(variable("bash -c 'A=$A/x; rm -f $A'").count == 1, "a loop in the values ends")
        precondition(variable("bash -c 'export E=/x; rm -f $E'") == ["E=/x"])
        precondition(variable("Z=/outer bash -c 'rm -f $Z'") == ["Z=/outer"])
        precondition(variable("bash -c 'rm -f $A $B $C $D $E'").count == ClaudeApprovalHint.maxValues)

        // The list stays short, and repeats are one line.
        let many = (0..<9).map { "rm -f f\($0)" }.joined(separator: "; ")
        let long = hint("bash -c '\(many)'")!
        precondition(long.removals.count == ClaudeApprovalHint.limit && long.hidden == 3 && long.hiddenText!.contains("3"))
        precondition(hint("bash -c 'rm -f a; rm -f a'")!.removals.count == 1 && hint("bash -c 'rm -f a; rm -f a'")!.hidden == 0)
        precondition(hint("bash -c 'rm -f a'")!.hiddenText == nil)
        precondition(hint("bash -c 'rm -f a'")!.estimatedHeight < long.estimatedHeight)

        // Outside bypass mode any command can ask, so no cause is claimed.
        let plain = hint("bash -c 'rm -f a'", mode: "default")!
        precondition(!plain.askedDespiteBypass && !plain.title.contains("Claude"))
        precondition(!hint("bash -c 'rm -f a'", mode: nil)!.askedDespiteBypass)

        // A command cannot disguise itself on the card.
        let disguised = hint("bash -c 'rm -rf \u{202E}gpj.x'")!.removals[0].statement
        precondition(disguised == "rm -rf \\u{202E}gpj.x", disguised)
        precondition(!hint("bash -c 'A=$(printf \"\u{200B}\"); rm -f $A'")!.removals[0].values[0].contains("\u{200B}"))

        // Broken and oversized input ends cleanly.
        for broken in ["bash -c", "bash -c '", "bash -c 'rm", "bash -c \"$(", "bash -c '$(rm", "bash -c `", "\\", "<<", "bash -c 'x <<E", "$(", "#", "bash -c 'rm \\"] {
            _ = hint(broken)
        }
        precondition(hint("bash -c 'rm -f a'" + String(repeating: " ", count: ClaudeApprovalHint.maxInput)) == nil)
        print("ClaudeApprovalHint checks passed")
    }
}
