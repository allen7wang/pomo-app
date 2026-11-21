package com.habitica.pomodoro.ui.theme

import android.provider.Settings
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** The 14 palette tokens of one skin for the active light/dark scheme. */
@Immutable
data class SkinColors(
    val background: Color,
    val backgroundAlt: Color,
    val surface: Color,
    val subtle: Color,
    val line: Color,
    val ink: Color,
    val muted: Color,
    val accent: Color,
    val accentSoft: Color,
    val onAccent: Color,
    /** Break-phase color. */
    val rest: Color,
    val restSoft: Color,
    val danger: Color,
    /** Streak / combo / gold / tree. */
    val highlight: Color,
)

@Immutable
data class SkinSpacing(val pageInset: Dp, val pageSpacing: Dp, val cardPadding: Dp, val rowSpacing: Dp)

/**
 * Everything a screen needs beyond MaterialTheme: extra colors, layout rhythm,
 * card/control shapes and the ring/timer tokens. Read via [LocalSkin].
 */
@Immutable
class SkinSpec(
    val style: AppUiStyle,
    val isDark: Boolean,
    val reduceMotion: Boolean,
) {
    val tokens: SkinTokens = style.tokens
    val colors: SkinColors = skinColors(if (isDark) tokens.dark else tokens.light)
    val layout: SkinLayout get() = tokens.layout
    val spacing: SkinSpacing = SkinCatalog.layouts.getValue(tokens.layout).let {
        SkinSpacing(it.pageInset.dp, it.pageSpacing.dp, it.cardPadding.dp, it.rowSpacing.dp)
    }

    val cardRadius: Dp = tokens.cardRadius.dp
    val controlRadius: Dp = tokens.controlRadius.dp
    val cardShape: Shape = RoundedCornerShape(cardRadius)
    val controlShape: Shape = RoundedCornerShape(controlRadius)
    /** Chips and small badges: a pill unless the skin is square-cornered. */
    val chipShape: Shape = if (tokens.controlRadius == 0f) RoundedCornerShape(0.dp) else RoundedCornerShape(50)

    val isPixel: Boolean get() = tokens.cardBorder == SkinCardBorder.Ink
    val hardShadow: Boolean get() = tokens.shadow.opacity >= 1f && tokens.shadow.radius == 0f

    val cardBorder: BorderStroke? = when (tokens.cardBorder) {
        SkinCardBorder.None -> null
        SkinCardBorder.Line -> BorderStroke(tokens.borderWidth.dp, colors.line)
        SkinCardBorder.Ink -> BorderStroke(tokens.borderWidth.dp, colors.ink)
    }

    /** Controls get an ink outline only in the pixel skin; elsewhere the fill carries them. */
    val controlBorder: BorderStroke? =
        if (tokens.cardBorder == SkinCardBorder.Ink) BorderStroke(tokens.borderWidth.dp, colors.ink) else null

    val titleFamily: FontFamily = fontFamily(tokens.titleDesign)
    val titleWeight: FontWeight = fontWeight(tokens.titleWeight)
    val timerFamily: FontFamily = fontFamily(tokens.timerDesign)
    val timerWeight: FontWeight = fontWeight(tokens.timerWeight)

    val shadowColor: Color = when (tokens.shadow.color) {
        SkinShadowColor.Ink -> colors.ink
        SkinShadowColor.Accent -> colors.accent
    }

    /** Page background: a quiet vertical wash, except the flat pixel skin. */
    val backgroundGradient: Boolean get() = !isPixel
}

val LocalSkin = staticCompositionLocalOf { SkinSpec(AppUiStyle.Mint, isDark = false, reduceMotion = false) }

/** Resolves the effective scheme: a skin's forcedScheme wins over the system setting. */
fun AppUiStyle.resolveDark(systemDark: Boolean): Boolean = when (tokens.forcedScheme) {
    SkinForcedScheme.Dark -> true
    SkinForcedScheme.Light -> false
    null -> systemDark
}

@Composable
fun HabiticaPomodoroTheme(
    style: AppUiStyle = AppUiStyle.Mint,
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val dark = style.resolveDark(darkTheme)
    val reduceMotion = rememberReduceMotion()
    val skin = remember(style, dark, reduceMotion) { SkinSpec(style, dark, reduceMotion) }
    val scheme = remember(skin) { colorScheme(skin.colors, dark) }
    val shapes = remember(skin) { shapes(skin.tokens) }
    val typography = remember(skin) { typography(skin) }
    CompositionLocalProvider(LocalAppSkin provides style, LocalSkin provides skin) {
        MaterialTheme(colorScheme = scheme, shapes = shapes, typography = typography, content = content)
    }
}

