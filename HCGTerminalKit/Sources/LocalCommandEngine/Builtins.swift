import FileWorkspace
import Foundation
import TerminalCore

/// Mutable state a built-in command runs against. Owned by one session and only used
/// synchronously from that session's isolation domain.
public final class BuiltinContext {
    public let workspace: FileWorkspace
    public var cwd: WorkspacePath
    public var previousDirectory: WorkspacePath?
    public var environment: [String: String]
    public var stdin: Data?
    public var stdout = ""
    public var stderr = ""
    public var history: [String] = []
    /// Lines describing the session (mode, target, backend) for `session`.
    public var sessionDescription: [String] = []
    /// Text printed by `capabilities`.
    public var capabilityDescription: String = "Capability report not loaded yet."
    /// Describes why external commands are or are not available.
    public var externalCommandPolicy: String = ""
    public var clearRequested = false
    public var exitRequested = false
    public let registry: BuiltinRegistry

    public init(workspace: FileWorkspace, cwd: WorkspacePath = .home, environment: [String: String], registry: BuiltinRegistry) {
        self.workspace = workspace
        self.cwd = cwd
        self.environment = environment
        self.registry = registry
    }

    func resolve(_ path: String) throws -> WorkspacePath {
        try WorkspacePath(path, relativeTo: cwd, home: WorkspacePath(environment["HOME"] ?? "/home"))
    }

    func out(_ text: String) { stdout += text }
    func line(_ text: String) { stdout += text + "\n" }
    func error(_ command: String, _ message: String) { stderr += "\(command): \(message)\n" }

    func readInput(_ files: [String], command: String) -> [(name: String, text: String)]? {
        if files.isEmpty { return [("-", String(decoding: stdin ?? Data(), as: UTF8.self))] }
        var result: [(String, String)] = []
        for file in files {
            if file == "-" { result.append(("-", String(decoding: stdin ?? Data(), as: UTF8.self))); continue }
            do { result.append((file, try workspace.readText(resolve(file)))) } catch {
                self.error(command, error.localizedDescription)
                return nil
            }
        }
        return result
    }
}

public struct BuiltinCommand: Sendable {
    public let name: String
    public let usage: String
    public let summary: String
    let body: @Sendable (_ arguments: [String], _ context: BuiltinContext) -> Int32

    public init(_ name: String, _ usage: String, _ summary: String, _ body: @escaping @Sendable ([String], BuiltinContext) -> Int32) {
        self.name = name
        self.usage = usage
        self.summary = summary
        self.body = body
    }

    public func run(_ arguments: [String], _ context: BuiltinContext) -> Int32 { body(arguments, context) }
}

/// Splits `-abc` style flags from operands. `--` ends option parsing.
struct Flags {
    var set: Set<Character> = []
    var values: [Character: String] = [:]
    var operands: [String] = []

    init(_ arguments: [String], valued: Set<Character> = []) {
        var index = 0
        var parsing = true
        while index < arguments.count {
            let argument = arguments[index]
            if parsing, argument == "--" { parsing = false; index += 1; continue }
            if parsing, argument.hasPrefix("-"), argument.count > 1, Int(argument) == nil {
                let letters = Array(argument.dropFirst())
                for (offset, letter) in letters.enumerated() {
                    if valued.contains(letter) {
                        let rest = String(letters[(offset + 1)...])
                        if !rest.isEmpty { values[letter] = rest } else if index + 1 < arguments.count { index += 1; values[letter] = arguments[index] }
                        break
                    }
                    set.insert(letter)
                }
            } else if parsing, argument.hasPrefix("-"), let number = Int(argument.dropFirst()), number >= 0 {
                values["n"] = String(number) // `head -5`
            } else {
                operands.append(argument)
            }
            index += 1
        }
    }

    func has(_ flag: Character) -> Bool { set.contains(flag) }
}

public struct BuiltinRegistry: Sendable {
    public private(set) var commands: [String: BuiltinCommand] = [:]

    public init(_ commands: [BuiltinCommand]) {
        for command in commands { self.commands[command.name] = command }
    }

    public subscript(name: String) -> BuiltinCommand? { commands[name] }

    public var sortedNames: [String] { commands.keys.sorted() }

