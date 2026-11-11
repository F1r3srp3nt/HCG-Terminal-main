#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import TerminalCapabilityProvider
import TerminalCore

enum SidebarItem: Hashable {
    case session(SessionID)
    case hosts
    case builds
    case artifacts
    case unleashedTools
    case preferences
    case diagnostics
}

/// Root of HCG Terminal. Split view on iPad, stack on iPhone (NavigationSplitView adapts).
public struct RootView: View {
    @State private var model: TerminalAppModel
    @State private var selection: SidebarItem?
    @State private var showNewRemote = false
    @State private var showLoopback = false

    public init(model: TerminalAppModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .environment(model)
        .tint(ModeAccent.color(model.preferredMode))
        .preferredColorScheme(.dark)
        .task { await model.bootstrap() }
        .onChange(of: model.selectedSessionID) { _, id in
            if let id { selection = .session(id) }
        }
        .sheet(item: $model.authorizationPrompt) { prompt in
            AuthorizationSheet(request: prompt.request).environment(model)
        }
        .sheet(item: $model.hostKeyPrompt) { prompt in
            HostKeySheet(prompt: prompt.request).environment(model)
        }
        .sheet(item: $model.modeSwitchConfirmation) { confirmation in
            ModeSwitchConfirmationSheet(confirmation: confirmation).environment(model)
        }
        .sheet(isPresented: $showNewRemote) {
            NavigationStack { HostPickerView { host in
                showNewRemote = false
                Task { await model.openRemoteShell(host) }
            } }
            .environment(model)
        }
        .sheet(isPresented: $showLoopback) {
            NavigationStack { LoopbackServiceSheet() }.environment(model)
        }
        .alert("HCG Terminal", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    ModeSelector(selection: model.preferredMode, availability: availability) { model.selectMode($0) }
                    ModeStatusLine(mode: model.preferredMode, available: availability(model.preferredMode))
                }
                .listRowBackground(Color.clear)
            } header: { Eyebrow("Local mode") }

            Section {
                ForEach(model.sessions) { session in
                    NavigationLink(value: SidebarItem.session(session.id)) {
                        SessionRow(session: session)
                    }
                    .contextMenu {
                        Button("Close", role: .destructive) { Task { await model.closeSession(session.id) } }
                    }
                }
                Menu {
                    Button {
                        Task { await model.openLocalSession() }
                    } label: {
                        Label("Local \(model.preferredMode.displayName) Session", systemImage: "iphone")
                    }
                    .disabled(!model.isAvailable(model.preferredMode))
                    if model.dependencies.distribution == .unleashed {
                        Button { showLoopback = true } label: {
                            Label("Connect to Local Terminal Service", systemImage: "network.badge.shield.half.filled")
                        }
                        .disabled(!model.isAvailable(.unleashed))
                    }
                    Button { showNewRemote = true } label: {
                        Label("Remote Host Session", systemImage: "desktopcomputer")
                    }
                } label: {
                    Label("New Session", systemImage: "plus.circle")
                }
            } header: { Eyebrow("Sessions") }

            Section {
                NavigationLink(value: SidebarItem.hosts) { Label("Hosts & Projects", systemImage: "server.rack") }
                NavigationLink(value: SidebarItem.builds) { Label("Builds & Tests", systemImage: "hammer") }
                NavigationLink(value: SidebarItem.artifacts) { Label("Artifacts", systemImage: "shippingbox") }
            } header: { Eyebrow("Remote development") }

            Section {
                if model.dependencies.distribution == .unleashed {
                    NavigationLink(value: SidebarItem.unleashedTools) { Label("Unleashed Tools", systemImage: "wrench.and.screwdriver") }
                }
                NavigationLink(value: SidebarItem.diagnostics) { Label("Diagnostics", systemImage: "stethoscope") }
                NavigationLink(value: SidebarItem.preferences) { Label("Preferences", systemImage: "gearshape") }
            } header: { Eyebrow("Device") }
        }
        .navigationTitle("HCG Terminal")
        .scrollContentBackground(.hidden)
        .background(HCGPalette.canvas)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .session(let id):
            if let session = model.session(id) {
                SessionScreen(session: session)
            } else {
                emptyState
            }
        case .hosts: NavigationStack { HostsView() }
        case .builds: NavigationStack { BuildsView() }
        case .artifacts: NavigationStack { ArtifactsView() }
        case .unleashedTools: NavigationStack { UnleashedToolsView() }
        case .preferences: NavigationStack { PreferencesView() }
        case .diagnostics: NavigationStack { DiagnosticsView() }
        case nil: emptyState
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Session Selected", systemImage: "terminal")
        } description: {
            Text("Open a local \(model.preferredMode.displayName) session or connect to a remote host.")
        } actions: {
            Button("New Local Session") { Task { await model.openLocalSession() } }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isAvailable(model.preferredMode))
        }
        .background(HCGPalette.canvas)
    }

    private func availability(_ mode: ExecutionMode) -> Bool? {
        model.report(for: mode).map { _ in model.isAvailable(mode) }
    }
}

struct SessionRow: View {
    let session: SessionModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ModeAccent.symbol(session.target))
                .foregroundStyle(ModeAccent.color(session.target))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).lineLimit(1)
                Text("\(session.target.label) · \(session.state.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Preferences: mode setting, capability status for both modes, build information.
struct PreferencesView: View {
    @Environment(TerminalAppModel.self) private var model

    var body: some View {
        List {
            Section {
                ModeSelector(selection: model.preferredMode, availability: { mode in
                    model.report(for: mode).map { _ in model.isAvailable(mode) }
                }) { model.selectMode($0) }
                .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(ExecutionMode.allCases) { mode in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(ModeAccent.color(mode))
                        Text(mode.summary).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Preferred local mode") } footer: {
                Text("Saved on this device. Applies to new local sessions. Remote sessions are never affected.")
            }

            ForEach(ExecutionMode.allCases) { mode in
                if let report = model.report(for: mode) {
                    CapabilityReportView(report: report)
                }
            }

            Section("This build") {
                LabeledContent("Distribution", value: model.dependencies.distribution.label)
                Text(model.dependencies.distribution == .standard
                    ? "Standard build for ordinary iOS and iPadOS distribution. The Unleashed backend is not included."
                    : "Unleashed build for supported devices. It is distributed separately and is not assumed to be eligible for the App Store.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("HCG Terminal never publishes to TestFlight, App Store Connect or any other channel.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Security") {
                NavigationLink("SSH Keys") { KeysView() }
                NavigationLink("Known Hosts") { KnownHostsView() }
            }
        }
        .navigationTitle("Preferences")
        .refreshable { await model.refreshCapabilities() }
        .toolbar {
            Button { Task { await model.refreshCapabilities() } } label: {
                if model.isDetecting { ProgressView() } else { Label("Re-check", systemImage: "arrow.clockwise") }
            }
        }
    }
}
#endif
