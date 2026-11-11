#if canImport(UIKit) && canImport(SwiftUI)
import BuildOrchestrator
import DeveloperWorkspace
import SwiftUI
import TerminalCore
import TerminalSecurity

struct HostsView: View {
    @Environment(TerminalAppModel.self) private var model
    @State private var editing: HostProfile?

    var body: some View {
        List {
            if model.hosts.isEmpty {
                ContentUnavailableView("No Hosts", systemImage: "server.rack", description: Text("Add your Mac or another SSH host to browse projects, build, test and run Claude Code remotely."))
            }
            ForEach(model.hosts) { host in
                NavigationLink {
                    HostDetailView(host: host)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(host.name)
                            if model.isConnected(host) { Circle().fill(HCGPalette.vanillaGreen).frame(width: 6, height: 6) }
                        }
                        Text(host.endpoint.address).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { Task { await model.deleteHost(host) } }
                    Button("Edit") { editing = host }
                }
            }
        }
        .navigationTitle("Hosts & Projects")
        .toolbar {
            Button { editing = HostProfile(name: "", hostname: "", username: "", auth: .password) } label: { Label("Add Host", systemImage: "plus") }
        }
        .sheet(item: $editing) { host in
            NavigationStack { HostEditor(host: host) }.environment(model)
        }
    }
}

