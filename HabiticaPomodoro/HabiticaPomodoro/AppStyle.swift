import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Skins (user-switchable; Mac and iOS share every skin)
// Palettes, shapes, type and ring tokens come from design/skins.json via the generated SkinTokens.swift.

enum AppUIStyle: String, CaseIterable, Identifiable {
    // Declaration order is the picker order and must match SkinCatalog.all.
    case mint, garden, studio, tomato, midnight, pixel, sakura

    var id: String { rawValue }

    var tokens: SkinTokens { Self.catalog[self] ?? SkinCatalog.all[0] }

    var title: String { tokens.title }
    var tagline: String { tokens.tagline }
    var symbol: String { tokens.symbol }
    var layout: SkinLayout { tokens.layout }
    var windowSize: CGSize { AppTheme.metrics(for: layout).macWindow }

    private static let catalog: [AppUIStyle: SkinTokens] = Dictionary(
        uniqueKeysWithValues: SkinCatalog.all.compactMap { skin in AppUIStyle(rawValue: skin.id).map { ($0, skin) } })
}

final class UIStyleStore: ObservableObject {
    static let shared = UIStyleStore()
    private static let storageKey = "app.uiStyle.v1"

    @Published var style: AppUIStyle {
        didSet {
            UserDefaults.standard.set(style.rawValue, forKey: Self.storageKey)
            applyForcedAppearance()
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? ""
        style = AppUIStyle(rawValue: raw) ?? .mint
    }

    /// Forced-scheme skins override the whole app (sheets, alerts, menus); the rest follow the system.
    func applyForcedAppearance() {
        let forced = style.tokens.forcedScheme
        #if os(macOS)
        guard let app = NSApp else { return }
        switch forced {
        case .dark?: app.appearance = NSAppearance(named: .darkAqua)
        case .light?: app.appearance = NSAppearance(named: .aqua)
        case nil: app.appearance = nil
        }
        #else
        let interface: UIUserInterfaceStyle
        switch forced {
        case .dark?: interface = .dark
        case .light?: interface = .light
        case nil: interface = .unspecified
        }
        // preferredColorScheme(nil) does not reliably hand control back to the system, so drive the windows directly.
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows where window.overrideUserInterfaceStyle != interface {
                window.overrideUserInterfaceStyle = interface
            }
        }
        #endif
    }
}

// MARK: - Theme (one skin resolved for the current light/dark scheme)

struct AppTheme {
    let style: AppUIStyle
    /// Effective scheme: forced skins stay dark even when the system is light.
    let dark: Bool
    let tokens: SkinTokens

    let background: Color
    let backgroundAlt: Color
    let surface: Color
    let subtle: Color
    let line: Color
    let ink: Color
    let muted: Color
    let accent: Color
    let accentSoft: Color
    let onAccent: Color
    /// Break-phase color; never put onAccent text on it.
    let rest: Color
    let restSoft: Color
    /// Abandon, wither, negative habit and destructive actions.
    let danger: Color
    /// Streaks, combos, gold and trees. Only for icons or large text (3:1 on surface).
    let highlight: Color

    init(style: AppUIStyle, dark systemDark: Bool) {
        let tokens = style.tokens
        let dark: Bool
        switch tokens.forcedScheme {
        case .dark?: dark = true
        case .light?: dark = false
        case nil: dark = systemDark
        }
        self.style = style
        self.dark = dark
        self.tokens = tokens
        let p = dark ? tokens.dark : tokens.light
        background = Color(appHex: p.background)
        backgroundAlt = Color(appHex: p.backgroundAlt)
        surface = Color(appHex: p.surface)
        subtle = Color(appHex: p.subtle)
        line = Color(appHex: p.line)
        ink = Color(appHex: p.ink)
        muted = Color(appHex: p.muted)
        accent = Color(appHex: p.accent)
        accentSoft = Color(appHex: p.accentSoft)
        onAccent = Color(appHex: p.onAccent)
        rest = Color(appHex: p.rest)
        restSoft = Color(appHex: p.restSoft)
        danger = Color(appHex: p.danger)
        highlight = Color(appHex: p.highlight)
    }

