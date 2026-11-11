import ArtifactManager
import BuildOrchestrator
import DeveloperWorkspace
import Foundation
import Observation
import TerminalCore

/// Remote build, test and artifact state. Everything here runs on a remote host and is
/// independent of the local mode.
@MainActor
@Observable
public final class BuildCenter {
    public private(set) var runs: [BuildRun] = []
    public private(set) var activePlan: BuildPlan?
    public private(set) var liveLog = ""
    public private(set) var artifacts: [ArtifactRecord] = []
    public private(set) var discovered: [UUID: [DiscoveredArtifact]] = [:]
    public private(set) var downloadProgress: [String: Double] = [:]
    public var lastError: String?

    @ObservationIgnored private let orchestrator: BuildOrchestrator
    @ObservationIgnored private let index: ArtifactIndex
    @ObservationIgnored private let workspaceProvider: @MainActor () -> AppDependencies
    @ObservationIgnored private var runningTask: Task<Void, Never>?
    @ObservationIgnored let executorFor: @MainActor (UUID) async throws -> any RemoteCommandExecuting

    init(dependencies: AppDependencies, executorFor: @escaping @MainActor (UUID) async throws -> any RemoteCommandExecuting) {
        self.orchestrator = dependencies.orchestrator
        self.index = dependencies.artifactIndex
        self.workspaceProvider = { dependencies }
        self.executorFor = executorFor
    }

    public var isRunning: Bool { activePlan != nil }

    public func reload() async {
        runs = await orchestrator.runs()
        artifacts = await index.all()
    }

    public func start(_ plan: BuildPlan) {
        guard activePlan == nil else { return }
        activePlan = plan
        liveLog = "$ \(plan.commandLine)\n"
        runningTask = Task {
            do {
                let executor = try await executorFor(plan.hostID)
                let run = await orchestrator.run(plan, on: executor) { [weak self] text in
                    Task { @MainActor in self?.appendLog(text) }
                }
                if run.status == .succeeded, let found = try? await ArtifactDiscovery.discover(for: plan, on: executor) {
                    discovered[run.id] = found
                }
            } catch {
                lastError = error.localizedDescription
            }
            activePlan = nil
            runningTask = nil
            await reload()
        }
    }

    private func appendLog(_ text: String) {
        liveLog += text
        if liveLog.count > 400_000 { liveLog.removeFirst(liveLog.count - 400_000) }
    }

    /// Cancels the running build; the remote channel is closed.
    public func cancel() {
        runningTask?.cancel()
    }

    public func log(for run: BuildRun) async -> String {
        await orchestrator.log(for: run)
    }

    public func logURL(for run: BuildRun) async -> URL {
        await orchestrator.logURL(for: run)
    }

    public func discover(for run: BuildRun) async {
        do {
            discovered[run.id] = try await ArtifactDiscovery.discover(for: run.plan, on: executorFor(run.plan.hostID))
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func download(_ artifact: DiscoveredArtifact, from run: BuildRun) async {
        let key = artifact.remotePath
        downloadProgress[key] = 0
        defer { downloadProgress[key] = nil }
        do {
            let executor = try await executorFor(run.plan.hostID)
            _ = try await ArtifactDownloader().download(
                remotePath: artifact.remotePath, from: executor, into: workspaceProvider().workspace, index: index, buildRunID: run.id
            ) { [weak self] received, total in
                Task { @MainActor in
                    if total > 0 { self?.downloadProgress[key] = Double(received) / Double(total) }
                }
            }
            artifacts = await index.all()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func localURL(for record: ArtifactRecord) -> URL? {
        guard let path = try? FileWorkspacePathBridge.path(record.localPath) else { return nil }
        return try? workspaceProvider().workspace.url(for: path)
    }

    public func delete(_ record: ArtifactRecord) async {
        try? await index.remove(record.id)
        artifacts = await index.all()
    }
}

import FileWorkspace

enum FileWorkspacePathBridge {
    static func path(_ string: String) throws -> WorkspacePath { try WorkspacePath(string) }
}
