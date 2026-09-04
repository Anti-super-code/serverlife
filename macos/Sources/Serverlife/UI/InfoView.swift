import AppKit
import ServerlifeCore
import SwiftUI

/// Direct port of TrayWindow.xaml's InfoPanel — the About & Settings screen that takes
/// over the panel's body and footer when the header's (i) button is tapped. Adapted
/// from Photokompressor's own InfoView.swift (same heart mark, same
/// about-blurb/links/toggle-row/CTA/version-line structure), with Serverlife's own copy
/// and its two toggles (no gallery-related setting exists here).
struct InfoView: View {
    @Binding var settings: AppSettings
    @Binding var shellRegistered: Bool
    @Binding var shellError: String?
    var onDismiss: () -> Void
    var onAlwaysOnTopChanged: (Bool) -> Void
    var onShellToggled: (Bool) -> Void

    private static let sourceURL = URL(string: "https://github.com/Anti-super-code/serverlife")!
    private static let homepageURL = URL(string: "https://antidot.gr")!

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    Text("Keeps your servers alive")
                        .font(Theme.font(size: 17, .light))
                        .foregroundColor(Theme.textHi)
                        .multilineTextAlignment(.center)
                        .frame(width: 300)

                    HeartbeatLogo()
                        .frame(width: 50, height: 46)
                        .padding(.top, 8)
                        .padding(.bottom, 10)

                    SectionLabel(text: "OPEN SOURCE")
                        .padding(.bottom, 8)

                    Text("Free and open source under the MIT licence. Serverlife only looks at your own machine — the ports it's listening on and the processes behind them — and never sends anything anywhere.")
                        .font(Theme.font(size: 12, .light))
                        .foregroundColor(Theme.textMid)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .frame(width: 300)

                    Button("View the source") { NSWorkspace.shared.open(Self.sourceURL) }
                        .buttonStyle(LinkButtonStyle())
                        .padding(.top, 6)

                    Text("Provided as is, without warranty. The Mine filter and the system tag are best-effort guesses from where a server runs — glance at a row before you stop it.")
                        .font(Theme.font(size: 11, .light))
                        .foregroundColor(Theme.textLo)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(width: 300)
                        .padding(.top, 12)

                    Button("Made by antidot.gr") { NSWorkspace.shared.open(Self.homepageURL) }
                        .buttonStyle(LinkButtonStyle())
                        .padding(.top, 10)

                    SunkenPanel {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Always on top")
                                    .font(Theme.font(size: 13, .semibold)).foregroundColor(Theme.textHi)
                                Text("Keep the panel above other windows while it's open")
                                    .font(Theme.font(size: 10.5, .light)).foregroundColor(Theme.textLo)
                            }
                            Spacer()
                            NeuToggle(isOn: Binding(
                                get: { settings.alwaysOnTop },
                                set: { settings.alwaysOnTop = $0; onAlwaysOnTopChanged($0) }))
                        }
                    }
                    .frame(width: 300)
                    .padding(.top, 20)

                    SunkenPanel {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Right-click menu")
                                    .font(Theme.font(size: 13, .semibold)).foregroundColor(Theme.textHi)
                                Text(shellHint)
                                    .font(Theme.font(size: 10.5, .light))
                                    .foregroundColor(shellError != nil ? Theme.danger : Theme.textLo)
                            }
                            Spacer()
                            NeuToggle(isOn: Binding(
                                get: { shellRegistered },
                                set: { onShellToggled($0) }))
                        }
                    }
                    .frame(width: 300)
                    .padding(.top, 10)
                }
                .padding(.top, 4)
            }

            VStack(spacing: 10) {
                Button("Server pamper") { onDismiss() }
                    .buttonStyle(AccentButtonStyle())
                Text(verbatim: "V.\(appVersion)")
                    .font(Theme.font(size: 10.5, .light))
                    .foregroundColor(Theme.textLo)
            }
            .padding(.top, 12)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private var shellHint: String {
        if let shellError { return "Couldn't update it — \(shellError)" }
        return shellRegistered
            ? "\u{201C}Start server here\u{201D} on any folder in Finder, from its Quick Actions menu"
            : "Drop a folder onto Serverlife instead, or pass it on the command line"
    }
}

/// A square stood on its corner, plus two circles matching its upper edges — the exact
/// shape Photokompressor's own HeartLogo draws — but this one beats continuously while
/// the panel is open: a lub-dub-rest cycle (two quick scale pulses close together, then
/// a longer rest), the SwiftUI counterpart of TrayWindow.xaml's HeartbeatStoryboard.
private struct HeartbeatLogo: View {
    @State private var scale: CGFloat = 1.0
    // Checked before every re-schedule so the recursive asyncAfter chain stops once
    // InfoView disappears — @State's storage is a shared box that outlives any one
    // struct copy, so without this guard the closures below would keep beating a
    // "ghost" heart (and waking the run loop every ~1s) forever after the panel closed.
    @State private var isAnimating = true

    var body: some View {
        Canvas { context, size in
            let s = size.width / 100
            let color = GraphicsContext.Shading.color(Theme.danger)

            var square = Path(CGRect(x: 22 * s, y: 22 * s, width: 56 * s, height: 56 * s))
            let center = CGPoint(x: (22 + 28) * s, y: (22 + 28) * s)
            let transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: .pi / 4)
                .translatedBy(x: -center.x, y: -center.y)
            square = square.applying(transform)
            context.fill(square, with: color)

            context.fill(Path(ellipseIn: CGRect(x: 2.2 * s, y: 2.2 * s, width: 56 * s, height: 56 * s)), with: color)
            context.fill(Path(ellipseIn: CGRect(x: 41.8 * s, y: 2.2 * s, width: 56 * s, height: 56 * s)), with: color)
        }
        .scaleEffect(scale)
        .onAppear { isAnimating = true; beat() }
        .onDisappear { isAnimating = false }
    }

    /// Two quick beats close together, then a longer rest — matches the WPF
    /// storyboard's 0/0.09/0.18/0.28/0.40/1.05s keyframe timings closely enough to read
    /// as the same rhythm without needing keyframe animation support SwiftUI lacks.
    private func beat() {
        guard isAnimating else { return }
        withAnimation(.easeOut(duration: 0.09)) { scale = 1.22 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
            guard isAnimating else { return }
            withAnimation(.easeIn(duration: 0.09)) { scale = 1.0 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            guard isAnimating else { return }
            withAnimation(.easeOut(duration: 0.12)) { scale = 1.14 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) {
            guard isAnimating else { return }
            withAnimation(.easeIn(duration: 0.12)) { scale = 1.0 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { beat() }
    }
}
