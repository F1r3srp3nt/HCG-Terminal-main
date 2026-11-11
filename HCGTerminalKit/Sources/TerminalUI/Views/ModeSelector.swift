#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import TerminalCore

/// The animated [ Vanilla | Unleashed ] selector.
///
/// Interaction pattern follows HCG ONE's `ExperienceSwitcher` (Website | App): a capsule track
/// on `surface2` with a 1-pt `line` stroke and 2-pt inset, icon + label segments, `.snappy`
/// animation. HCG Terminal adds a sliding thumb (`matchedGeometryEffect`) filled with the mode
/// accent, selection haptics, and an availability dot for modes that are unavailable.
///
/// Selecting a mode only changes the preferred local mode. It never interrupts SSH sessions:
/// the selector has no access to sessions at all.
public struct ModeSelector: View {
    let selection: ExecutionMode
    /// `true` available, `false` unavailable, `nil` still detecting.
    let availability: (ExecutionMode) -> Bool?
    var compact: Bool
    let onSelect: (ExecutionMode) -> Void

    @Namespace private var thumbNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(selection: ExecutionMode, compact: Bool = false, availability: @escaping (ExecutionMode) -> Bool?, onSelect: @escaping (ExecutionMode) -> Void) {
        self.selection = selection
        self.compact = compact
        self.availability = availability
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(ExecutionMode.allCases) { mode in
                segment(mode)
            }
        }
        .padding(2)
        .background(HCGPalette.surface2, in: Capsule())
        .overlay(Capsule().strokeBorder(HCGPalette.line, lineWidth: 1))
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Local execution mode")
    }

    private func segment(_ mode: ExecutionMode) -> some View {
        let selected = selection == mode
        let available = availability(mode)
        return Button {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.28, extraBounce: 0.04)) {
                onSelect(mode)
            }
        } label: {
            HStack(spacing: 5) {
                if !compact {
                    Image(systemName: mode.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(mode.displayName)
                    .font(.system(size: compact ? 12 : 13, weight: .semibold))
                if available == false {
                    Circle()
                        .fill(selected ? Color.white.opacity(0.7) : HCGPalette.muted)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(selected ? Color.white : HCGPalette.ivory.opacity(0.7))
            .padding(.horizontal, compact ? 12 : 14)
            .frame(minHeight: compact ? 30 : 34)
            .background {
                if selected {
                    Capsule()
                        .fill(ModeAccent.gradient(mode))
                        .shadow(color: ModeAccent.color(mode).opacity(0.35), radius: 6, y: 1)
                        .matchedGeometryEffect(id: "mode-thumb", in: thumbNamespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel("\(mode.displayName) mode")
        .accessibilityHint(available == false ? "Not available in this environment" : mode.summary)
    }
}

/// One line explaining the active mode's capability state, shown under the selector.
struct ModeStatusLine: View {
    let mode: ExecutionMode
    let available: Bool?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(available == true ? ModeAccent.color(mode) : available == false ? HCGPalette.warn : HCGPalette.muted)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.footnote)
                .foregroundStyle(HCGPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        switch (mode, available) {
        case (_, nil): "Checking capabilities…"
        case (.vanilla, _): "Vanilla: sandboxed workspace and built-in commands. Remote development available."
        case (.unleashed, true?): "Unleashed: local capabilities available as reported. Nothing is elevated automatically."
        case (.unleashed, false?): "Unleashed features are not available in this environment. Vanilla terminal and remote development remain available."
        }
    }
}
#endif
