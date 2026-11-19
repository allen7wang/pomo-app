package com.habitica.pomodoro.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider

@Composable
fun HabiticaPomodoroTheme(
    style: AppUiStyle = AppUiStyle.Mint,
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val palette = skinPalette(style, darkTheme)
    val scheme = if (darkTheme) darkScheme(palette) else lightScheme(palette)
    CompositionLocalProvider(LocalAppSkin provides style) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}

private fun lightScheme(p: SkinPalette) = lightColorScheme(
    primary = p.color(p.accent),
    onPrimary = p.color(p.onAccent),
    primaryContainer = p.color(p.accentSoft),
    onPrimaryContainer = p.color(p.ink),
    secondary = p.color(p.accent),
    onSecondary = p.color(p.onAccent),
    secondaryContainer = p.color(p.accentSoft),
    onSecondaryContainer = p.color(p.ink),
    tertiary = p.color(p.accent),
    onTertiary = p.color(p.onAccent),
    background = p.color(p.background),
    onBackground = p.color(p.ink),
    surface = p.color(p.surface),
    onSurface = p.color(p.ink),
    surfaceVariant = p.color(p.subtle),
    onSurfaceVariant = p.color(p.muted),
    outline = p.color(p.line),
    outlineVariant = p.color(p.line),
    surfaceContainer = p.color(p.surface),
    surfaceContainerLow = p.color(p.background),
    surfaceContainerHigh = p.color(p.subtle),
    surfaceContainerLowest = p.color(p.background),
)

private fun darkScheme(p: SkinPalette) = darkColorScheme(
    primary = p.color(p.accent),
    onPrimary = p.color(p.onAccent),
    primaryContainer = p.color(p.accentSoft),
    onPrimaryContainer = p.color(p.ink),
    secondary = p.color(p.accent),
    onSecondary = p.color(p.onAccent),
    secondaryContainer = p.color(p.accentSoft),
    onSecondaryContainer = p.color(p.ink),
    tertiary = p.color(p.accent),
    onTertiary = p.color(p.onAccent),
    background = p.color(p.background),
    onBackground = p.color(p.ink),
    surface = p.color(p.surface),
    onSurface = p.color(p.ink),
    surfaceVariant = p.color(p.subtle),
    onSurfaceVariant = p.color(p.muted),
    outline = p.color(p.line),
    outlineVariant = p.color(p.line),
    surfaceContainer = p.color(p.surface),
    surfaceContainerLow = p.color(p.background),
    surfaceContainerHigh = p.color(p.subtle),
    surfaceContainerLowest = p.color(p.background),
)