    /// All built-in commands of the local environment.
    public static let standard = BuiltinRegistry(StandardBuiltins.all)
}

enum StandardBuiltins {
    static let all: [BuiltinCommand] = [
        help, pwd, cd, ls, cat, echo, mkdir, rmdir, touch, rm, mv, cp, head, tail, wc, grep, find,
        du, sort, uniq, tee, basename, dirname, seq, env, export, unset, history, clear, date,
        whoami, uname, trueCommand, falseCommand, which, session, capabilities, exit,
    ]

    static let help = BuiltinCommand("help", "help [command]", "List built-in commands") { args, ctx in
        if let name = args.first {
            guard let command = ctx.registry[name] else { ctx.error("help", "no help for \(name)"); return 1 }
            ctx.line("\(command.usage)\n  \(command.summary)")
            return 0
        }
        ctx.line("\(ANSI.bold)HCG Terminal built-in commands\(ANSI.reset)")
        for name in ctx.registry.sortedNames {
            let command = ctx.registry[name]!
            ctx.line("  \(command.name.padding(toLength: 14, withPad: " ", startingAt: 0))\(command.summary)")
        }
        ctx.line("\nOperators: ;  &&  ||  |  >  >>  <   Quoting: '…' \"…\" \\   Variables: $NAME ${NAME} $?")
        if !ctx.externalCommandPolicy.isEmpty { ctx.line("\n" + ctx.externalCommandPolicy) }
        return 0
    }

    static let pwd = BuiltinCommand("pwd", "pwd", "Print the working directory") { _, ctx in
        ctx.line(ctx.cwd.string)
        return 0
    }

    static let cd = BuiltinCommand("cd", "cd [dir | - | ~]", "Change the working directory") { args, ctx in
        let target: WorkspacePath
        do {
            if args.first == "-" {
                guard let previous = ctx.previousDirectory else { ctx.error("cd", "OLDPWD not set"); return 1 }
                target = previous
                ctx.line(target.string)
            } else {
                target = try ctx.resolve(args.first ?? "~")
            }
        } catch { ctx.error("cd", error.localizedDescription); return 1 }
        guard ctx.workspace.exists(target) else { ctx.error("cd", "\(args.first ?? "~"): No such file or directory"); return 1 }
        guard ctx.workspace.isDirectory(target) else { ctx.error("cd", "\(args.first ?? "~"): Not a directory"); return 1 }
        ctx.previousDirectory = ctx.cwd
        ctx.cwd = target
        ctx.environment["PWD"] = target.string
        return 0
    }

    static let ls = BuiltinCommand("ls", "ls [-alh1] [path ...]", "List directory contents") { args, ctx in
        let flags = Flags(args)
        let operands = flags.operands.isEmpty ? ["."] : flags.operands
        var status: Int32 = 0
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        func size(_ bytes: Int64) -> String {
            flags.has("h") ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : String(bytes)
        }
        func render(_ items: [WorkspaceItem]) {
            if flags.has("l") {
                for item in items {
                    let kind = item.isDirectory ? "d" : "-"
                    let date = item.modified.map(formatter.string(from:)) ?? ""
                    let name = item.isDirectory ? "\(ANSI.blue)\(item.name)/\(ANSI.reset)" : item.name
                    ctx.line("\(kind) \(size(item.size).leftPad(10)) \(date.leftPad(12)) \(name)")
                }
            } else if flags.has("1") {
                for item in items { ctx.line(item.isDirectory ? "\(item.name)/" : item.name) }
            } else {
                let names = items.map { $0.isDirectory ? "\(ANSI.blue)\($0.name)/\(ANSI.reset)" : $0.name }
                if !names.isEmpty { ctx.line(names.joined(separator: "  ")) }
            }
        }
        for (index, operand) in operands.enumerated() {
            do {
                let path = try ctx.resolve(operand)
                if ctx.workspace.isDirectory(path) {
                    if operands.count > 1 { ctx.line((index > 0 ? "\n" : "") + "\(operand):") }
                    render(try ctx.workspace.list(path, includeHidden: flags.has("a")))
                } else {
                    render([try ctx.workspace.item(at: path)])
                }
            } catch {
                ctx.error("ls", error.localizedDescription)
                status = 1
            }
        }
        return status
    }

