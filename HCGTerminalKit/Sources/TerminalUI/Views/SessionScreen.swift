#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import TerminalCapabilityProvider
import TerminalCore

/// A terminal session: header (target, mode selector, actions), notices and the terminal.
struct SessionScreen: View {
    @Environment(TerminalAppModel.self) private var model
    let session: SessionModel
    @State private var showDetails = false
    @State private var confirmClose = false

    var body: some View {
        VStack(spacing: 0) {
            SessionHeader(session: session, showDetails: $showDetails, confirmClose: $confirmClose)
            ForEach(session.notices, id: \.self) { notice in
                NoticeBanner(notice: notice) { session.dismissNotice(notice) }
            }
            TerminalHostView(session: session, accent: ModeAccent.color(session.target))
                .id(session.id)
                .background(HCGPalette.canvas)
        }
        .background(HCGPalette.canvas)
        .sheet(isPresented: $showDetails) {
            NavigationStack { SessionDetailsView(session: session) }
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Close this session?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Close Session", role: .destructive) { Task { await model.closeSession(session.id) } }
        } message: {
            Text(session.target.isLocal
                ? "Anything running in this local session stops."
                : "Only this session's channel closes. The SSH connection and other sessions stay open.")
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct SessionHeader: View {
    @Environment(TerminalAppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    let session: SessionModel
    @Binding var showDetails: Bool
    @Binding var confirmClose: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(HCGPalette.ivory)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        TargetBadge(target: session.target)
                        Text(session.target.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(HCGPalette.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if sizeClass == .regular { selector }
                Button { session.interrupt() } label: { Image(systemName: "stop.circle") }
                    .accessibilityLabel("Interrupt (Control-C)")
                    .disabled(!session.isLive)
                Button { showDetails = true } label: { Image(systemName: "info.circle") }
                    .accessibilityLabel("Session details")
                Button { confirmClose = true } label: { Image(systemName: "xmark.circle") }
                    .accessibilityLabel("Close session")
            }
            .font(.system(size: 18))
            .foregroundStyle(HCGPalette.silver)
            if sizeClass != .regular { selector }
            ModeStatusLine(mode: model.preferredMode, available: availability(model.preferredMode))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(HCGPalette.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(HCGPalette.line).frame(height: 1) }
    }

    private var selector: some View {
        ModeSelector(selection: model.preferredMode, compact: sizeClass != .regular, availability: availability) { mode in
            model.selectMode(mode)
        }
    }

    private func availability(_ mode: ExecutionMode) -> Bool? {
        model.report(for: mode).map { _ in model.isAvailable(mode) }
    }
}

struct NoticeBanner: View {
    let notice: TerminalNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: notice.kind == .error ? "exclamationmark.octagon" : notice.kind == .warning ? "exclamationmark.triangle" : "info.circle")
            Text(notice.message).font(.footnote).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }.accessibilityLabel("Dismiss")
        }
        .foregroundStyle(notice.kind == .info ? HCGPalette.silver : HCGPalette.warn)
        .padding(10)
        .background(HCGPalette.surface2)
    }
}

/// Session details: target, backend, the session's mode and the current preferred mode.
struct SessionDetailsView: View {
    @Environment(TerminalAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: SessionModel

    var body: some View {
        List {
            Section("Execution") {
                LabeledContent("Target", value: session.target.label)
                LabeledContent("Where", value: session.target.detail)
                LabeledContent("Backend", value: session.backend.label)
                LabeledContent("Session mode", value: sessionMode)
                LabeledContent("Active local mode", value: model.preferredMode.displayName)
            }
            Section("State") {
                LabeledContent("Status", value: session.state.label)
                LabeledContent("Opened", value: session.createdAt.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Last activity", value: session.lastActivity.formatted(date: .omitted, time: .standard))
                if let directory = session.workingDirectory { LabeledContent("Directory", value: directory) }
                LabeledContent("Session ID", value: session.id.description)
            }
            Section {
                Text(explanation).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Session Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private var sessionMode: String {
        switch session.target {
        case .local(let mode): mode.displayName
        case .remote: "Remote (independent of local mode)"
        }
    }

    private var explanation: String {
        switch session.target {
        case .local(let mode) where mode != model.preferredMode:
            "This session keeps running in \(mode.displayName). Changing the local mode only affects new sessions unless you confirm moving this one, which starts a fresh session; nothing running is transferred."
        case .local:
            "Commands typed here run on this device in the environment shown above. They are never sent to a remote host."
        case .remote:
            "Commands typed here run on the remote host. Switching the local mode never interrupts this session."
        }
    }
}

/// Capability status for one mode: headline plus one row per capability with its evidence.
struct CapabilityReportView: View {
    let report: CapabilityReport

    var body: some View {
        Section {
            Text(report.headline)
                .font(.subheadline)
                .foregroundStyle(report.localFeaturesAvailable ? ModeAccent.color(report.mode) : HCGPalette.warn)
            ForEach(report.results) { result in
                DisclosureGroup {
                    if let detail = result.availability.detail {
                        Text(detail).font(.footnote)
                    }
                    Text(result.summary).font(.footnote).foregroundStyle(.secondary)
                    ForEach(Array(result.evidence.enumerated()), id: \.offset) { _, evidence in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: evidence.positive ? "checkmark.circle" : "minus.circle")
                                .foregroundStyle(evidence.positive ? HCGPalette.vanillaGreen : HCGPalette.muted)
                            VStack(alignment: .leading) {
                                Text(evidence.probe).font(.caption.monospaced())
                                Text(evidence.observation).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Label(result.kind.title, systemImage: result.kind.symbolName)
                        Spacer()
                        AvailabilityPill(availability: result.availability)
                    }
                }
            }
            ForEach(report.buildNotes, id: \.self) { note in
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("\(report.mode.displayName) capabilities")
        } footer: {
            Text("Detected \(report.generatedAt.formatted(date: .omitted, time: .standard)). Detection is read-only and never requests privileges.")
        }
    }
}

struct AvailabilityPill: View {
    let availability: CapabilityAvailability

    var body: some View {
        Text(availability.label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }

    private var color: Color {
        switch availability {
        case .available: HCGPalette.vanillaGreen
        case .limited, .unverified: HCGPalette.vanillaBlue
        case .requiresAuthorization: HCGPalette.warn
        case .unavailable: HCGPalette.muted
        }
    }
}
#endif