/** System "remove animations" (animator scale 0) turns progress animations into snaps. */
@Composable
private fun rememberReduceMotion(): Boolean {
    val resolver = LocalContext.current.contentResolver
    return remember(resolver) {
        Settings.Global.getFloat(resolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
}

fun skinColors(p: SkinPaletteTokens) = SkinColors(
    background = rgb(p.background), backgroundAlt = rgb(p.backgroundAlt), surface = rgb(p.surface),
    subtle = rgb(p.subtle), line = rgb(p.line), ink = rgb(p.ink), muted = rgb(p.muted),
    accent = rgb(p.accent), accentSoft = rgb(p.accentSoft), onAccent = rgb(p.onAccent),
    rest = rgb(p.rest), restSoft = rgb(p.restSoft), danger = rgb(p.danger), highlight = rgb(p.highlight),
)

private fun rgb(hex: Long): Color = Color(0xFF000000 or hex)

/*
 * Token -> Material roles. primary = accent, secondary/tertiary = rest (break),
 * error = danger. Container roles climb background -> backgroundAlt -> surface -> subtle
 * so default Material components (dialogs, menus, filled cards) land on skin colors.
 * outline sits between line and muted: line alone is too faint for text-field borders.
 */
private fun colorScheme(c: SkinColors, dark: Boolean): ColorScheme {
    val outline = lerp(c.line, c.muted, 0.45f)
    val errorContainer = lerp(c.surface, c.danger, if (dark) 0.22f else 0.12f)
    return if (dark) {
        darkColorScheme(
            primary = c.accent, onPrimary = c.onAccent, primaryContainer = c.accentSoft, onPrimaryContainer = c.ink,
            inversePrimary = c.accent,
            secondary = c.rest, onSecondary = c.surface, secondaryContainer = c.restSoft, onSecondaryContainer = c.ink,
            tertiary = c.rest, onTertiary = c.surface, tertiaryContainer = c.restSoft, onTertiaryContainer = c.ink,
            error = c.danger, onError = c.surface, errorContainer = errorContainer, onErrorContainer = c.ink,
            background = c.background, onBackground = c.ink,
            surface = c.surface, onSurface = c.ink, surfaceVariant = c.subtle, onSurfaceVariant = c.muted,
            surfaceTint = c.accent, inverseSurface = c.ink, inverseOnSurface = c.background,
            outline = outline, outlineVariant = c.line, scrim = Color.Black,
            surfaceBright = c.subtle, surfaceDim = c.background,
            surfaceContainerLowest = c.background, surfaceContainerLow = c.backgroundAlt,
            surfaceContainer = c.surface, surfaceContainerHigh = c.surface, surfaceContainerHighest = c.subtle,
        )
    } else {
        lightColorScheme(
            primary = c.accent, onPrimary = c.onAccent, primaryContainer = c.accentSoft, onPrimaryContainer = c.ink,
            inversePrimary = c.accentSoft,
            secondary = c.rest, onSecondary = c.surface, secondaryContainer = c.restSoft, onSecondaryContainer = c.ink,
            tertiary = c.rest, onTertiary = c.surface, tertiaryContainer = c.restSoft, onTertiaryContainer = c.ink,
            error = c.danger, onError = c.surface, errorContainer = errorContainer, onErrorContainer = c.ink,
            background = c.background, onBackground = c.ink,
            surface = c.surface, onSurface = c.ink, surfaceVariant = c.subtle, onSurfaceVariant = c.muted,
            surfaceTint = c.accent, inverseSurface = c.ink, inverseOnSurface = c.background,
            outline = outline, outlineVariant = c.line, scrim = Color.Black,
            surfaceBright = c.surface, surfaceDim = c.backgroundAlt,
            surfaceContainerLowest = c.surface, surfaceContainerLow = c.background,
            surfaceContainer = c.surface, surfaceContainerHigh = c.surface, surfaceContainerHighest = c.subtle,
        )
    }
}

private fun shapes(t: SkinTokens): Shapes {
    val card = t.cardRadius
    val control = t.controlRadius
    fun r(v: Float) = RoundedCornerShape(v.coerceAtLeast(0f).dp)
    return Shapes(
        extraSmall = r(control / 2f),
        small = r(control),
        medium = r(card),
        large = r(if (card == 0f) 0f else card + 4f),
        extraLarge = r(if (card == 0f) 0f else card + 8f),
    )
}

private fun fontFamily(design: SkinFontDesign): FontFamily = when (design) {
    SkinFontDesign.Serif -> FontFamily.Serif
    SkinFontDesign.Monospaced, SkinFontDesign.Pixel -> FontFamily.Monospace
    // Android ships no rounded system face; the default sans keeps metrics predictable.
    SkinFontDesign.Default, SkinFontDesign.Rounded -> FontFamily.Default
}

private fun fontWeight(weight: SkinFontWeight): FontWeight = when (weight) {
    SkinFontWeight.Thin -> FontWeight.Thin
    SkinFontWeight.Light -> FontWeight.Light
    SkinFontWeight.Regular -> FontWeight.Normal
    SkinFontWeight.Medium -> FontWeight.Medium
    SkinFontWeight.Semibold -> FontWeight.SemiBold
    SkinFontWeight.Bold -> FontWeight.Bold
}

/**
 * Display/headline/title roles carry the skin's title face; body and label stay on the
 * system sans for legibility of long Chinese copy. Small titles never drop below Medium
 * so section headings keep their hierarchy in light-weight skins.
 */
private fun typography(skin: SkinSpec): Typography {
    val base = Typography()
    val family = skin.titleFamily
    val weight = skin.titleWeight
    val sectionWeight = if (weight.weight < FontWeight.Medium.weight) FontWeight.Medium else weight
    val tracking = if (family == FontFamily.Monospace) 0.sp else null
    fun TextStyle.title(w: FontWeight) = copy(
        fontFamily = family,
        fontWeight = w,
        letterSpacing = tracking ?: letterSpacing,
    )
    return base.copy(
        displayLarge = base.displayLarge.title(weight),
        displayMedium = base.displayMedium.title(weight),
        displaySmall = base.displaySmall.title(weight),
        headlineLarge = base.headlineLarge.title(weight),
        headlineMedium = base.headlineMedium.title(weight),
        headlineSmall = base.headlineSmall.title(weight),
        titleLarge = base.titleLarge.title(sectionWeight),
        titleMedium = base.titleMedium.title(sectionWeight),
        titleSmall = base.titleSmall.title(sectionWeight),
    )
}

/** Tabular figures so counters and clocks do not jitter as digits change. */
fun TextStyle.tabular(): TextStyle = copy(fontFeatureSettings = "tnum")
