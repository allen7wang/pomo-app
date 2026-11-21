import SwiftUI

// MARK: - Ring timer (smooth / ticks / segmented, per skin tokens)

struct RingTimer: View {
    let progress: Double
    let text: String
    let caption: String
    let theme: AppTheme
    var size: CGFloat = 214
    /// Break phases draw in the rest color.
    var resting: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shownProgress: Double {
        #if DEBUG
        if let override = SkinPreviewArgs.progress { return override }
        #endif
        return progress
    }

    private var shownResting: Bool {
        #if DEBUG
        if SkinPreviewArgs.resting { return true }
        #endif
        return resting
    }

    var body: some View {
        let resting = shownResting
        ZStack {
            SkinRing(theme: theme, progress: shownProgress, tint: theme.phaseTint(resting: resting),
                     track: theme.phaseSoft(resting: resting), diameter: size, animated: !reduceMotion)
            VStack(spacing: size * 0.035) {
                digits
                Text(caption)
                    .font(.system(size: max(10, (size * 0.048).rounded())))
                    .foregroundColor(theme.muted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: size * 0.64)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityValue(text)
    }

    @ViewBuilder private var digits: some View {
        if theme.tokens.timerDesign == .pixel, PixelText.supports(text) {
            PixelText(text: text, cell: max(2, (size / 40).rounded()), color: theme.ink,
                      shadow: theme.phaseSoft(resting: shownResting))
        } else {
            Text(text)
                .font(theme.timerFont(size: size * digitScale))
                .foregroundColor(theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: text)
        }
    }

    private var digitScale: CGFloat {
        switch theme.tokens.timerDesign {
        case .monospaced, .pixel: return 0.235
        case .serif: return 0.27
        default: return 0.28
        }
    }
}

#if DEBUG
/// Screenshot-only overrides (`-previewProgress 0.62`, `-previewResting`) to inspect rings without running a timer.
enum SkinPreviewArgs {
    static let progress: Double? = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-previewProgress"), index + 1 < args.count else { return nil }
        return Double(args[index + 1])
    }()
    static let resting = ProcessInfo.processInfo.arguments.contains("-previewResting")
}
#endif

/// The ring alone; also drawn small inside skin previews.
struct SkinRing: View {
    let theme: AppTheme
    let progress: Double
    let tint: Color
    let track: Color
    let diameter: CGFloat
    var animated = true
    /// Token widths are specified for a 214pt ring; previews pass a smaller reference to stay legible.
    var reference: CGFloat = 214

    private var width: CGFloat { max(1.5, theme.tokens.ringWidth * diameter / reference) }
    private var value: Double { min(1, max(0, progress)) }

