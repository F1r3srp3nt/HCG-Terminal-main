#if canImport(UIKit) && canImport(SwiftUI)
import ArtifactManager
import BuildOrchestrator
import DeveloperWorkspace
import SwiftUI
import TerminalCore
import TerminalSecurity

/// Chooses action, configuration, scheme and destination, shows the exact command, then runs it.
struct BuildPlanSheet: View {
    @Environment(TerminalAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: HostProfile
    let projectPath: String
    let project: ProjectKind

    @State private var action: BuildAction = .build
    @State private var configuration: BuildConfiguration = .debug
    @State private var schemes: [String] = []
    @State private var scheme = ""
    @State private var destination: DestinationChoice = .macOS
    @State private var simulatorName = "iPhone 17"

    enum DestinationChoice: String, CaseIterable { case macOS = "My Mac", genericIOS = "Any iOS Device", simulator = "iOS Simulator" }

    var body: some View {
        Form {
            Section("Project") {
                LabeledContent("Host", value: host.name)
                LabeledContent("Folder", value: projectPath)
                LabeledContent("Type", value: project.label)
            }
            Section("Run") {
                Picker("Action", selection: $action) { ForEach(BuildAction.allCases, id: \.self) { Text($0.title) } }
                    .pickerStyle(.segmented)
                Picker("Configuration", selection: $configuration) { ForEach(BuildConfiguration.allCases, id: \.self) { Text($0.rawValue) } }
                if isXcode {
                    Picker("Scheme", selection: $scheme) { ForEach(schemes, id: \.self) { Text($0) } }
                    Picker("Destination", selection: $destination) { ForEach(DestinationChoice.allCases, id: \.self) { Text($0.rawValue) } }
                    if destination == .simulator { TextField("Simulator name", text: $simulatorName) }
                }
            }
            Section {
                if let plan = try? makePlan() {
                    Text(plan.commandLine).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                } else if let error = planError {
                    Text(error).foregroundStyle(HCGPalette.warn)
                }
            } header: { Text("Command") } footer: {
                Text("Runs on \(host.name) over SSH. Never uploads or publishes anything.")
            }
        }
        .navigationTitle("Build & Test")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSchemes() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Run") {
                    if let plan = try? makePlan() { model.builds.start(plan); dismiss() }
                }
                .disabled((try? makePlan()) == nil || model.builds.isRunning)
            }
        }
    }

    private var isXcode: Bool {
        switch project {
        case .xcodeProject, .xcodeWorkspace: true
        default: false
        }
    }

    private var planError: String? {
        do { _ = try makePlan(); return nil } catch { return error.localizedDescription }
    }

    private func makePlan() throws -> BuildPlan {
        let destinationValue: XcodeDestination = switch destination {
        case .macOS: .macOS
        case .genericIOS: .genericIOS
        case .simulator: .iOSSimulator(name: simulatorName)
        }
        let system: BuildSystem
        switch project {
        case .swiftPackage: system = .swiftPackage
        case .xcodeProject(let name):
            guard !scheme.isEmpty else { throw BuildPlanError.unsupported("Choose a scheme.") }
            system = .xcodeProject(name: name, scheme: scheme, destination: destinationValue)
        case .xcodeWorkspace(let name):
            guard !scheme.isEmpty else { throw BuildPlanError.unsupported("Choose a scheme.") }
            system = .xcodeWorkspace(name: name, scheme: scheme, destination: destinationValue)
        case .dotnetSolution(let name), .dotnetProject(let name): system = .dotnet(target: name)
        }
        return try BuildPlanner.plan(host: host, projectPath: projectPath, system: system, action: action, configuration: configuration)
    }

    private func loadSchemes() async {
        guard isXcode, let command = XcodeSchemeLister.command(projectDirectory: projectPath, container: project) else { return }
        do {
            let result = try await model.connection(for: host).run(command)
            schemes = XcodeSchemeLister.parse(result.stdout)
            if scheme.isEmpty { scheme = schemes.first ?? "" }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

struct BuildsView: View {
    @Environment(TerminalAppModel.self) private var model

    var body: some View {
        let builds = model.builds!
        List {
            if let plan = builds.activePlan {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            ProgressView()
                            Text(plan.title).font(.subheadline.weight(.semibold))
                            Spacer()
                            Button("Stop", role: .destructive) { builds.cancel() }
                        }
                        Text("on \(plan.hostName)").font(.caption).foregroundStyle(.secondary)
                        ScrollView {
                            Text(builds.liveLog)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(height: 260)
                        .defaultScrollAnchor(.bottom)
                    }
                } header: { Text("Running") }
            }
            Section("History") {
                ForEach(builds.runs) { run in
                    NavigationLink { BuildRunDetailView(run: run) } label: { BuildRunRow(run: run) }
                }
            }
        }
        .overlay {
            if builds.runs.isEmpty && builds.activePlan == nil {
                ContentUnavailableView("No Builds Yet", systemImage: "hammer", description: Text("Open Hosts & Projects, browse to a project and choose Build & Test."))
            }
        }
        .navigationTitle("Builds & Tests")
        .refreshable { await builds.reload() }
    }
}

struct BuildRunRow: View {
    let run: BuildRun

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.plan.title).lineLimit(1)
                Text("\(run.plan.hostName) · \(run.status.label) · \(run.startedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var icon: String {
        switch run.status {
        case .succeeded: "checkmark.circle.fill"
        case .running: "clock"
        case .cancelled: "stop.circle"
        default: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch run.status {
        case .succeeded: HCGPalette.vanillaGreen
        case .running, .cancelled: HCGPalette.muted
        default: HCGPalette.loss
        }
    }
}