    static let cat = BuiltinCommand("cat", "cat [file ...]", "Print files") { args, ctx in
        guard let inputs = ctx.readInput(Flags(args).operands, command: "cat") else { return 1 }
        for input in inputs { ctx.out(input.text) }
        return 0
    }

    static let echo = BuiltinCommand("echo", "echo [-n] [text ...]", "Print text") { args, ctx in
        var words = args
        let noNewline = words.first == "-n"
        if noNewline { words.removeFirst() }
        ctx.out(words.joined(separator: " ") + (noNewline ? "" : "\n"))
        return 0
    }

    static let mkdir = BuiltinCommand("mkdir", "mkdir [-p] dir ...", "Create directories") { args, ctx in
        let flags = Flags(args)
        guard !flags.operands.isEmpty else { ctx.error("mkdir", "missing operand"); return 1 }
        var status: Int32 = 0
        for operand in flags.operands {
            do { try ctx.workspace.createDirectory(ctx.resolve(operand), intermediates: flags.has("p")) } catch {
                ctx.error("mkdir", error.localizedDescription); status = 1
            }
        }
        return status
    }

    static let rmdir = BuiltinCommand("rmdir", "rmdir dir ...", "Remove empty directories") { args, ctx in
        var status: Int32 = 0
        for operand in args {
            do {
                let path = try ctx.resolve(operand)
                guard ctx.workspace.isDirectory(path) else { throw WorkspaceError.notADirectory(path.string) }
                try ctx.workspace.remove(path, recursive: false)
            } catch { ctx.error("rmdir", error.localizedDescription); status = 1 }
        }
        return status
    }

    static let touch = BuiltinCommand("touch", "touch file ...", "Create files or update timestamps") { args, ctx in
        var status: Int32 = 0
        for operand in args {
            do { try ctx.workspace.touch(ctx.resolve(operand)) } catch { ctx.error("touch", error.localizedDescription); status = 1 }
        }
        return status
    }

    static let rm = BuiltinCommand("rm", "rm [-rf] path ...", "Remove files and directories") { args, ctx in
        let flags = Flags(args)
        let recursive = flags.has("r") || flags.has("R")
        guard !flags.operands.isEmpty else {
            if flags.has("f") { return 0 }
            ctx.error("rm", "missing operand"); return 1
        }
        var status: Int32 = 0
        for operand in flags.operands {
            do {
                let path = try ctx.resolve(operand)
                if path.isRoot || path == ctx.cwd || ctx.cwd.isDescendant(of: path) {
                    throw WorkspaceError.operationNotPermitted(operand)
                }
                if !ctx.workspace.exists(path), flags.has("f") { continue }
                if ctx.workspace.isDirectory(path), !recursive { throw WorkspaceError.isADirectory(operand) }
                try ctx.workspace.remove(path, recursive: recursive)
            } catch { ctx.error("rm", error.localizedDescription); status = 1 }
        }
        return status
    }

    static let mv = BuiltinCommand("mv", "mv source ... destination", "Move or rename") { args, ctx in
        transfer("mv", args, ctx) { try ctx.workspace.move($0, to: $1) }
    }

    static let cp = BuiltinCommand("cp", "cp [-r] source ... destination", "Copy files and directories") { args, ctx in
        let flags = Flags(args)
        return transfer("cp", flags.operands, ctx) { source, destination in
            if ctx.workspace.isDirectory(source), !(flags.has("r") || flags.has("R")) {
                throw WorkspaceError.isADirectory(source.string + " (use -r)")
            }
            try ctx.workspace.copy(source, to: destination)
        }
    }

    static func transfer(_ name: String, _ args: [String], _ ctx: BuiltinContext, _ action: (WorkspacePath, WorkspacePath) throws -> Void) -> Int32 {
        let operands = Flags(args).operands
        guard operands.count >= 2 else { ctx.error(name, "missing destination operand"); return 1 }
        do {
            let destination = try ctx.resolve(operands.last!)
            if operands.count > 2, !ctx.workspace.isDirectory(destination) {
                throw WorkspaceError.notADirectory(operands.last!)
            }
            for source in operands.dropLast() { try action(ctx.resolve(source), destination) }
            return 0
        } catch {
            ctx.error(name, error.localizedDescription)
            return 1
        }
    }

