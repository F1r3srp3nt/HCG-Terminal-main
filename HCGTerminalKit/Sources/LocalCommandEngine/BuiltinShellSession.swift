import FileWorkspace
import Foundation
import TerminalCore

/// A command that is not a built-in.
public struct ExternalCommandRequest: Sendable {
    public var arguments: [String]
    public var workingDirectory: WorkspacePath
    public var environment: [String: String]
    public var stdin: Data?
}

/// Decides what happens to commands that are not built-ins. The Vanilla provider refuses
/// them (no local process execution in the iOS sandbox); nothing ever forwards them to a
/// remote host.
public protocol ExternalCommandHandler: Sendable {
    /// Shown by `help` so the user knows the policy of this session.
    var policyDescription: String { get }
    /// Runs the command. `output` receives stdout (`isError == false`) and stderr chunks.
    /// Must honour task cancellation (Ctrl-C).
    func run(_ request: ExternalCommandRequest, output: @escaping @Sendable (Data, _ isError: Bool) -> Void) async -> Int32
}

/// Refuses every external command with an explanation. Exit status 127, like a shell.
public struct RefusingExternalCommandHandler: ExternalCommandHandler {
    public let policyDescription: String
    private let explanation: String

    public init(policyDescription: String, explanation: String) {
        self.policyDescription = policyDescription
        self.explanation = explanation
    }

    public func run(_ request: ExternalCommandRequest, output: @escaping @Sendable (Data, Bool) -> Void) async -> Int32 {
        let name = request.arguments.first ?? ""
        output(Data("hcg: \(name): command not found. \(explanation)\n".utf8), true)
        return 127
    }
}

/// Configuration of a built-in shell session.
public struct BuiltinShellConfiguration: Sendable {
    public var target: ExecutionTarget
    public var workspace: FileWorkspace
    public var environment: [String: String]
    public var banner: String
    public var promptLabel: String
    /// ANSI color for the prompt label.
    public var promptColor: String
    public var sessionDescription: [String]
    public var capabilityDescription: @Sendable () async -> String

    public init(
        target: ExecutionTarget, workspace: FileWorkspace, environment: [String: String], banner: String,
        promptLabel: String, promptColor: String, sessionDescription: [String],
        capabilityDescription: @escaping @Sendable () async -> String
    ) {
        self.target = target
        self.workspace = workspace
        self.environment = environment
        self.banner = banner
        self.promptLabel = promptLabel
        self.promptColor = promptColor
        self.sessionDescription = sessionDescription
        self.capabilityDescription = capabilityDescription
    }
}