    // Layout

    var layout: SkinLayout { tokens.layout }

    static func metrics(for layout: SkinLayout) -> SkinLayoutTokens {
        SkinCatalog.layouts[layout] ?? SkinLayoutTokens(pageInset: 22, pageSpacing: 14, cardPadding: 14, rowSpacing: 8,
                                                         macWindow: CGSize(width: 470, height: 820))
    }

    private var metrics: SkinLayoutTokens { Self.metrics(for: layout) }
    var pageInset: CGFloat { metrics.pageInset }
    var pageSpacing: CGFloat { metrics.pageSpacing }
    var cardPadding: CGFloat { metrics.cardPadding }
    var rowSpacing: CGFloat { metrics.rowSpacing }
    var macWindowSize: CGSize { metrics.macWindow }

    /// Side-by-side columns only fit a regular width. iPhone stays stacked.
    func showsColumns(compactWidth: Bool) -> Bool {
        layout == .columns && !compactWidth
    }

    // Shape

    var cardRadius: CGFloat { tokens.cardRadius }
    var controlRadius: CGFloat { tokens.controlRadius }
    var borderWidth: CGFloat { tokens.borderWidth }
    var squareCorners: Bool { tokens.cardRadius == 0 }
    /// Hard shadows are solid offset blocks (pixel); everything else blurs.
    var hardShadow: Bool { tokens.shadow.radius == 0 && tokens.shadow.opacity > 0 }
    var hardShadowOffset: CGSize { CGSize(width: tokens.shadow.x, height: tokens.shadow.y) }

    var cardStroke: Color? {
        switch tokens.cardBorder {
        case .none: return nil
        case .line: return line
        case .ink: return ink
        }
    }

    /// Controls keep a visible edge even on borderless skins.
    var controlStroke: Color { tokens.cardBorder == .ink ? ink : line }
    var controlStrokeWidth: CGFloat { tokens.cardBorder == .ink ? tokens.borderWidth : 1 }

