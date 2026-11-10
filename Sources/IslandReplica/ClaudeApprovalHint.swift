import CoreGraphics
import Foundation

/// What a shell script says it will delete, read from its text for the person deciding.
/// Display only: nothing here can produce or change a decision, and the complete input stays on the
/// card. Claude does not tell hooks why it asked, so the card says this reading is the island's own.
struct ClaudeApprovalHint: Equatable {
    struct Removal: Equatable {
        let statement: String
        /// "NAME=value" for each variable it uses, inner variables filled in where the script sets them.
        let values: [String]
    }

    let removals: [Removal]
    /// Removals found beyond `limit`.
    let hidden: Int
    /// In this mode Claude asks only for its own safety checks, so the cause can be named, as a guess.
    let askedDespiteBypass: Bool

    static let limit = 6
    static let maxValues = 3
    static let maxInput = 256 * 1024

    var title: String {
        askedDespiteBypass ? "可能是 Claude 的删除检查（小岛推断，非 Claude 原话）" : "脚本里有删除操作（小岛从命令文本读出）"
    }
    static let subtitle = "脚本中找到的删除操作，可能不全："
    var hiddenText: String? { hidden > 0 ? "还有 \(hidden) 处，见下方完整命令" : nil }

    /// The panel grows by this much, so the buttons stay in view. Every row is a single line.
    var estimatedHeight: CGFloat {
        let rows = removals.reduce(CGFloat(0)) { $0 + 15 + CGFloat($1.values.count) * 13 }
        return 16 + 16 + 14 + rows + (hidden > 0 ? 14 : 0) + 9
    }

    /// Nil unless a shell is handed a script with -c and that script deletes something.
    static func make(toolName: String, command: String?, permissionMode: String?) -> ClaudeApprovalHint? {
        guard toolName == "Bash", let command, command.utf8.count <= maxInput else { return nil }
        var scan = ShellScan()
        scan.read(command)
        guard scan.inlineDeletes else { return nil }
        var unique: [Removal] = []
        for removal in scan.removals where !unique.contains(removal) { unique.append(removal) }
        return ClaudeApprovalHint(
            removals: Array(unique.prefix(limit)), hidden: max(0, unique.count - limit),
            askedDespiteBypass: permissionMode == "bypassPermissions")
    }
}

/// A small reader for the parts of shell text the hint needs. It is not a shell: anything it cannot
/// follow simply goes unlisted, which is why the card says the list may be incomplete.
private struct ShellScan {
    private(set) var removals: [ClaudeApprovalHint.Removal] = []
    private(set) var inlineDeletes = false

