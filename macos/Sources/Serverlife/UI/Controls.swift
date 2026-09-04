import SwiftUI

// MARK: - Segmented pill picker (SegmentTrack.cs)

/// A pill that slides behind whichever segment is selected — the pill lives
/// on the track (so it can animate between segments), not on the segments
/// themselves, exactly like SegmentTrack.cs's PART_Pill.
struct SegmentedPicker<T: Hashable>: View {
    let options: [(label: String, value: T)]
    @Binding var selection: T
    var height: CGFloat = 46

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.value) { option in
                segment(option)
            }
        }
        .padding(3)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.sunken)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.insetEdge, lineWidth: 1))
        )
    }

    @ViewBuilder
    private func segment(_ option: (label: String, value: T)) -> some View {
        let isSelected = selection == option.value
        ZStack {
            if isSelected {
                RoundedRectangle(cornerRadius: 13)
                    .fill(Theme.accent)
                    .shadow(color: Theme.accentBlue.opacity(0.5), radius: 6, x: 0, y: 2)
                    .matchedGeometryEffect(id: "pill", in: namespace)
            }
            Text(option.label)
                .font(Theme.font(size: 13.5, isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .white : Theme.textMid)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.18)) { selection = option.value }
        }
    }
}

// MARK: - Toggle switch (Switch style)

struct NeuToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            RoundedRectangle(cornerRadius: 16)
                .fill(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.sunken))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.insetEdge, lineWidth: isOn ? 0 : 1))
            Circle()
                .fill(Color.white)
                .padding(3)
                .shadow(color: Theme.shadowDark, radius: 3, x: 0, y: 2)
        }
        .frame(width: 56, height: 32)
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.18)) { isOn.toggle() }
        }
    }
}

// MARK: - Buttons

struct AccentButtonStyle: ButtonStyle {
    var height: CGFloat = 52
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(size: 16, .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Theme.accent)
                    .shadow(color: Theme.accentBlue.opacity(0.5), radius: 16, x: 0, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Color.white.opacity(configuration.isPressed ? 0 : 0.13))
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct SoftButtonStyle: ButtonStyle {
    var height: CGFloat = 52
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(size: 15, .semibold))
            .foregroundColor(configuration.isPressed ? Theme.textHi : Theme.textMid)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(configuration.isPressed ? Theme.sunken : Theme.surface)
                    .neumorphicRaised(radius: configuration.isPressed ? 0 : 5)
            )
    }
}

struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(size: 12, .semibold))
            .foregroundColor(configuration.isPressed ? Theme.accentBlue : Theme.textMid)
            .padding(.horizontal, 12)
            .frame(height: 27)
            .background(
                Capsule()
                    .fill(configuration.isPressed ? Theme.sunken : Theme.surface)
                    .neumorphicRaised(radius: configuration.isPressed ? 0 : 3)
            )
    }
}

struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(size: 12))
            .foregroundColor(configuration.isPressed ? Theme.accentBlue : Theme.textLo)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
    }
}

struct RoundIconButtonStyle: ButtonStyle {
    var size: CGFloat = 38
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(configuration.isPressed ? Theme.sunken : Theme.surface)
                    .neumorphicRaised(radius: configuration.isPressed ? 0 : 4)
            )
    }
}

/// The window's close (X) / options (cog) buttons — same geometry, different glyph.
struct RoundGlyphButton: View {
    enum Kind { case close, options }
    /// `.accent` is the main window's close button: red on hover. The
    /// gallery tray's own close button uses `.neutral` instead — a darker
    /// grey — per direct feedback that a secondary/tray-level close
    /// shouldn't carry the same "destructive" weight as the main window's.
    enum HoverStyle { case accent, neutral }
    var kind: Kind
    var hoverStyle: HoverStyle = .accent
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(hovering ? hoverFill : Theme.surface)
                    .neumorphicRaised(radius: hovering ? 0 : 5)
                glyph
            }
            .frame(width: 46, height: 46)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var hoverFill: Color {
        switch hoverStyle {
        case .accent: return kind == .close ? Theme.danger : Theme.good
        case .neutral: return Theme.textMid
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch kind {
        case .close:
            ZStack {
                Rectangle().fill(hovering ? Color.white : Theme.textMid)
                    .frame(width: 2.4, height: 15).rotationEffect(.degrees(45))
                Rectangle().fill(hovering ? Color.white : Theme.textMid)
                    .frame(width: 2.4, height: 15).rotationEffect(.degrees(-45))
            }
        case .options:
            Image(systemName: "gearshape.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(hovering ? .white : Theme.textMid)
        }
    }
}

// MARK: - Sunken panel / text field / progress / result card

struct SunkenPanel<Content: View>: View {
    var padding: EdgeInsets = EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16)
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Theme.sunken)
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.insetEdge, lineWidth: 1))
            )
    }
}