    static let head = BuiltinCommand("head", "head [-n count] [file ...]", "First lines") { args, ctx in
        let flags = Flags(args, valued: ["n"])
        let count = Int(flags.values["n"] ?? "10") ?? 10
        guard let inputs = ctx.readInput(flags.operands, command: "head") else { return 1 }
        for input in inputs {
            var lines = input.text.split(separator: "\n", omittingEmptySubsequences: false)
            if input.text.hasSuffix("\n") { lines.removeLast() }
            for line in lines.prefix(count) { ctx.line(String(line)) }
        }
        return 0
    }

    static let tail = BuiltinCommand("tail", "tail [-n count] [file ...]", "Last lines") { args, ctx in
        let flags = Flags(args, valued: ["n"])
        let count = Int(flags.values["n"] ?? "10") ?? 10
        guard let inputs = ctx.readInput(flags.operands, command: "tail") else { return 1 }
        for input in inputs {
            var lines = input.text.split(separator: "\n", omittingEmptySubsequences: false)
            if input.text.hasSuffix("\n") { lines.removeLast() }
            for line in lines.suffix(count) { ctx.line(String(line)) }
        }
        return 0
    }

    static let wc = BuiltinCommand("wc", "wc [-lwc] [file ...]", "Count lines, words and bytes") { args, ctx in
        let flags = Flags(args)
        let all = !flags.has("l") && !flags.has("w") && !flags.has("c")
        guard let inputs = ctx.readInput(flags.operands, command: "wc") else { return 1 }
        for input in inputs {
            var columns: [String] = []
            if all || flags.has("l") { columns.append(String(input.text.filter { $0 == "\n" }.count).leftPad(7)) }
            if all || flags.has("w") { columns.append(String(input.text.split(whereSeparator: { $0.isWhitespace }).count).leftPad(7)) }
            if all || flags.has("c") { columns.append(String(input.text.utf8.count).leftPad(7)) }
            ctx.line(columns.joined(separator: " ") + (input.name == "-" ? "" : " \(input.name)"))
        }
        return 0
    }

    static let grep = BuiltinCommand("grep", "grep [-invc] pattern [file ...]", "Search text (regular expressions)") { args, ctx in
        let flags = Flags(args)
        guard let pattern = flags.operands.first else { ctx.error("grep", "missing pattern"); return 2 }
        let files = Array(flags.operands.dropFirst())
        let options: NSRegularExpression.Options = flags.has("i") ? [.caseInsensitive] : []
        let regex = try? NSRegularExpression(pattern: pattern, options: options)
        guard let inputs = ctx.readInput(files, command: "grep") else { return 2 }
        var matched = false
        for input in inputs {
            var count = 0
            var lines = input.text.split(separator: "\n", omittingEmptySubsequences: false)
            if input.text.hasSuffix("\n") { lines.removeLast() }
            for (number, rawLine) in lines.enumerated() {
                let line = String(rawLine)
                let hit: Bool
                if let regex {
                    hit = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
                } else {
                    hit = flags.has("i") ? line.localizedCaseInsensitiveContains(pattern) : line.contains(pattern)
                }
                guard hit != flags.has("v") else { continue }
                matched = true
                count += 1
                if !flags.has("c") {
                    let prefix = (inputs.count > 1 ? "\(input.name):" : "") + (flags.has("n") ? "\(number + 1):" : "")
                    ctx.line(prefix + line)
                }
            }
            if flags.has("c") { ctx.line((inputs.count > 1 ? "\(input.name):" : "") + "\(count)") }
        }
        return matched ? 0 : 1
    }