    private static let shells: Set<String> = ["bash", "sh", "zsh", "dash", "ksh"]
    private static let deleters: Set<String> = ["rm", "rmdir"]
    private static let prefixes: Set<String> = [
        "then", "do", "else", "elif", "if", "while", "until", "!", "{", "time", "nohup", "exec", "command", "builtin", "sudo", "doas", "env",
    ]
    private static let declarers: Set<String> = ["export", "local", "readonly", "declare", "typeset"]
    private static let variable = try! NSRegularExpression(pattern: #"\$\{?([A-Za-z_][A-Za-z0-9_]*)"#)
    private static let reference = try! NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)[^}]*\}|\$([A-Za-z_][A-Za-z0-9_]*)"#)

    mutating func read(_ text: String) {
        read(text, inherited: [:], depth: 0, inline: false)
    }

    private mutating func read(_ text: String, inherited: [String: String], depth: Int, inline: Bool) {
        guard depth <= 4 else { return }
        var assigned = inherited
        for statement in Self.statements(of: text) {
            let words = Self.words(of: statement)
            record(words, into: &assigned)
            var index = 0
            while index < words.count, Self.prefixes.contains(words[index]) || Self.isAssignment(words[index]) { index += 1 }
            guard index < words.count else { continue }
            let tail = Array(words[index...])
            if deletes(tail) {
                if inline { inlineDeletes = true }
                removals.append(.init(statement: Self.visible(Self.withoutKeywords(statement)), values: Self.values(in: statement, assigned: assigned)))
            } else if let script = Self.inlineScript(tail) {
                read(script, inherited: assigned, depth: depth + 1, inline: true)
            }
        }
    }

    private func deletes(_ words: [String]) -> Bool {
        let names = words.map(Self.commandName)
        guard let first = names.first else { return false }
        if Self.deleters.contains(first) { return true }
        if first == "xargs" { return names.dropFirst().contains { Self.deleters.contains($0) } }
        if first == "find" {
            if names.contains("-delete") { return true }
            for (index, name) in names.enumerated() where ["-exec", "-execdir", "-ok", "-okdir"].contains(name) {
                if index + 1 < names.count, Self.deleters.contains(names[index + 1]) { return true }
            }
        }
        return false
    }

    private func record(_ words: [String], into assigned: inout [String: String]) {
        guard let first = words.first else { return }
        if first == "for", words.count > 1 { assigned[words[1]] = "（for 循环的值）"; return }
        let start = Self.declarers.contains(first) || Self.prefixes.contains(first) ? 1 : 0
        for word in words.dropFirst(start) {
            guard Self.isAssignment(word), let equals = word.firstIndex(of: "=") else { break }
            let name = word[..<equals].replacingOccurrences(of: "+", with: "")
            assigned[name] = Self.unquoted(String(word[word.index(after: equals)...]))
        }
    }

    // MARK: Pure text helpers

    /// `then rm -f a` reads better as `rm -f a`. Prefixes that change what runs, like sudo, stay.
    private static func withoutKeywords(_ statement: String) -> String {
        var text = Substring(statement)
        while let word = text.split(whereSeparator: \.isWhitespace).first, ["then", "do", "else", "elif", "if", "while", "until", "!", "{"].contains(String(word)) {
            text = text[word.endIndex...].drop(while: \.isWhitespace)
        }
        return String(text)
    }

    private static func isAssignment(_ word: String) -> Bool {
        word.range(of: #"^[A-Za-z_][A-Za-z0-9_]*\+?="#, options: .regularExpression) != nil
    }

    private static func commandName(_ word: String) -> String {
        (unquoted(word) as NSString).lastPathComponent
    }

    /// The script of `bash -c '...'`, `sh -lc "..."` and the like.
    private static func inlineScript(_ words: [String]) -> String? {
        guard let first = words.first, shells.contains(commandName(first)) else { return nil }
        var index = 1
        var sawC = false
        while index < words.count, words[index].hasPrefix("-") {
            if !words[index].hasPrefix("--"), words[index].contains("c") { sawC = true }
            index += 1
        }
        return sawC && index < words.count ? unquoted(words[index]) : nil
    }

    private static func values(in statement: String, assigned: [String: String]) -> [String] {
        let range = NSRange(statement.startIndex..., in: statement)
        var names: [String] = []
        for match in variable.matches(in: statement, range: range) {
            if let found = Range(match.range(at: 1), in: statement), !names.contains(String(statement[found])) {
                names.append(String(statement[found]))
            }
        }
        return names.prefix(ClaudeApprovalHint.maxValues).map { name in
            guard let value = assigned[name] else { return visible("\(name) 未在脚本中赋值") }
            return visible("\(name)=\(expand(value, assigned: assigned, depth: 0))")
        }
    }

    private static func expand(_ value: String, assigned: [String: String], depth: Int) -> String {
        guard depth < 6 else { return value }
        var result = ""
        var cursor = value.startIndex
        for match in reference.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let whole = Range(match.range, in: value) else { continue }
            let group = match.range(at: 1).location != NSNotFound ? 1 : 2
            guard let nameRange = Range(match.range(at: group), in: value) else { continue }
            result += value[cursor..<whole.lowerBound]
            if let inner = assigned[String(value[nameRange])] {
                result += expand(inner, assigned: assigned, depth: depth + 1)
            } else {
                result += value[whole]
            }
            cursor = whole.upperBound
        }
        return result + value[cursor...]
    }

    /// Control and direction-changing characters would let a command look like something else.
    private static func visible(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\t" || scalar == "\r" { out.append(" "); continue }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned:
                out.append(contentsOf: "\\u{\(String(scalar.value, radix: 16, uppercase: true))}".unicodeScalars)
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    private static func unquoted(_ word: String) -> String {
        let chars = Array(word)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "'" {
                i += 1
                while i < chars.count, chars[i] != "'" { out.append(chars[i]); i += 1 }
                i += 1
            } else if c == "$", i + 1 < chars.count, chars[i + 1] == "'" {
                i += 2
                while i < chars.count, chars[i] != "'" {
                    if chars[i] == "\\", i + 1 < chars.count {
                        i += 1
                        switch chars[i] { case "n": out.append("\n"); case "t": out.append("\t"); default: out.append(chars[i]) }
                    } else { out.append(chars[i]) }
                    i += 1
                }
                i += 1
            } else if c == "\"" {
                i += 1
                while i < chars.count, chars[i] != "\"" {
                    if chars[i] == "\\", i + 1 < chars.count, "\"\\$`".contains(chars[i + 1]) { i += 1 }
                    out.append(chars[i]); i += 1
                }
                i += 1
            } else if c == "\\", i + 1 < chars.count {
                out.append(chars[i + 1]); i += 2
            } else {
                out.append(c); i += 1
            }
        }
        return out
    }

    private static func words(of statement: String) -> [String] {
        let chars = Array(statement)
        var result: [String] = []
        var current = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                if !current.isEmpty { result.append(current); current = "" }
                i += 1
            } else if c == "'" || c == "\"" || c == "`" {
                let end = closing(chars, from: i)
                current += String(chars[i..<end]); i = end
            } else if c == "$", i + 1 < chars.count, chars[i + 1] == "(" {
                let end = closingParen(chars, from: i + 1)
                current += String(chars[i..<end]); i = end
            } else if c == "\\", i + 1 < chars.count {
                current += String(chars[i...(i + 1)]); i += 2
            } else {
                current.append(c); i += 1
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// The index just past the string that opens at `start`.
    private static func closing(_ chars: [Character], from start: Int) -> Int {
        let quote = chars[start]
        var i = start + 1
        while i < chars.count {
            if quote == "\"", chars[i] == "\\" { i += 2; continue }
            if chars[i] == quote { return i + 1 }
            i += 1
        }
        return chars.count
    }

    /// The index just past the `)` matching the `$(` whose `(` is at `open`.
    private static func closingParen(_ chars: [Character], from open: Int) -> Int {
        var depth = 0
        var i = open
        while i < chars.count {
            let c = chars[i]
            if c == "'" || c == "\"" { i = closing(chars, from: i); continue }
            if c == "\\" { i += 2; continue }
            if c == "(" { depth += 1 }
            if c == ")" { depth -= 1; if depth == 0 { return i + 1 } }
            i += 1
        }
        return chars.count
    }

    /// Commands in order. Heredoc bodies and comments are left out, since they run nothing here;
    /// command substitutions are read as commands too. Quotes span lines, as they do in a shell.
    private static func statements(of text: String, depth: Int = 0) -> [String] {
        let chars = Array(text)
        var result: [String] = []
        var current = ""
        var terminators: [String] = []
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
            current = ""
        }
        func substitution(_ inner: String) {
            if depth < 4 { result += statements(of: inner, depth: depth + 1) }
        }
        /// Commands substituted inside a double-quoted string run as well.
        func scanQuoted(_ range: Range<Int>) {
            var j = range.lowerBound
            while j < range.upperBound {
                if chars[j] == "\\" { j += 2; continue }
                if chars[j] == "$", j + 1 < range.upperBound, chars[j + 1] == "(" {
                    let end = min(closingParen(chars, from: j + 1), range.upperBound)
                    if end - 1 > j + 2 { substitution(String(chars[(j + 2)..<(end - 1)])) }
                    j = end; continue
                }
                j += 1
            }
        }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                if i + 1 < chars.count, chars[i + 1].isNewline { current.append(" ") }
                else { current += String(chars[i..<min(i + 2, chars.count)]) }
                i += 2
            case "'":
                let end = closing(chars, from: i)
                current += String(chars[i..<end]); i = end
            case "\"":
                let end = closing(chars, from: i)
                scanQuoted(i..<end)
                current += String(chars[i..<end]); i = end
            case "$" where i + 1 < chars.count && chars[i + 1] == "(":
                let end = closingParen(chars, from: i + 1)
                let arithmetic = i + 2 < chars.count && chars[i + 2] == "("
                if !arithmetic, end - 1 > i + 2 { substitution(String(chars[(i + 2)..<(end - 1)])) }
                current += String(chars[i..<end]); i = end
            case "`":
                let end = closing(chars, from: i)
                if end - 1 > i + 1 { substitution(String(chars[(i + 1)..<(end - 1)])) }
                current += String(chars[i..<end]); i = end
            case "#" where current.isEmpty || current.last!.isWhitespace:
                while i < chars.count, !chars[i].isNewline { i += 1 }
            case "<" where i + 1 < chars.count && chars[i + 1] == "<" && !(i + 2 < chars.count && chars[i + 2] == "<"):
                var j = i + 2
                if j < chars.count, chars[j] == "-" { j += 1 }
                while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
                let start = j
                while j < chars.count, !chars[j].isWhitespace, !";|&()<>".contains(chars[j]) { j += 1 }
                let name = unquoted(String(chars[start..<j]))
                if !name.isEmpty { terminators.append(name) }
                current += String(chars[i..<j]); i = j
            case _ where c.isNewline:
                flush()
                i += 1
                while let terminator = terminators.first {
                    guard i < chars.count else { terminators.removeAll(); break }
                    var end = i
                    while end < chars.count, !chars[end].isNewline { end += 1 }
                    let line = String(chars[i..<end]).trimmingCharacters(in: .whitespaces)
                    i = min(end + 1, chars.count)
                    if line == terminator { terminators.removeFirst() }
                }
            case ";", "|", "(", ")":
                flush(); i += 1
            case "&":
                let redirect = current.last == ">" || current.last == "<" || (i + 1 < chars.count && chars[i + 1] == ">")
                if redirect { current.append(c) } else { flush() }
                i += 1
            default:
                current.append(c); i += 1
            }
        }
        flush()
        return result
    }
}