struct BuildRunDetailView: View {
    @Environment(TerminalAppModel.self) private var model
    let run: BuildRun
    @State private var log = ""
    @State private var logURL: URL?

    var body: some View {
        let builds = model.builds!
        List {
            Section("Result") {
                LabeledContent("Status", value: run.status.label)
                LabeledContent("Host", value: run.plan.hostName)
                LabeledContent("Folder", value: run.plan.projectPath)
                if let finished = run.finishedAt {
                    LabeledContent("Duration", value: Duration.seconds(finished.timeIntervalSince(run.startedAt)).formatted(.units(allowed: [.minutes, .seconds])))
                }
                Text(run.plan.commandLine).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            if let summary = run.testSummary {
                Section("Tests") {
                    LabeledContent("Outcome", value: summary.succeeded ? "Passed" : "Failed")
                    if let total = summary.total { LabeledContent("Total", value: "\(total)") }
                    if let failed = summary.failed { LabeledContent("Failed", value: "\(failed)") }
                    if let skipped = summary.skipped { LabeledContent("Skipped", value: "\(skipped)") }
                }
            }
            if !run.diagnostics.isEmpty {
                Section("Diagnostics (\(run.errorCount) errors, \(run.warningCount) warnings)") {
                    ForEach(run.diagnostics) { diagnostic in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(diagnostic.message, systemImage: diagnostic.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                                .foregroundStyle(diagnostic.severity == .error ? HCGPalette.loss : HCGPalette.warn)
                            if let file = diagnostic.file {
                                Text("\((file as NSString).lastPathComponent):\(diagnostic.line ?? 0)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("Artifacts") {
                ForEach(builds.discovered[run.id] ?? []) { artifact in
                    HStack {
                        Label(artifact.name, systemImage: artifact.isDirectory ? "shippingbox" : "doc.zipper")
                        Spacer()
                        if let progress = builds.downloadProgress[artifact.remotePath] {
                            ProgressView(value: progress).frame(width: 80)
                        } else {
                            Button("Download") { Task { await builds.download(artifact, from: run) } }
                        }
                    }
                }
                Button("Find Build Products") { Task { await builds.discover(for: run) } }
            }
            Section("Log") {
                Text(log.isEmpty ? "Loading…" : String(log.suffix(60_000)))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                if let logURL { ShareLink("Share Full Log", item: logURL) }
            }
        }
        .navigationTitle(run.plan.action.title)
        .task {
            log = await builds.log(for: run)
            logURL = await builds.logURL(for: run)
        }
    }
}

struct ArtifactsView: View {
    @Environment(TerminalAppModel.self) private var model

    var body: some View {
        let builds = model.builds!
        List {
            ForEach(builds.artifacts) { record in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(record.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        if let url = builds.localURL(for: record) { ShareLink(item: url) { Image(systemName: "square.and.arrow.up") } }
                    }
                    Text("\(ByteCountFormatter.string(fromByteCount: record.size, countStyle: .file)) · from \(record.hostName)")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(record.verification == .remoteChecksumMatched ? "SHA-256 verified against the remote host" : "SHA-256 of local archive (directory transfer)")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(record.sha256).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .swipeActions { Button("Delete", role: .destructive) { Task { await builds.delete(record) } } }
            }
        }
        .overlay {
            if builds.artifacts.isEmpty {
                ContentUnavailableView("No Artifacts", systemImage: "shippingbox", description: Text("Download build products from a finished build. Files are stored in the app workspace under /artifacts."))
            }
        }
        .navigationTitle("Artifacts")
        .refreshable { await builds.reload() }
    }
}

struct KeysView: View {
    @Environment(TerminalAppModel.self) private var model
    @State private var comment = "hcg-terminal"

    var body: some View {
        List {
            Section {
                TextField("Comment", text: $comment)
                Button("Generate Ed25519 Key") { model.generateKey(comment: comment) }
            } footer: {
                Text("The private key is created and kept in the Keychain on this device. Add the public key to ~/.ssh/authorized_keys on your host.")
            }
            ForEach(model.keys) { key in
                VStack(alignment: .leading, spacing: 4) {
                    Text(key.comment.isEmpty ? "Ed25519 key" : key.comment).font(.subheadline.weight(.semibold))
                    Text(key.fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
                    HStack {
                        Button("Copy Public Key") { UIPasteboard.general.string = key.publicKeyLine }
                        ShareLink(item: key.publicKeyLine) { Text("Share") }
                    }
                    .buttonStyle(.borderless)
                }
                .swipeActions { Button("Delete", role: .destructive) { model.deleteKey(key) } }
            }
        }
        .navigationTitle("SSH Keys")
    }
}

struct KnownHostsView: View {
    @Environment(TerminalAppModel.self) private var model
    @State private var entries: [KnownHostEntry] = []

    var body: some View {
        List {
            ForEach(entries, id: \.self) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.port == 22 ? entry.host : "\(entry.host):\(entry.port)")
                    Text("\(entry.algorithm) \(entry.fingerprint)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("Forget", role: .destructive) {
                        Task {
                            try? await model.dependencies.knownHosts.forget(host: entry.host, port: entry.port)
                            entries = await model.dependencies.knownHosts.all()
                        }
                    }
                }
            }
        }
        .overlay { if entries.isEmpty { ContentUnavailableView("No Known Hosts", systemImage: "key") } }
        .navigationTitle("Known Hosts")
        .task { entries = await model.dependencies.knownHosts.all() }
    }
}
#endif