    static let find = BuiltinCommand("find", "find [path] [-name pattern] [-type f|d]", "Find files") { args, ctx in
        var root = "."
        var namePattern: String?
        var type: String?
        var index = 0
        if let first = args.first, !first.hasPrefix("-") { root = first; index = 1 }
        while index < args.count {
            switch args[index] {
            case "-name" where index + 1 < args.count: namePattern = args[index + 1]; index += 2
            case "-type" where index + 1 < args.count: type = args[index + 1]; index += 2
            default: ctx.error("find", "unsupported expression \(args[index])"); return 1
            }
        }
        do {
            let start = try ctx.resolve(root)
            guard ctx.workspace.exists(start) else { throw WorkspaceError.notFound(root) }
            var stack = [start]
            var visited = 0
            while let path = stack.popLast(), visited < 100_000 {
                visited += 1
                let isDirectory = ctx.workspace.isDirectory(path)
                let typeMatches = type == nil || (type == "d" && isDirectory) || (type == "f" && !isDirectory)
                let nameMatches = namePattern.map { Glob.matches(path.name, pattern: $0) } ?? true
                if typeMatches && nameMatches {
                    let relative = path == start ? root : root == "." ? "./" + path.components.dropFirst(start.components.count).joined(separator: "/") : (root.hasSuffix("/") ? root : root + "/") + path.components.dropFirst(start.components.count).joined(separator: "/")
                    ctx.line(relative)
                }
                if isDirectory {
                    stack.append(contentsOf: try ctx.workspace.list(path, includeHidden: true).map(\.path).reversed())
                }
            }
            return 0
        } catch {
            ctx.error("find", error.localizedDescription)
            return 1
        }
    }

    static let du = BuiltinCommand("du", "du [-h] [path ...]", "Disk usage") { args, ctx in
        let flags = Flags(args)
        for operand in flags.operands.isEmpty ? ["."] : flags.operands {
            do {
                let bytes = try ctx.workspace.diskUsage(ctx.resolve(operand))
                let size = flags.has("h") ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : String((bytes + 1023) / 1024)
                ctx.line("\(size)\t\(operand)")
            } catch { ctx.error("du", error.localizedDescription); return 1 }
        }
        return 0
    }

    static let sort = BuiltinCommand("sort", "sort [-rnu] [file ...]", "Sort lines") { args, ctx in
        let flags = Flags(args)
        guard let inputs = ctx.readInput(flags.operands, command: "sort") else { return 1 }
        var lines = inputs.flatMap { $0.text.split(separator: "\n").map(String.init) }
        if flags.has("n") {
            lines.sort { (Double($0.trimmingCharacters(in: .whitespaces)) ?? 0) < (Double($1.trimmingCharacters(in: .whitespaces)) ?? 0) }
        } else {
            lines.sort()
        }
        if flags.has("r") { lines.reverse() }
        if flags.has("u") { var seen = Set<String>(); lines = lines.filter { seen.insert($0).inserted } }
        for line in lines { ctx.line(line) }
        return 0
    }

    static let uniq = BuiltinCommand("uniq", "uniq [-c] [file]", "Collapse repeated lines") { args, ctx in
        let flags = Flags(args)
        guard let inputs = ctx.readInput(flags.operands, command: "uniq") else { return 1 }
        var previous: String?
        var count = 0
        func emit() {
            guard let previous else { return }
            ctx.line(flags.has("c") ? "\(String(count).leftPad(7)) \(previous)" : previous)
        }
        for line in inputs.flatMap({ $0.text.split(separator: "\n").map(String.init) }) {
            if line == previous { count += 1 } else { emit(); previous = line; count = 1 }
        }
        emit()
        return 0
    }

    static let tee = BuiltinCommand("tee", "tee [-a] file ...", "Copy input to files and output") { args, ctx in
        let flags = Flags(args)
        let data = ctx.stdin ?? Data()
        for operand in flags.operands {
            do { try ctx.workspace.write(data, to: ctx.resolve(operand), append: flags.has("a")) } catch {
                ctx.error("tee", error.localizedDescription); return 1
            }
        }
        ctx.out(String(decoding: data, as: UTF8.self))
        return 0
    }

    static let basename = BuiltinCommand("basename", "basename path", "Last path component") { args, ctx in
        guard let path = args.first else { ctx.error("basename", "missing operand"); return 1 }
        ctx.line((path as NSString).lastPathComponent)
        return 0
    }

