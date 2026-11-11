#if canImport(UIKit) && canImport(SwiftUI)
import SwiftUI
import TerminalCore

extension Color {
    init(hcgHex hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// HCG design tokens. Surfaces, lines and text are taken from HCG ONE's `Palette`
/// (ios-hcg/HCGONE/Utilities/Theme.swift). HCG ONE's accent is silver; the Vanilla blue/green
/// pair reuses HCG ONE's `info` (0x5C8CC4) and `gain` (0x5E9C76) tokens. The Unleashed violet
/// is new to HCG Terminal and deliberately desaturated.
public enum HCGPalette {
    public static let canvas = Color(hcgHex: 0x08090B)
    public static let surface = Color(hcgHex: 0x0D0E10)
    public static let surface2 = Color(hcgHex: 0x1C1D21)
    public static let line = Color(hcgHex: 0x2A2C31)
    public static let ivory = Color(hcgHex: 0xF5F5F3)
    public static let muted = Color(hcgHex: 0x787B82)
    public static let silver = Color(hcgHex: 0xC5C7CB)
    public static let warn = Color(hcgHex: 0xC49A5C)
    public static let loss = Color(hcgHex: 0xC0524F)

    public static let vanillaBlue = Color(hcgHex: 0x5C8CC4)
    public static let vanillaGreen = Color(hcgHex: 0x5E9C76)
    public static let unleashedViolet = Color(hcgHex: 0x8A7FC4)
    public static let unleashedVioletDeep = Color(hcgHex: 0x5E5596)
}

/// Accent colors per execution target.
public enum ModeAccent {
    public static func gradient(_ mode: ExecutionMode) -> LinearGradient {
        switch mode {
        case .vanilla:
            LinearGradient(colors: [HCGPalette.vanillaBlue, HCGPalette.vanillaGreen], startPoint: .leading, endPoint: .trailing)
        case .unleashed:
            LinearGradient(colors: [HCGPalette.unleashedViolet, HCGPalette.unleashedVioletDeep], startPoint: .leading, endPoint: .trailing)
        }
    }

    public static func color(_ mode: ExecutionMode) -> Color {
        mode == .vanilla ? HCGPalette.vanillaBlue : HCGPalette.unleashedViolet
    }

    public static func color(_ target: ExecutionTarget) -> Color {
        switch target {
        case .local(let mode): color(mode)
        case .remote: HCGPalette.silver
        }
    }

    public static func symbol(_ target: ExecutionTarget) -> String {
        switch target {
        case .local(.vanilla): "iphone"
        case .local(.unleashed): "iphone.gen3.radiowaves.left.and.right"
        case .remote: "desktopcomputer"
        }
    }
}

/// Small uppercase label, as in HCG ONE.
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(HCGPalette.muted)
    }
}

/// Pill showing where a session executes: Local Vanilla, Local Unleashed or Remote Host.
struct TargetBadge: View {
    let target: ExecutionTarget

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: ModeAccent.symbol(target)).font(.system(size: 10, weight: .semibold))
            Text(target.label).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(ModeAccent.color(target))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(ModeAccent.color(target).opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(ModeAccent.color(target).opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Execution target: \(target.label), \(target.detail)")
    }
}
#endif