    var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: cardRadius, style: .continuous) }
    var controlShape: RoundedRectangle { RoundedRectangle(cornerRadius: controlRadius, style: .continuous) }

    /// Icon wells, cells and bars: the control radius, capped so small pieces do not turn into pills.
    func smallShape(_ cap: CGFloat = 8) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: min(controlRadius, cap), style: .continuous)
    }

    /// Chips and status capsules; square skins keep square chips.
    var chipShape: AnyShape { squareCorners ? AnyShape(Rectangle()) : AnyShape(Capsule()) }
    /// Dots, avatars and wells that are round on soft skins.
    var dotShape: AnyShape { squareCorners ? AnyShape(Rectangle()) : AnyShape(Circle()) }

    /// Blurred shadow for soft/lifted skins. Light-colored ink would glow in dark mode, so dark uses black.
    var blurShadow: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat)? {
        let s = tokens.shadow
        guard s.opacity > 0, s.radius > 0 else { return nil }
        if dark { return (Color.black.opacity(min(0.45, s.opacity * 4)), s.radius, s.x, s.y) }
        return ((s.color == .accent ? accent : ink).opacity(s.opacity), s.radius, s.x, s.y)
    }

    var hardShadowColor: Color {
        // Dark pixel ink is near-white; a light block would read as a second border, so darken it instead.
        dark ? Color.black.opacity(0.55) : (tokens.shadow.color == .accent ? accent : ink)
    }

    // Color helpers

    func phaseTint(resting: Bool) -> Color { resting ? rest : accent }
    func phaseSoft(resting: Bool) -> Color { resting ? restSoft : accentSoft }

    /// Checkbox glyphs follow the corner language (square on pixel).
    func checkSymbol(_ done: Bool) -> String {
        squareCorners ? (done ? "checkmark.square.fill" : "square") : (done ? "checkmark.circle.fill" : "circle")
    }

    // Type

    func titleFont(size: CGFloat, weight: SkinFontWeight? = nil) -> Font {
        SkinTypography.font(size: size, weight: weight ?? tokens.titleWeight, design: tokens.titleDesign)
    }

    /// Card and section headings: the title face, never lighter than medium.
    func sectionFont(size: CGFloat) -> Font {
        let w = tokens.titleWeight
        let weight: SkinFontWeight = (w == .thin || w == .light || w == .regular) ? .medium : w
        return SkinTypography.font(size: size, weight: weight, design: tokens.titleDesign)
    }

    func timerFont(size: CGFloat) -> Font {
        Font.system(size: size, weight: SkinTypography.weight(tokens.timerWeight),
                    design: SkinTypography.design(tokens.timerDesign)).monospacedDigit()
    }

    /// Counters and metrics share the timer's face so numbers read the same across a skin. Monospaced and
    /// pixel faces stay on the timer only: their wide spaces break up mixed strings like "第 1 / 4 个".
    func numberFont(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        let design: Font.Design
        switch tokens.timerDesign {
        case .serif: design = .serif
        case .rounded: design = .rounded
        case .default, .monospaced, .pixel: design = .default
        }
        return Font.system(size: size, weight: weight, design: design).monospacedDigit()
    }

    // Background

    /// Vertical wash from background to backgroundAlt; pixel stays flat.
    var pageBackground: some View {
        Group {
            if squareCorners {
                background
            } else {
                LinearGradient(colors: [background, backgroundAlt], startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

extension Color {
    /// Opaque sRGB color from 0xRRGGBB.
    init(appHex: UInt32) {
        let r = Double((appHex >> 16) & 0xFF) / 255
        let g = Double((appHex >> 8) & 0xFF) / 255
        let b = Double(appHex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

// MARK: - Typography

enum SkinTypography {
    static func weight(_ weight: SkinFontWeight) -> Font.Weight {
        switch weight {
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }

    static func design(_ design: SkinFontDesign) -> Font.Design {
        switch design {
        case .default: return .default
        case .serif: return .serif
        case .rounded: return .rounded
        case .monospaced, .pixel: return .monospaced
        }
    }

    static func font(size: CGFloat, weight: SkinFontWeight, design: SkinFontDesign) -> Font {
        if design == .serif { return serif(size: size, weight: weight) }
        return .system(size: size, weight: self.weight(weight), design: self.design(design))
    }

    private static var serifCache: [String: Font] = [:]

    /// System serif (New York) for Latin and digits, cascading to Songti for Chinese where installed
    /// (macOS); otherwise Chinese falls back to the system face instead of a mismatched Japanese Mincho.
    private static func serif(size: CGFloat, weight: SkinFontWeight) -> Font {
        let key = "\(size)|\(weight.rawValue)"
        if let cached = serifCache[key] { return cached }
        let songti: String
        switch weight {
        case .thin, .light: songti = "STSongti-SC-Light"
        case .regular, .medium: songti = "STSongti-SC-Regular"
        case .semibold, .bold: songti = "STSongti-SC-Bold"
        }
        #if os(macOS)
        let base = NSFont.systemFont(ofSize: size, weight: platformWeight(weight))
        let serif = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        let descriptor = serif.addingAttributes([.cascadeList: [NSFontDescriptor(name: songti, size: size)]])
        let resolved = NSFont(descriptor: descriptor, size: size) ?? base
        #else
        let base = UIFont.systemFont(ofSize: size, weight: platformWeight(weight))
        let serif = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        let descriptor = serif.addingAttributes([.cascadeList: [UIFontDescriptor(name: songti, size: size)]])
        let resolved = UIFont(descriptor: descriptor, size: size)
        #endif
        let font = Font(resolved as CTFont)
        serifCache[key] = font
        return font
    }

    #if os(macOS)
    private static func platformWeight(_ weight: SkinFontWeight) -> NSFont.Weight {
        switch weight {
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }
    #else
    private static func platformWeight(_ weight: SkinFontWeight) -> UIFont.Weight {
        switch weight {
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }
    #endif
}

// MARK: - Theme environment (shared views opt into the active style)

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme(style: .mint, dark: false)
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

/// Root of any separately hosted window or scene: resolves the active skin and tints system controls.
struct AppSkinRoot: ViewModifier {
    @ObservedObject private var styleStore = UIStyleStore.shared
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let theme = AppTheme(style: styleStore.style, dark: colorScheme == .dark)
        content
            .environment(\.appTheme, theme)
            .tint(theme.accent)
    }
}

extension View {
    func appSkin() -> some View { modifier(AppSkinRoot()) }
}

// MARK: - Surfaces

/// Card/control backing that honors border, radius and shadow tokens. Hard shadows are a solid block, no blur.
/// Pressed controls move their face 2pt toward the block (the caller offsets the face), so the block tucks to 1pt.
struct SkinSurface: View {
    let theme: AppTheme
    var fill: Color
    var radius: CGFloat
    var stroke: Color?
    var strokeWidth: CGFloat
    var elevated = true
    var pressed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if elevated && theme.hardShadow {
                let offset = theme.hardShadowOffset
                shape.fill(theme.hardShadowColor)
                    .offset(x: pressed ? 1 : offset.width, y: pressed ? 1 : offset.height)
            }
            if elevated, let s = theme.blurShadow {
                shape.fill(fill).shadow(color: s.color, radius: pressed ? s.radius / 2 : s.radius, x: s.x, y: pressed ? s.y / 2 : s.y)
            } else {
                shape.fill(fill)
            }
            if let stroke, strokeWidth > 0 {
                shape.strokeBorder(stroke, lineWidth: strokeWidth)
            }
        }
    }
}

struct ThemeCard: ViewModifier {
    let theme: AppTheme
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(SkinSurface(theme: theme, fill: theme.surface, radius: theme.cardRadius,
                                    stroke: theme.cardStroke, strokeWidth: theme.borderWidth))
    }
}

extension View {
    func themeCard(_ theme: AppTheme, padding: CGFloat = 14) -> some View {
        modifier(ThemeCard(theme: theme, padding: padding))
    }

    /// Flat inset well inside a card (cells, metric tiles): subtle fill, no shadow.
    func themeWell(_ theme: AppTheme, padding: CGFloat = 10, fill: Color? = nil) -> some View {
        self.padding(padding)
            .background(theme.smallShape().fill(fill ?? theme.subtle))
    }
}

// MARK: - Buttons

struct PrimaryActionStyle: ButtonStyle {
    let theme: AppTheme
    var height: CGFloat = 42
    var fontSize: CGFloat = 13

    func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration, theme: theme, height: height, fontSize: fontSize)
    }

    private struct PrimaryBody: View {
        let configuration: ButtonStyleConfiguration
        let theme: AppTheme
        let height: CGFloat
        let fontSize: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .font(theme.squareCorners ? .system(size: fontSize, weight: .bold, design: .monospaced)
                                          : .system(size: fontSize, weight: .semibold))
                .foregroundColor(theme.onAccent)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(
                    SkinSurface(theme: theme,
                                fill: theme.accent.opacity(pressed ? 0.86 : (hovering ? 0.93 : 1)),
                                radius: theme.controlRadius,
                                stroke: theme.squareCorners ? theme.ink : nil,
                                strokeWidth: theme.borderWidth, pressed: pressed)
                )
                .offset(x: theme.hardShadow && pressed ? 2 : 0, y: theme.hardShadow && pressed ? 2 : 0)
                .scaleEffect(!theme.hardShadow && pressed ? 0.985 : 1)
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(theme.controlShape)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: pressed)
        }
    }
}

struct QuietButtonStyle: ButtonStyle {
    let theme: AppTheme
    var height: CGFloat = 34
    var fontSize: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        QuietBody(configuration: configuration, theme: theme, height: height, fontSize: fontSize)
    }

    private struct QuietBody: View {
        let configuration: ButtonStyleConfiguration
        let theme: AppTheme
        let height: CGFloat
        let fontSize: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .font(.system(size: fontSize, weight: .medium))
                .foregroundColor(theme.ink)
                .frame(minHeight: height)
                .padding(.horizontal, 12)
                .background(
                    SkinSurface(theme: theme,
                                fill: pressed ? theme.subtle : (hovering && isEnabled ? theme.subtle.opacity(0.6) : theme.surface),
                                radius: theme.controlRadius,
                                stroke: theme.controlStroke, strokeWidth: theme.controlStrokeWidth,
                                elevated: theme.hardShadow, pressed: pressed)
                )
                .offset(x: theme.hardShadow && pressed ? 2 : 0, y: theme.hardShadow && pressed ? 2 : 0)
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(theme.controlShape)
                .onHover { hovering = $0 }
        }
    }
}