struct NeuTextField: View {
    @Binding var text: String
    var alignment: TextAlignment = .center
    var isReadOnly: Bool = false
    var font: Font = Theme.font(size: 15, .semibold)

    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .multilineTextAlignment(alignment)
            .font(font)
            .foregroundColor(Theme.textHi)
            .textFieldStyle(.plain)
            .disabled(isReadOnly)
            .focused($focused)
            .padding(.horizontal, 10)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Theme.sunken)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.insetEdge, lineWidth: 1))
                    if focused {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Theme.accentBlue.opacity(0.85), lineWidth: 2)
                    }
                }
            )
    }
}

struct NeuProgressBar: View {
    var progress: Double // 0...1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.sunken)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.insetEdge, lineWidth: 1))
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.accent)
                    .frame(width: max(12, geo.size.width * CGFloat(min(max(progress, 0), 1))))
            }
        }
        .frame(height: 12)
    }
}

struct ResultCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.surface)
                    .shadow(color: Theme.shadowDark.opacity(0.8), radius: 6, x: 3, y: 3)
            )
    }
}

// MARK: - Value-bubble slider (NeuSlider + BubbleThumb)

/// A slider whose thumb carries a floating value bubble above it, matching
/// BubbleThumb's "{0:0} px" tooltip-that-never-goes-away.
struct ValueBubbleSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 10

    @State private var dragging = false

    // The thumb's travel is inset from both track ends, rather than running
    // the full 0...width — so the bubble above it (roughly bubbleHalfWidth*2
    // wide) never needs to render past the track's own bounds in the first
    // place. The accent fill tracks the same inset position, so it visually
    // always reaches exactly to the thumb.
    private let edgeInset: CGFloat = 42
    // Separate from edgeInset on purpose, even though the two are close in
    // practice: this is what actually centers the bubble under its notch —
    // reusing edgeInset here previously (an easy mix-up, since both are
    // "roughly the bubble's half-width") offset the bubble by the wrong
    // amount, leaving its pointer not lined up with the thumb beneath it.
    private let bubbleHalfWidth: CGFloat = 40

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let usableWidth = max(0, width - edgeInset * 2)
            let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let thumbX = edgeInset + fraction * usableWidth

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.sunken)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.insetEdge, lineWidth: 1))
                    .frame(height: 12)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Theme.accent)
                    .frame(width: max(12, thumbX), height: 12)

                bubble
                    .offset(x: thumbX - bubbleHalfWidth, y: -38)

                ZStack {
                    Circle().fill(Theme.surface).frame(width: 30, height: 30)
                        .shadow(color: Theme.shadowDark, radius: 4, x: 0, y: 2)
                    Circle().fill(Color.white).frame(width: 28, height: 28)
                    Circle().fill(Theme.accent).frame(width: 13, height: 13)
                }
                .offset(x: thumbX - 15)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        let clampedX = min(max(edgeInset, drag.location.x), width - edgeInset)
                        let rawFraction = usableWidth > 0 ? Double((clampedX - edgeInset) / usableWidth) : 0
                        let raw = range.lowerBound + rawFraction * (range.upperBound - range.lowerBound)
                        value = (raw / step).rounded() * step
                        value = min(max(value, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(height: 30)
    }

    private var bubble: some View {
        VStack(spacing: 0) {
            // Text(verbatim:) is deliberate, not stylistic: Text("\(Int(value)) px")
            // — an interpolated literal passed directly to Text — resolves to the
            // LocalizedStringKey initializer, whose string interpolation
            // auto-formats interpolated numbers with the current locale's
            // grouping separator (e.g. "3.000" instead of "3000" under locales
            // that use "." for thousands). Confirmed via a real crash-course of
            // hands-on testing, not a hunch: this produced numbers like "1.920"
            // and "3.000" instead of "1920"/"3000".
            Text(verbatim: "\(Int(value)) px")
                .font(Theme.font(size: 12, .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.textHi))
            Triangle()
                .fill(Theme.textHi)
                .frame(width: 12, height: 7)
        }
        .fixedSize()
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Radio row (used nowhere yet, kept for parity with RadioRow style)

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.font(size: 11))
            .foregroundColor(Theme.textLo)
            .tracking(1.1) // ~0.1em at this size
    }
}