/// Picks a host for a new remote session.
struct HostPickerView: View {
    @Environment(TerminalAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onPick: (HostProfile) -> Void

    var body: some View {
        List(model.hosts) { host in
            Button { onPick(host) } label: {
                VStack(alignment: .leading) {
                    Text(host.name)
                    Text(host.endpoint.address).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if model.hosts.isEmpty {
                ContentUnavailableView("No Hosts", systemImage: "server.rack", description: Text("Add a host under Hosts & Projects first."))
            }
        }
        .navigationTitle("Remote Host Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
}

struct HostEditor: View {
    @Environment(TerminalAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var host: HostProfile
    @State private var password = ""
    @State private var portText = ""

    private enum AuthChoice: String, CaseIterable { case password = "Password", key = "SSH Key", keyThenPassword = "Key, then Password" }
    @State private var authChoice: AuthChoice = .password
    @State private var keyID: UUID?

    var body: some View {
        Form {
            Section("Host") {
                TextField("Name", text: $host.name)
                TextField("Hostname or IP", text: $host.hostname)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField("Port", text: $portText).keyboardType(.numberPad)
                TextField("Username", text: $host.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Projects folder (optional)", text: Binding(get: { host.projectsPath ?? "" }, set: { host.projectsPath = $0.isEmpty ? nil : $0 }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section {
                Picker("Method", selection: $authChoice) {
                    ForEach(AuthChoice.allCases, id: \.self) { Text($0.rawValue) }
                }
                if authChoice != .key {
                    SecureField("Password (stored in the Keychain)", text: $password)
                }
                if authChoice != .password {
                    Picker("Key", selection: $keyID) {
                        Text("Choose…").tag(UUID?.none)
                        ForEach(model.keys) { Text($0.comment.isEmpty ? $0.fingerprint : $0.comment).tag(UUID?.some($0.id)) }
                    }
                    NavigationLink("Manage SSH Keys") { KeysView() }
                }
            } header: { Text("Authentication") } footer: {
                Text("Passwords and private keys are kept in the Keychain on this device only. Ed25519 keys are supported.")
            }
        }
        .navigationTitle(host.name.isEmpty ? "New Host" : host.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            portText = String(host.port)
            switch host.auth {
            case .password: authChoice = .password
            case .key(let id): authChoice = .key; keyID = id
            case .keyThenPassword(let id): authChoice = .keyThenPassword; keyID = id
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    var updated = host
                    updated.port = Int(portText) ?? 22
                    switch authChoice {
                    case .password: updated.auth = .password
                    case .key: if let keyID { updated.auth = .key(keyID) }
                    case .keyThenPassword: if let keyID { updated.auth = .keyThenPassword(keyID) }
                    }
                    Task {
                        await model.saveHost(updated, password: authChoice == .key ? nil : password)
                        dismiss()
                    }
                }
                .disabled(!isValid)
            }
        }
    }

    private var isValid: Bool {
        var candidate = host
        candidate.port = Int(portText) ?? 0
        return candidate.isValid && (authChoice == .password || keyID != nil)
    }
}

/// Actions for one host: shell, Claude Code, project browsing, toolchains.
struct HostDetailView: View {
    @Environment(TerminalAppModel.self) private var model
    let host: HostProfile
    @State private var toolchains: RemoteToolchains?
    @State private var probing = false

    var body: some View {
        List {
            Section {
                Button { Task { await model.openRemoteShell(host) } } label: { Label("Open Shell", systemImage: "terminal") }
                NavigationLink { RemoteBrowserView(host: host, startPath: host.projectsPath ?? "~") } label: {
                    Label("Browse Projects", systemImage: "folder")
                }
                if model.isConnected(host) {
                    Button(role: .destructive) { Task { await model.disconnect(host) } } label: { Label("Disconnect", systemImage: "bolt.slash") }
                }
            } header: { Text(host.endpoint.address) } footer: {
                Text("Remote sessions run on \(host.name) and are independent of the local mode.")
            }
            Section("Toolchains") {
                if let toolchains {
                    LabeledContent("System", value: toolchains.operatingSystem)
                    ForEach(ToolchainProbe.tools, id: \.self) { tool in
                        LabeledContent(tool, value: toolchains.tools[tool] ?? "not found")
                    }
                } else {
                    Button(probing ? "Checking…" : "Check Installed Tools") { Task { await probe() } }.disabled(probing)
                }
            }
        }
        .navigationTitle(host.name)
    }

    private func probe() async {
        probing = true
        defer { probing = false }
        do { toolchains = try await ToolchainProbe.probe(model.connection(for: host)) } catch { model.errorMessage = error.localizedDescription }
    }
}

/// Browses a remote directory, recognises projects and starts builds, tests or Claude Code.
struct RemoteBrowserView: View {
    @Environment(TerminalAppModel.self) private var model
    let host: HostProfile
    let startPath: String
    @State private var directory = ""
    @State private var entries: [RemoteEntry] = []
    @State private var loading = false
    @State private var planning: ProjectKind?

    var body: some View {
        List {
            let projects = ProjectDetector.detect(entries)
            if !projects.isEmpty {
                Section("Project") {
                    ForEach(projects, id: \.self) { project in
                        Button { planning = project } label: { Label(project.label, systemImage: "hammer") }
                    }
                    Button { Task { await model.openClaudeCode(host, projectPath: directory) } } label: {
                        Label("Claude Code in This Folder", systemImage: "sparkles")
                    }
                }
            }
            Section(directory) {
                ForEach(entries) { entry in
                    if entry.kind == .directory || entry.kind == .symlink {
                        NavigationLink { RemoteBrowserView(host: host, startPath: entry.path) } label: { row(entry) }
                    } else {
                        row(entry)
                    }
                }
            }
        }
        .overlay { if loading { ProgressView() } }
        .navigationTitle((directory as NSString).lastPathComponent.isEmpty ? "Projects" : (directory as NSString).lastPathComponent)
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            Button { Task { await model.openClaudeCode(host, projectPath: directory.isEmpty ? startPath : directory) } } label: {
                Label("Claude Code", systemImage: "sparkles")
            }
        }
        .sheet(item: Binding(get: { planning.map(PlanningTarget.init) }, set: { planning = $0?.kind })) { target in
            NavigationStack { BuildPlanSheet(host: host, projectPath: directory, project: target.kind) }.environment(model)
        }
    }

    private func row(_ entry: RemoteEntry) -> some View {
        HStack {
            Image(systemName: entry.kind == .directory ? "folder" : entry.kind == .symlink ? "arrow.turn.up.right" : "doc")
                .foregroundStyle(entry.kind == .directory ? HCGPalette.vanillaBlue : HCGPalette.muted)
            Text(entry.name)
            Spacer()
            if let size = entry.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let result = try await RemoteProjectBrowser(executor: model.connection(for: host)).list(directory.isEmpty ? startPath : directory)
            directory = result.directory
            entries = result.entries
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

struct PlanningTarget: Identifiable {
    let kind: ProjectKind
    var id: String { kind.label }
}
#endif