/// Borderless icons, nav items and list rows: hover wash on Mac, pressed wash everywhere.
struct SkinPlainButtonStyle: ButtonStyle {
    let theme: AppTheme
    var radius: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        PlainBody(configuration: configuration, theme: theme, radius: radius)
    }

    private struct PlainBody: View {
        let configuration: ButtonStyleConfiguration
        let theme: AppTheme
        let radius: CGFloat?
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: radius ?? min(theme.controlRadius, 8), style: .continuous)
            configuration.label
                .background(shape.fill(configuration.isPressed ? theme.subtle
                                       : (hovering && isEnabled ? theme.subtle.opacity(0.7) : Color.clear)))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(shape)
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Page furniture (shared so secondary tabs speak the same visual language as focus)

/// Small status capsule; square on pixel.
struct SkinChip: View {
    @Environment(\.appTheme) private var theme
    let text: String
    var symbol: String? = nil
    var tint: Color? = nil
    var fill: Color? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(theme.numberFont(size: 10, weight: .medium))
        }
        .foregroundColor(tint ?? theme.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.chipShape.fill(fill ?? theme.accentSoft))
        .fixedSize()
    }
}

struct ThemedPageHeader: View {
    @Environment(\.appTheme) private var theme
    let title: String
    let subtitle: String
    let symbol: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(theme.accent)
                .frame(width: 38, height: 38)
                .background(theme.smallShape(11).fill(theme.accentSoft))
                .overlay(theme.squareCorners ? theme.smallShape().strokeBorder(theme.ink, lineWidth: theme.borderWidth) : nil)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(theme.titleFont(size: theme.layout == .airy ? 21 : 19))
                    .foregroundColor(theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let detail = detail {
                SkinChip(text: detail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct ThemedEmptyState: View {
    @Environment(\.appTheme) private var theme
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundColor(theme.accent)
                .frame(width: 54, height: 54)
                .background(theme.dotShape.fill(theme.accentSoft))
                .accessibilityHidden(true)
            Text(title)
                .font(theme.sectionFont(size: 15))
                .foregroundColor(theme.ink)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 170)
        .themeCard(theme, padding: theme.cardPadding)
        .accessibilityElement(children: .combine)
    }
}

struct ThemeRefreshButton: View {
    @Environment(\.appTheme) private var theme
    let loading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if loading {
                    ProgressView().controlSize(.small).tint(theme.accent)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(loading ? "刷新中…" : "刷新")
            }
        }
        .buttonStyle(QuietButtonStyle(theme: theme))
        .disabled(loading)
        .accessibilityLabel(loading ? "正在刷新" : "刷新")
    }
}

/// Resizes the hosting window when the user switches between compact and wide layouts.
#if os(macOS)
struct WindowSizeConfigurator: NSViewRepresentable {
    let size: CGSize

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            let current = window.contentView?.bounds.size ?? .zero
            guard abs(current.width - size.width) > 1 || abs(current.height - size.height) > 1 else { return }
            window.setContentSize(size)
            window.center()
        }
    }
}
#endif
