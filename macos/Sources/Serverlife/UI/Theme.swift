import SwiftUI
import CoreText
import AppKit

/// Design tokens ported 1:1 from Theme.xaml — same palette, same gradients,
/// same corner radii. Where WPF used a DropShadowEffect with an explicit
/// direction/depth/blur, this uses SwiftUI's .shadow(color:radius:x:y:) with
/// an equivalent offset computed from the same angle.
enum Theme {
    static let bg = Color(hex: 0xEDF1F6)
    static let surface = Color(hex: 0xF4F7FB)
    static let sunken = Color(hex: 0xE2E8F0)
    static let textHi = Color(hex: 0x131820)
    // Darkened from the original 0x59647A/0x94A0B4 for readability, per
    // direct feedback that the gray hint/caption text was too light.
    static let textMid = Color(hex: 0x434D60)
    static let textLo = Color(hex: 0x717D91)
    /// Background for the gallery tray — noticeably darker than the card
    /// (bg/surface/sunken) so the tray reads as a distinct, attached panel.
    static let trayBg = Color(hex: 0xD3DBE6)
    static let danger = Color(hex: 0xFF3B30)
    /// A touch darker than `danger` — used where a small persistent red
    /// dot (the gallery row's remove button) sits directly on light
    /// backgrounds and needs more contrast than the brighter hover-only red.
    static let dangerDeep = Color(hex: 0xE23A2E)
    static let good = Color(hex: 0x12B76A)
    static let warn = Color(hex: 0xF0A020)
    static let accentBlue = Color(hex: 0x2E6BF5)
    static let accentCyan = Color(hex: 0x22C3E6)
    static let shadowDark = Color(hex: 0xC0C9D8)
    static let insetEdgeTop = Color(hex: 0xC9D2E0)
    static let insetEdgeBottom = Color.white

    static let accent = LinearGradient(
        colors: [accentBlue, accentCyan],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let insetEdge = LinearGradient(
        colors: [insetEdgeTop, insetEdgeBottom],
        startPoint: .top, endPoint: .bottom)

    /// All four static weights share one family name ("Fira Sans Condensed"),
    /// differentiated only by subfamily — SwiftUI's `.weight()` modifier has
    /// no reliable way to pick among same-named faces, so each weight is
    /// referenced by its exact PostScript name instead.
    enum FiraWeight: String {
        case extraLight = "FiraSansCondensed-ExtraLight"
        case light = "FiraSansCondensed-Light"
        case regular = "FiraSansCondensed-Regular"
        case semibold = "FiraSansCondensed-SemiBold"
    }

    static func font(size: CGFloat, _ weight: FiraWeight = .light) -> Font {
        .custom(weight.rawValue, size: size)
    }

    // Dual "neumorphic" shadow used by chips, soft buttons, round icon
    // buttons, and the accent button — a dark shadow toward the bottom-right
    // (WPF Direction 315) and a light one toward the top-left (Direction 135).
    struct NeumorphicRaised: ViewModifier {
        var radius: CGFloat
        func body(content: Content) -> some View {
            content
                .shadow(color: shadowDark.opacity(0.55), radius: radius, x: radius * 0.5, y: radius * 0.5)
                .shadow(color: .white.opacity(0.9), radius: radius * 0.85, x: -radius * 0.4, y: -radius * 0.4)
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension View {
    func neumorphicRaised(radius: CGFloat = 5) -> some View {
        modifier(Theme.NeumorphicRaised(radius: radius))
    }
}

/// Registers the bundled Fira Sans Condensed static weights so `.custom(...)`
/// resolves them, matching the exe-embedded font on Windows. WPF has no
/// letter-spacing property and works around it (see Tracking.cs there);
/// SwiftUI's native `.tracking()` needs no such workaround.
enum FontRegistration {
    static let once: Void = {
        // Bundle.module's generated accessor resolves against
        // Bundle.main.bundleURL, which for a packaged .app is the .app's own
        // root — outside Contents, a location codesign won't seal. So the
        // packaged app carries its fonts in the proper Contents/Resources
        // instead, found via Bundle.main; Bundle.module is only reached
        // during `swift run`/`swift test`, where it resolves fine since
        // SwiftPM copies resources next to the bare debug/release binary.
        guard let fontsDir = Bundle.main.url(forResource: "Fonts", withExtension: nil)
            ?? Bundle.module.url(forResource: "Fonts", withExtension: nil)
        else { return }
        let names = ["FiraSansCondensed-ExtraLight", "FiraSansCondensed-Light",
                     "FiraSansCondensed-Regular", "FiraSansCondensed-SemiBold"]
        for name in names {
            let url = fontsDir.appendingPathComponent("\(name).ttf")
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        }
    }()

    static func ensureRegistered() { _ = once }
}