    static let dirname = BuiltinCommand("dirname", "dirname path", "Path without its last component") { args, ctx in
        guard let path = args.first else { ctx.error("dirname", "missing operand"); return 1 }
        let parent = (path as NSString).deletingLastPathComponent
        ctx.line(parent.isEmpty ? "." : parent)
        return 0
    }

    static let seq = BuiltinCommand("seq", "seq [first] last", "Print a sequence of numbers") { args, ctx in
        let numbers = args.compactMap { Int($0) }
        guard numbers.count == args.count, (1...2).contains(numbers.count) else { ctx.error("seq", "usage: seq [first] last"); return 1 }
        let first = numbers.count == 2 ? numbers[0] : 1
        let last = numbers.last!
        guard abs(last - first) <= 100_000 else { ctx.error("seq", "range too large"); return 1 }
        for value in stride(from: first, through: last, by: first <= last ? 1 : -1) { ctx.line(String(value)) }
        return 0
    }

    static let env = BuiltinCommand("env", "env", "Print environment variables") { _, ctx in
        for key in ctx.environment.keys.sorted() { ctx.line("\(key)=\(ctx.environment[key]!)") }
        return 0
    }

    static let export = BuiltinCommand("export", "export NAME=value ...", "Set environment variables") { args, ctx in
        for assignment in args {
            guard let equals = assignment.firstIndex(of: "="), equals != assignment.startIndex else {
                ctx.error("export", "`\(assignment)': not a valid identifier"); return 1
            }
            ctx.environment[String(assignment[..<equals])] = String(assignment[assignment.index(after: equals)...])
        }
        return 0
    }

    static let unset = BuiltinCommand("unset", "unset NAME ...", "Remove environment variables") { args, ctx in
        for name in args { ctx.environment[name] = nil }
        return 0
    }

    static let history = BuiltinCommand("history", "history", "Show command history") { _, ctx in
        for (index, entry) in ctx.history.enumerated() { ctx.line("\(String(index + 1).leftPad(5))  \(entry)") }
        return 0
    }

    static let clear = BuiltinCommand("clear", "clear", "Clear the screen") { _, ctx in
        ctx.clearRequested = true
        return 0
    }

    static let date = BuiltinCommand("date", "date [-u]", "Print the date and time") { args, ctx in
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d HH:mm:ss zzz yyyy"
        if args.contains("-u") { formatter.timeZone = TimeZone(identifier: "UTC") }
        ctx.line(formatter.string(from: Date()))
        return 0
    }

    static let whoami = BuiltinCommand("whoami", "whoami", "Print the local user") { _, ctx in
        ctx.line(ctx.environment["USER"] ?? "mobile")
        return 0
    }

    static let uname = BuiltinCommand("uname", "uname [-a]", "Print system information") { args, ctx in
        #if os(iOS)
        let system = "iOS"
        #elseif os(macOS)
        let system = "macOS"
        #else
        let system = "Linux"
        #endif
        if args.contains("-a") {
            ctx.line("\(system) \(ProcessInfo.processInfo.operatingSystemVersionString) · HCG Terminal built-in environment")
        } else {
            ctx.line(system)
        }
        return 0
    }

    static let trueCommand = BuiltinCommand("true", "true", "Do nothing, successfully") { _, _ in 0 }
    static let falseCommand = BuiltinCommand("false", "false", "Do nothing, unsuccessfully") { _, _ in 1 }

    static let which = BuiltinCommand("which", "which command ...", "Locate a command") { args, ctx in
        var status: Int32 = 0
        for name in args {
            if ctx.registry[name] != nil {
                ctx.line("\(name): HCG Terminal built-in")
            } else {
                ctx.stderr += "\(name) not found\n"
                status = 1
            }
        }
        return status
    }

    static let session = BuiltinCommand("session", "session", "Show the execution target and backend of this session") { _, ctx in
        for line in ctx.sessionDescription { ctx.line(line) }
        return 0
    }

    static let capabilities = BuiltinCommand("capabilities", "capabilities", "Show the capability report for this mode") { _, ctx in
        ctx.line(ctx.capabilityDescription)
        return 0
    }

    static let exit = BuiltinCommand("exit", "exit", "Close this session") { _, ctx in
        ctx.exitRequested = true
        return 0
    }
}

extension String {
    func leftPad(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
