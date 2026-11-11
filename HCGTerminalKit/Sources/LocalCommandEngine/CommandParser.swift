import Foundation

/// A word after quote removal. `globbable` is false when any glob character was quoted.
public struct ShellWord: Hashable, Sendable {
    public var text: String
    public var globbable: Bool
}

public enum Redirection: Hashable, Sendable {
    case output(String, append: Bool)
    case input(String)
}

public struct SimpleCommand: Hashable, Sendable {
    public var words: [ShellWord]
    public var redirections: [Redirection]
    public var arguments: [String] { words.map(\.text) }
}

public struct Pipeline: Hashable, Sendable {
    public var commands: [SimpleCommand]
}

public enum ListConnector: Hashable, Sendable {
    case sequence   // ;
    case and        // &&
    case or         // ||
}

/// `a | b && c ; d` → [(a|b, &&), (c, ;), (d, ;)]
public struct CommandList: Hashable, Sendable {
    public var items: [(pipeline: Pipeline, connector: ListConnector)]

    public static func == (lhs: CommandList, rhs: CommandList) -> Bool {
        lhs.items.map(\.pipeline) == rhs.items.map(\.pipeline) && lhs.items.map(\.connector) == rhs.items.map(\.connector)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(items.map(\.pipeline))
    }
}

public enum ParseError: Error, LocalizedError, Equatable {
    case unterminatedQuote
    case unexpectedToken(String)
    case missingRedirectTarget

    public var errorDescription: String? {
        switch self {
        case .unterminatedQuote: "syntax error: unterminated quote"
        case .unexpectedToken(let t): "syntax error near unexpected token `\(t)'"
        case .missingRedirectTarget: "syntax error: missing redirection target"
        }
    }
}

/// A small POSIX-flavoured parser for the built-in command environment: quoting, escapes,
/// `$VAR` / `${VAR}` / `$?` expansion, `;`, `&&`, `||`, `|`, `<`, `>`, `>>` and comments.
/// It is not a full shell and does not pretend to be one.
public enum CommandParser {
    private enum Token: Equatable {
        case word(ShellWord)
        case op(String)
    }

    public static func parse(_ line: String, environment: [String: String] = [:], lastStatus: Int32 = 0) throws -> CommandList {
        let tokens = try tokenize(line, environment: environment, lastStatus: lastStatus)
        var items: [(Pipeline, ListConnector)] = []
        var pipeline: [SimpleCommand] = []
        var current = SimpleCommand(words: [], redirections: [])
        var index = 0

        func finishCommand(_ op: String) throws {
            guard !current.words.isEmpty || !current.redirections.isEmpty else { throw ParseError.unexpectedToken(op) }
            pipeline.append(current)
            current = SimpleCommand(words: [], redirections: [])
        }

        while index < tokens.count {
            switch tokens[index] {
            case .word(let word):
                current.words.append(word)
            case .op(let op):
                switch op {
                case "|":
                    try finishCommand(op)
                case ";", "&&", "||":
                    try finishCommand(op)
                    items.append((Pipeline(commands: pipeline), op == ";" ? .sequence : op == "&&" ? .and : .or))
                    pipeline = []
                case ">", ">>", "<":
                    index += 1
                    guard index < tokens.count, case .word(let target) = tokens[index] else { throw ParseError.missingRedirectTarget }
                    current.redirections.append(op == "<" ? .input(target.text) : .output(target.text, append: op == ">>"))
                default:
                    throw ParseError.unexpectedToken(op)
                }
            }
            index += 1
        }
        if case .op(let op) = tokens.last, op != ";" { throw ParseError.unexpectedToken("newline") }
        if !current.words.isEmpty || !current.redirections.isEmpty { pipeline.append(current) }
        if !pipeline.isEmpty { items.append((Pipeline(commands: pipeline), .sequence)) }
        return CommandList(items: items.map { (pipeline: $0.0, connector: $0.1) })
    }