/// A local session backed by HCG Terminal's built-in commands and a line editor.
public actor BuiltinShellSession: TerminalSession {
    public nonisolated let id = SessionID()
    public nonisolated let target: ExecutionTarget
    public nonisolated let backend: SessionBackend = .builtInCommands
    public nonisolated let createdAt = Date()
    public nonisolated var events: AsyncStream<TerminalEvent> { channel.stream }

    private let channel = EventChannel<TerminalEvent>()
    private let configuration: BuiltinShellConfiguration
    private let external: any ExternalCommandHandler
    private let context: BuiltinContext
    private var editor = LineEditor()
    private var runningTask: Task<Void, Never>?
    private var lastStatus: Int32 = 0
    private var started = false
    private var closed = false

    public init(configuration: BuiltinShellConfiguration, external: any ExternalCommandHandler, registry: BuiltinRegistry = .standard) {
        self.configuration = configuration
        self.target = configuration.target
        self.external = external
        var environment = configuration.environment
        environment["HOME"] = environment["HOME"] ?? WorkspacePath.home.string
        environment["PWD"] = WorkspacePath.home.string
        let context = BuiltinContext(workspace: configuration.workspace, cwd: .home, environment: environment, registry: registry)
        context.sessionDescription = configuration.sessionDescription
        context.externalCommandPolicy = external.policyDescription
        self.context = context
    }

    // MARK: TerminalSession

    public func start(size: TerminalSize) async throws {
        guard !started else { return }
        started = true
        channel.yield(.stateChanged(.ready))
        channel.yield(.workingDirectory(context.cwd.string))
        channel.write(configuration.banner)
        showPrompt()
    }

    public func send(_ bytes: [UInt8]) async throws {
        guard !closed else { throw ExecutionError.sessionClosed }
        if runningTask != nil {
            // While a command runs, only Ctrl-C is meaningful.
            if bytes.contains(0x03) { await interrupt() }
            return
        }
        for action in editor.feed(bytes) {
            switch action {
            case .echo(let echo):
                channel.yield(.output(echo))
            case .submit(let line):
                submit(line)
            case .interrupt:
                lastStatus = 130
                showPrompt()
            case .endOfInput:
                channel.write("exit\n")
                await close()
                return
            case .clearScreen:
                channel.write(ANSI.clearScreen)
                showPrompt(keepBuffer: true)
            case .complete(let prefix):
                complete(prefix)
            }
        }
    }

    public func resize(_ size: TerminalSize) async {}

    public func interrupt() async {
        guard let runningTask else { return }
        runningTask.cancel()
        channel.write("^C\n")
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        runningTask?.cancel()
        channel.yield(.stateChanged(.closed))
        channel.finish()
    }

    /// Runs a line as if typed (used by tests and by "run in session" actions).
    public func runForTesting(_ line: String) async -> Int32 {
        await execute(line)
        return lastStatus
    }

    // MARK: Prompt and completion

    private var prompt: String {
        let home = (try? WorkspacePath(context.environment["HOME"] ?? "/home")) ?? .home
        let location = context.cwd.display(home: home)
        return "\(configuration.promptColor)\(configuration.promptLabel)\(ANSI.reset) \(ANSI.bold)\(location)\(ANSI.reset) $ "
    }

    private func showPrompt(keepBuffer: Bool = false) {
        editor.prompt = prompt
        if keepBuffer {
            channel.yield(.output(editor.redraw()))
        } else {
            editor.reset()
            channel.write(prompt)
        }
    }

    private func complete(_ prefix: String) {
        let words = prefix.split(separator: " ", omittingEmptySubsequences: false)
        let fragment = String(words.last ?? "")
        var candidates: [String]
        if words.count <= 1 {
            candidates = context.registry.sortedNames.filter { $0.hasPrefix(fragment) }
        } else {
            let directoryPart = fragment.contains("/") ? String(fragment[...fragment.lastIndex(of: "/")!]) : ""
            let namePart = String(fragment.dropFirst(directoryPart.count))
            let directory = (try? context.resolve(directoryPart.isEmpty ? "." : directoryPart)) ?? context.cwd
            candidates = ((try? context.workspace.list(directory, includeHidden: namePart.hasPrefix("."))) ?? [])
                .filter { $0.name.hasPrefix(namePart) }
                .map { directoryPart + $0.name + ($0.isDirectory ? "/" : "") }
        }
        guard !candidates.isEmpty else { channel.yield(.output([0x07])); return }
        let common = candidates.dropFirst().reduce(candidates[0]) { partial, next in
            String(zip(partial, next).prefix(while: { $0 == $1 }).map(\.0))
        }
        if common.count > fragment.count {
            let insertion = String(common.dropFirst(fragment.count)) + (candidates.count == 1 && !common.hasSuffix("/") ? " " : "")
            channel.yield(.output(editor.insert(insertion)))
        } else if candidates.count > 1 {
            channel.write("\n" + candidates.joined(separator: "  ") + "\n")
            channel.yield(.output(editor.redraw()))
        }
    }

    // MARK: Execution

    private func submit(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { showPrompt(); return }
        editor.addHistory(trimmed)
        context.history.append(trimmed)
        channel.yield(.stateChanged(.running(command: trimmed)))
        runningTask = Task {
            await self.execute(trimmed)
            self.finishRun()
        }
    }

    private func finishRun() {
        runningTask = nil
        if context.exitRequested {
            Task { await self.close() }
            return
        }
        channel.yield(.stateChanged(.ready))
        showPrompt()
    }

    private func execute(_ line: String) async {
        let list: CommandList
        do {
            list = try CommandParser.parse(line, environment: context.environment, lastStatus: lastStatus)
        } catch {
            channel.write("hcg: \(error.localizedDescription)\n")
            lastStatus = 2
            return
        }
        var previousConnector: ListConnector = .sequence
        for item in list.items {
            if Task.isCancelled { lastStatus = 130; return }
            switch previousConnector {
            case .and where lastStatus != 0: previousConnector = item.connector; continue
            case .or where lastStatus == 0: previousConnector = item.connector; continue
            default: break
            }
            lastStatus = await run(item.pipeline)
            previousConnector = item.connector
            if context.exitRequested { return }
        }
        if Task.isCancelled { lastStatus = 130 }
    }

    private func run(_ pipeline: Pipeline) async -> Int32 {
        var input: Data?
        var status: Int32 = 0
        for (index, command) in pipeline.commands.enumerated() {
            if Task.isCancelled { return 130 }
            let isLast = index == pipeline.commands.count - 1
            var arguments = expand(command.words)
            var redirectOut: (WorkspacePath, Bool)?

            // Leading NAME=value words set variables (only meaningful without a command).
            while let first = arguments.first, let equals = first.firstIndex(of: "="), equals != first.startIndex,
                  first[..<equals].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                if arguments.count == 1 { context.environment[String(first[..<equals])] = String(first[first.index(after: equals)...]) }
                arguments.removeFirst()
            }

            do {
                for redirection in command.redirections {
                    switch redirection {
                    case .input(let file): input = try context.workspace.readData(context.resolve(file))
                    case .output(let file, let append): redirectOut = (try context.resolve(file), append)
                    }
                }
            } catch {
                channel.write("hcg: \(error.localizedDescription)\n")
                return 1
            }
            guard let name = arguments.first else { continue }

            let streamDirectly = isLast && redirectOut == nil
            var stdout = Data()
            if let builtin = context.registry[name] {
                context.stdin = input
                context.stdout = ""
                context.stderr = ""
                status = builtin.run(Array(arguments.dropFirst()), context)
                stdout = Data(context.stdout.utf8)
                if !context.stderr.isEmpty { channel.write(ANSI.red + context.stderr + ANSI.reset) }
                if context.clearRequested {
                    context.clearRequested = false
                    channel.write(ANSI.clearScreen)
                }
                if name == "cd" { channel.yield(.workingDirectory(context.cwd.string)) }
                if streamDirectly { channel.write(context.stdout) }
            } else {
                let request = ExternalCommandRequest(
                    arguments: arguments, workingDirectory: context.cwd, environment: context.environment, stdin: input
                )
                let collector = DataCollector()
                let channel = self.channel
                status = await external.run(request) { data, isError in
                    if isError {
                        channel.yield(.output(Array(data)))
                    } else if streamDirectly {
                        channel.yield(.output(Array(data)))
                    } else {
                        collector.append(data)
                    }
                }
                stdout = collector.data
            }

            if let (path, append) = redirectOut {
                do { try context.workspace.write(stdout, to: path, append: append) } catch {
                    channel.write("hcg: \(error.localizedDescription)\n")
                    return 1
                }
            }
            input = stdout
        }
        return status
    }

    /// Glob expansion against the workspace for unquoted patterns.
    private func expand(_ words: [ShellWord]) -> [String] {
        var result: [String] = []
        for word in words {
            guard word.globbable, Glob.hasPattern(word.text) else { result.append(word.text); continue }
            let directoryPart = word.text.contains("/") ? String(word.text[...word.text.lastIndex(of: "/")!]) : ""
            let pattern = String(word.text.dropFirst(directoryPart.count))
            guard !Glob.hasPattern(directoryPart),
                  let directory = try? context.resolve(directoryPart.isEmpty ? "." : directoryPart),
                  let items = try? context.workspace.list(directory, includeHidden: pattern.hasPrefix(".")) else {
                result.append(word.text); continue
            }
            let matches = items.map(\.name).filter { Glob.matches($0, pattern: pattern) }.map { directoryPart + $0 }
            result.append(contentsOf: matches.isEmpty ? [word.text] : matches)
        }
        return result
    }

    /// Loads the capability description lazily so `capabilities` shows the current report.
    public func refreshCapabilityDescription() async {
        context.capabilityDescription = await configuration.capabilityDescription()
    }
}

/// Thread-safe byte accumulator for streamed output.
final class DataCollector: @unchecked Sendable {
    private var storage = Data()
    private let lock = NSLock()

    func append(_ data: Data) {
        lock.lock(); storage.append(data); lock.unlock()
    }

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
