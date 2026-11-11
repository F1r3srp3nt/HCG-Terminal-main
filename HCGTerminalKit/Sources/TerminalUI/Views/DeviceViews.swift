#if canImport(UIKit) && canImport(SwiftUI)
import Diagnostics
import SwiftUI
import TerminalCapabilityProvider
import TerminalCore

/// Unleashed build only: packages, permitted locations and logs. Every view states what it
/// can and cannot do on this device; nothing is attempted without a user action.
struct UnleashedToolsView: View {
    @Environment(TerminalAppModel.self) private var model
    @State private var packages: [PackageRow] = []
    @State private var packageFilter = ""
    @State private var packageName = ""
    @State private var roots: [String] = []
    @State private var logRoots: [String] = []
    @State private var packagesAvailable = false
    @State private var loading = false

    var body: some View {
        List {
            if !model.isAvailable(.unleashed) {
                Section {
                    Text(CapabilityReport.unleashedUnavailableMessage).foregroundStyle(HCGPalette.warn)
                }
            }
            Section {
                if packagesAvailable {
                    HStack {
                        TextField("Package name", text: $packageName)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Install") { request(.install(packageName)) }.disabled(packageName.isEmpty)
                    }
                    Button("Refresh Package Lists") { request(.refreshIndexes) }
                    TextField("Filter installed packages", text: $packageFilter)
                    ForEach(packages.filter { packageFilter.isEmpty || $0.name.localizedCaseInsensitiveContains(packageFilter) }.prefix(300)) { package in
                        HStack {
                            Text(package.name)
                            Spacer()
                            Text(package.version).font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions { Button("Remove", role: .destructive) { request(.remove(package.name)) } }
                    }
                } else {
                    Text("No supported package manager was found.").foregroundStyle(.secondary)
                }
            } header: { Text("Packages") } footer: {
                Text("Listing is read-only. Install, remove and refresh need your approval each time, then run visibly in a new Local Unleashed session with the permissions the device grants. HCG Terminal never adds sudo.")
            }
            Section("Permitted locations") {
                if roots.isEmpty { Text("No location outside the app sandbox is readable.").foregroundStyle(.secondary) }
                ForEach(roots, id: \.self) { root in
                    NavigationLink(root) { HostDirectoryView(path: root) }
                }
            }
            Section("Logs") {
                if logRoots.isEmpty { Text("No readable log directories.").foregroundStyle(.secondary) }
                ForEach(logRoots, id: \.self) { root in
                    NavigationLink(root) { HostDirectoryView(path: root) }
                }
            }
        }
        .navigationTitle("Unleashed Tools")
        .overlay { if loading { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let tools = model.dependencies.unleashedTools else { return }
        loading = true
        defer { loading = false }
        packagesAvailable = await tools.packageManagerAvailable()
        roots = await tools.permittedRoots()
        logRoots = await tools.logRoots()
        if packagesAvailable {
            do { packages = try await tools.installedPackages() } catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func request(_ request: PackageRequest) {
        guard let tools = model.dependencies.unleashedTools else { return }
        Task {
            do {
                let command = try await tools.authorizedPackageCommand(request)
                await model.runApprovedCommandInNewUnleashedSession(command)
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}

/// Read-only listing of a permitted directory, with a log/text viewer for files.
struct HostDirectoryView: View {
    @Environment(TerminalAppModel.self) private var model
    let path: String
    @State private var rows: [HostFileRow] = []

    var body: some View {
        List(rows) { row in
            if row.isDirectory {
                NavigationLink { HostDirectoryView(path: row.path) } label: { Label(row.name, systemImage: "folder") }
            } else {
                NavigationLink { HostFileTailView(path: row.path) } label: {
                    HStack {
                        Label(row.name, systemImage: "doc.text")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .task {
            do { rows = try await model.dependencies.unleashedTools?.list(path) ?? [] } catch { model.errorMessage = error.localizedDescription }
        }
    }
}

struct HostFileTailView: View {
    @Environment(TerminalAppModel.self) private var model
    let path: String
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .defaultScrollAnchor(.bottom)
        .navigationTitle((path as NSString).lastPathComponent)
        .task {
            do { text = try await model.dependencies.unleashedTools?.readTail(path) ?? "" } catch { text = error.localizedDescription }
        }
    }
}

/// Sign-in to an existing terminal service on this device (loopback SSH).
struct LoopbackServiceSheet: View {
    @Environment(TerminalAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var ports: [Int] = []
    @State private var port = 22
    @State private var username = "mobile"
    @State private var password = ""

    var body: some View {
        Form {
            Section {
                if ports.isEmpty {
                    Text("No terminal service is accepting connections on 127.0.0.1.").foregroundStyle(.secondary)
                } else {
                    Picker("Port", selection: $port) { ForEach(ports, id: \.self) { Text("127.0.0.1:\($0)") } }
                }
                TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password", text: $password)
            } footer: {
                Text("Uses the service's own account. The password is used for this connection only and is not stored. Commands run on this device (Local Unleashed).")
            }
        }
        .navigationTitle("Local Terminal Service")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            ports = await model.dependencies.unleashedTools?.loopbackServicePorts() ?? []
            if let first = ports.first { port = first }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Connect") {
                    Task {
                        await model.openLoopbackService(port: port, username: username, password: password)
                        password = ""
                        dismiss()
                    }
                }
                .disabled(ports.isEmpty || username.isEmpty || password.isEmpty)
            }
        }
    }
}

/// System snapshot, read-only process list and the app's own diagnostic log.
struct DiagnosticsView: View {
    @Environment(TerminalAppModel.self) private var model
    @State private var snapshot: SystemSnapshot?
    @State private var processes: ProcessListing?
    @State private var entries: [LogEntry] = []
    @State private var exportText = ""

    var body: some View {
        List {
            if let snapshot {
                Section("Device") {
                    ForEach(snapshot.lines, id: \.0) { row in LabeledContent(row.0, value: row.1) }
                }
            }
            Section("Processes") {
                switch processes {
                case .listed(let list, let complete)?:
                    if !complete { Text("The system shows only part of the process table to this app.").font(.footnote).foregroundStyle(.secondary) }
                    ForEach(list.prefix(400)) { process in
                        HStack {
                            Text("\(process.pid)").font(.caption.monospaced()).frame(width: 56, alignment: .leading)
                            Text(process.name)
                            Spacer()
                            Text("uid \(process.userID)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                case .restricted(let reason)?:
                    Text(reason).foregroundStyle(.secondary)
                case nil:
                    ProgressView()
                }
            }
            Section("Log") {
                ForEach(entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.level.label) · \(entry.category)").font(.caption.weight(.semibold))
                        Text(entry.message).font(.footnote)
                        if !entry.metadata.isEmpty {
                            Text(entry.metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                if !exportText.isEmpty { ShareLink("Export Log", item: exportText) }
            }
        }
        .navigationTitle("Diagnostics")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        snapshot = SystemSnapshot.capture(sandboxURL: model.dependencies.workspace.rootURL)
        processes = await Task.detached { ProcessInspector.listProcesses() }.value
        entries = await DiagnosticLog.shared.recent()
        exportText = await DiagnosticLog.shared.exportText()
    }
}
#endif