    private static func tokenize(_ line: String, environment: [String: String], lastStatus: Int32) throws -> [Token] {
        var tokens: [Token] = []
        var text = ""
        var globbable = true
        var inWord = false
        let chars = Array(line)
        var i = 0

        func flush() {
            if inWord { tokens.append(.word(ShellWord(text: text, globbable: globbable))) }
            text = ""
            globbable = true
            inWord = false
        }

        func expandVariable(at position: inout Int) -> String {
            // `position` points at the character after `$`.
            guard position < chars.count else { return "$" }
            if chars[position] == "?" { position += 1; return String(lastStatus) }
            if chars[position] == "{" {
                guard let close = chars[position...].firstIndex(of: "}") else { return "$" }
                let name = String(chars[(position + 1)..<close])
                position = close + 1
                return environment[name] ?? ""
            }
            var name = ""
            while position < chars.count, chars[position].isLetter || chars[position].isNumber || chars[position] == "_" {
                name.append(chars[position])
                position += 1
            }
            return name.isEmpty ? "$" : (environment[name] ?? "")
        }

        while i < chars.count {
            let c = chars[i]
            switch c {
            case " ", "\t":
                flush()
                i += 1
            case "#" where !inWord:
                i = chars.count
            case "'":
                inWord = true
                guard let close = chars[(i + 1)...].firstIndex(of: "'") else { throw ParseError.unterminatedQuote }
                let quoted = String(chars[(i + 1)..<close])
                if quoted.contains(where: { "*?[".contains($0) }) { globbable = false }
                text += quoted
                i = close + 1
            case "\"":
                inWord = true
                i += 1
                var closed = false
                while i < chars.count {
                    let d = chars[i]
                    if d == "\"" { closed = true; i += 1; break }
                    if d == "\\", i + 1 < chars.count, "\"\\$`".contains(chars[i + 1]) {
                        text.append(chars[i + 1]); i += 2; continue
                    }
                    if d == "$" { i += 1; text += expandVariable(at: &i); continue }
                    if "*?[".contains(d) { globbable = false }
                    text.append(d)
                    i += 1
                }
                if !closed { throw ParseError.unterminatedQuote }
            case "\\":
                inWord = true
                if i + 1 < chars.count {
                    if "*?[".contains(chars[i + 1]) { globbable = false }
                    text.append(chars[i + 1])
                }
                i += 2
            case "$":
                inWord = true
                i += 1
                text += expandVariable(at: &i)
            case ";":
                flush(); tokens.append(.op(";")); i += 1
            case "|":
                flush()
                if i + 1 < chars.count, chars[i + 1] == "|" { tokens.append(.op("||")); i += 2 } else { tokens.append(.op("|")); i += 1 }
            case "&":
                flush()
                if i + 1 < chars.count, chars[i + 1] == "&" { tokens.append(.op("&&")); i += 2 } else { throw ParseError.unexpectedToken("&") }
            case ">":
                flush()
                if i + 1 < chars.count, chars[i + 1] == ">" { tokens.append(.op(">>")); i += 2 } else { tokens.append(.op(">")); i += 1 }
            case "<":
                flush(); tokens.append(.op("<")); i += 1
            default:
                inWord = true
                text.append(c)
                i += 1
            }
        }
        flush()
        return tokens
    }
}

/// Minimal glob matching (`*`, `?`, `[abc]`, `[a-z]`, `[!x]`) for a single path component.
public enum Glob {
    public static func hasPattern(_ text: String) -> Bool {
        text.contains(where: { "*?[".contains($0) })
    }

    public static func matches(_ name: String, pattern: String) -> Bool {
        matches(Array(name), 0, Array(pattern), 0)
    }

    private static func matches(_ s: [Character], _ si: Int, _ p: [Character], _ pi: Int) -> Bool {
        if pi == p.count { return si == s.count }
        switch p[pi] {
        case "*":
            var k = si
            while true {
                if matches(s, k, p, pi + 1) { return true }
                if k == s.count { return false }
                k += 1
            }
        case "?":
            return si < s.count && matches(s, si + 1, p, pi + 1)
        case "[":
            guard si < s.count, let close = p[(pi + 1)...].firstIndex(of: "]") else {
                return si < s.count && s[si] == "[" && matches(s, si + 1, p, pi + 1)
            }
            var set = Array(p[(pi + 1)..<close])
            var negate = false
            if let first = set.first, first == "!" || first == "^" { negate = true; set.removeFirst() }
            var found = false
            var j = 0
            while j < set.count {
                if j + 2 < set.count, set[j + 1] == "-" {
                    if set[j] <= s[si] && s[si] <= set[j + 2] { found = true }
                    j += 3
                } else {
                    if set[j] == s[si] { found = true }
                    j += 1
                }
            }
            return found != negate && matches(s, si + 1, p, close + 1)
        default:
            return si < s.count && s[si] == p[pi] && matches(s, si + 1, p, pi + 1)
        }
    }
}