    var body: some View {
        Group {
            switch theme.tokens.ringStyle {
            case .smooth: smooth
            case .ticks: ticks
            case .segmented: segmented
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(animated ? .easeOut(duration: 0.35) : nil, value: value)
    }

    private var knobSize: CGFloat { theme.tokens.ringKnob ? width + max(5, width * 0.6) : 0 }
    private var glowRadius: CGFloat { theme.tokens.ringGlow ? max(4, width * 2.4) : 0 }

    private var smooth: some View {
        let inset = max(width, knobSize) / 2
        return ZStack {
            Circle().inset(by: inset)
                .stroke(track, lineWidth: width)
            Circle().inset(by: inset)
                .trim(from: 0, to: max(0.001, value))
                .stroke(tint, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(theme.tokens.ringGlow ? 0.7 : 0), radius: glowRadius)
                .opacity(value > 0 || theme.tokens.ringKnob ? 1 : 0)
            if theme.tokens.ringKnob {
                Circle()
                    .fill(tint)
                    .overlay(Circle().strokeBorder(theme.background, lineWidth: max(1.5, knobSize * 0.16)))
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: tint.opacity(theme.tokens.ringGlow ? 0.8 : 0), radius: glowRadius)
                    .offset(y: -(diameter / 2 - inset))
                    .rotationEffect(.degrees(360 * value))
            }
        }
    }

    private var ticks: some View {
        let count = diameter < 90 ? 30 : 60
        let major = max(3, diameter * 0.065)
        let minor = max(2, diameter * 0.034)
        let style = StrokeStyle(lineWidth: width, lineCap: .round)
        return ZStack {
            TickRingShape(progress: value, count: count, lit: false, major: major, minor: minor)
                .stroke(theme.line, style: style)
            TickRingShape(progress: value, count: count, lit: true, major: major, minor: minor)
                .stroke(tint, style: style)
        }
        .padding(width / 2)
    }

    private var segmented: some View {
        let count = diameter < 90 ? 12 : 24
        let style = StrokeStyle(lineWidth: width, lineCap: .butt)
        return ZStack {
            SegmentRingShape(progress: value, count: count, lit: false)
                .stroke(theme.line, style: style)
            SegmentRingShape(progress: value, count: count, lit: true)
                .stroke(tint, style: style)
        }
        .padding(width / 2)
    }
}

/// 60 radial ticks; the first `progress` share light up. Animatable so ticks reveal in order.
private struct TickRingShape: Shape {
    var progress: Double
    let count: Int
    let lit: Bool
    let major: CGFloat
    let minor: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let litCount = progress > 0 ? Int((progress * Double(count)).rounded(.up)) : 0
        for index in 0..<count where (index < litCount) == lit {
            let length = index % 5 == 0 ? major : minor
            let angle = Double(index) / Double(count) * 2 * .pi - .pi / 2
            let direction = CGPoint(x: cos(angle), y: sin(angle))
            path.move(to: CGPoint(x: center.x + direction.x * radius, y: center.y + direction.y * radius))
            path.addLine(to: CGPoint(x: center.x + direction.x * (radius - length),
                                     y: center.y + direction.y * (radius - length)))
        }
        return path
    }
}

/// Discrete square-capped blocks around the ring (pixel).
private struct SegmentRingShape: Shape {
    var progress: Double
    let count: Int
    let lit: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let step = 360.0 / Double(count)
        let gap = min(4, step * 0.28)
        let litCount = progress > 0 ? Int((progress * Double(count)).rounded(.up)) : 0
        for index in 0..<count where (index < litCount) == lit {
            let start = Double(index) * step - 90 + gap / 2
            let radians = start * .pi / 180
            // addArc would otherwise bridge from the previous block's end, closing the gaps.
            path.move(to: CGPoint(x: center.x + cos(radians) * radius, y: center.y + sin(radians) * radius))
            path.addArc(center: center, radius: radius, startAngle: .degrees(start),
                        endAngle: .degrees(start + step - gap), clockwise: false)
        }
        return path
    }
}

/// 5×7 bitmap digits drawn as crisp squares; callers fall back to text for unsupported characters.
struct PixelText: View {
    let text: String
    let cell: CGFloat
    let color: Color
    var shadow: Color? = nil

    static func supports(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { PixelGlyphs.table[$0] != nil }
    }

    var body: some View {
        let glyphs = text.compactMap { PixelGlyphs.table[$0] }
        let columns = glyphs.reduce(0) { $0 + ($1.first?.count ?? 0) } + max(0, glyphs.count - 1)
        let drop: CGFloat = shadow == nil ? 0 : max(1, (cell / 2).rounded(.down))
        return Canvas { context, _ in
            var path = Path()
            var x = 0
            for glyph in glyphs {
                for (row, bits) in glyph.enumerated() {
                    for (column, bit) in bits.enumerated() where bit == "1" {
                        path.addRect(CGRect(x: CGFloat(x + column) * cell, y: CGFloat(row) * cell,
                                            width: cell, height: cell))
                    }
                }
                x += (glyph.first?.count ?? 0) + 1
            }
            if let shadow {
                context.fill(path.offsetBy(dx: drop, dy: drop), with: .color(shadow))
            }
            context.fill(path, with: .color(color))
        }
        .frame(width: CGFloat(columns) * cell + drop, height: CGFloat(PixelGlyphs.height) * cell + drop)
        .accessibilityLabel(text)
    }
}

// MARK: - Small shared pieces

/// Whole-card buttons: hover lifts the wash slightly; pressing dims, or sinks into the hard shadow on pixel.
struct SkinCardButtonStyle: ButtonStyle {
    let theme: AppTheme

    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration, theme: theme)
    }

    private struct CardBody: View {
        let configuration: ButtonStyleConfiguration
        let theme: AppTheme
        @State private var hovering = false

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .overlay(theme.cardShape.fill(theme.ink.opacity(pressed ? 0.06 : (hovering ? 0.03 : 0))).allowsHitTesting(false))
                .offset(x: theme.hardShadow && pressed ? 1 : 0, y: theme.hardShadow && pressed ? 1 : 0)
                .onHover { hovering = $0 }
        }
    }
}

/// Thin determinate bar in the skin's corner language.
struct SkinProgressBar: View {
    @Environment(\.appTheme) private var theme
    let value: Double
    let total: Double
    var tint: Color? = nil
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                theme.chipShape.fill(theme.subtle)
                theme.chipShape.fill(tint ?? theme.accent)
                    .frame(width: max(0, min(1, value / max(total, 0.001))) * geo.size.width)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Skin picker (Mac header popover, iOS toolbar sheet, settings)

/// Mini card of a skin drawn in its own tokens: background wash, an accent ring arc and a rest dot.
struct SkinSwatch: View {
    let theme: AppTheme
    var size: CGFloat = 48

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(theme.cardRadius, size * 0.26), style: .continuous)
        ZStack {
            theme.pageBackground
            SkinRing(theme: theme, progress: 0.62, tint: theme.accent, track: theme.accentSoft,
                     diameter: size * 0.64, animated: false, reference: 96)
            theme.dotShape
                .fill(theme.rest)
                .frame(width: size * 0.15, height: size * 0.15)
                .offset(x: size * 0.33, y: size * 0.33)
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(theme.cardStroke ?? theme.line, lineWidth: theme.tokens.cardBorder == .ink ? 2 : 1))
        .accessibilityHidden(true)
    }
}

/// One skin rendered in its own palette and title face.
struct SkinOptionRow: View {
    let style: AppUIStyle
    let dark: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let preview = AppTheme(style: style, dark: dark)
        Button(action: action) {
            HStack(spacing: 12) {
                SkinSwatch(theme: preview, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(style.title)
                            .font(preview.titleFont(size: 15))
                            .foregroundColor(preview.ink)
                        if preview.tokens.forcedScheme == .dark {
                            Text("仅深色")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(preview.muted)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(preview.chipShape.fill(preview.subtle))
                        }
                    }
                    Text(style.tagline)
                        .font(.system(size: 11))
                        .foregroundColor(preview.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundColor(selected ? preview.accent : preview.line)
            }
            .padding(10)
            .background(
                SkinSurface(theme: preview, fill: preview.background, radius: min(preview.cardRadius, 14),
                            stroke: selected ? preview.accent : (preview.cardStroke ?? preview.line),
                            strokeWidth: selected ? 2 : max(1, preview.borderWidth), elevated: preview.hardShadow)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(style.title)，\(style.tagline)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

struct SkinPickerList: View {
    @ObservedObject private var styleStore = UIStyleStore.shared
    @Environment(\.colorScheme) private var colorScheme
    var spacing: CGFloat = 8

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(AppUIStyle.allCases) { style in
                SkinOptionRow(style: style, dark: colorScheme == .dark, selected: styleStore.style == style) {
                    styleStore.style = style
                }
            }
        }
    }
}

struct SkinPaletteButton: View {
    @Environment(\.appTheme) private var theme
    @State private var showPicker = false

    var body: some View {
        Button { showPicker = true } label: {
            Image(systemName: "paintpalette")
                #if os(macOS)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
                #else
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 36)
                #endif
                .foregroundColor(theme.muted)
                .contentShape(Rectangle())
        }
        #if os(macOS)
        .buttonStyle(SkinPlainButtonStyle(theme: theme))
        .help("切换界面风格")
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("界面风格")
                        .font(.system(size: 13, weight: .semibold))
                    SkinPickerList()
                }
                .padding(14)
            }
            .frame(width: 330, height: 560)
            .appSkin()
        }
        #else
        .buttonStyle(.plain)
        .sheet(isPresented: $showPicker) { SkinPickerSheet() }
        #endif
        .accessibilityLabel("切换界面风格")
    }
}

#if os(iOS)
private struct SkinPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SkinPickerSheetContent()
                .navigationTitle("界面风格")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .appSkin()
    }
}

private struct SkinPickerSheetContent: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("选择保存在本机，不影响任务、计时或同步。")
                    .font(.caption)
                    .foregroundColor(theme.muted)
                SkinPickerList()
            }
            .padding(16)
        }
        .background(theme.pageBackground.ignoresSafeArea())
        .toolbarBackground(theme.background, for: .navigationBar)
    }
}
#endif

struct AppearanceStylePicker: View {
    @ObservedObject private var styleStore = UIStyleStore.shared
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(AppUIStyle.allCases.count) 套皮肤可随时切换。选择保存在本机，不影响任务、计时或同步。")
                .font(.caption)
                .foregroundColor(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            SkinPickerList()
            Text("当前：\(styleStore.style.title)。各页右上角的调色板也可以切换。")
                .font(.caption2)
                .foregroundColor(theme.muted)
        }
    }
}
