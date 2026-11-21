package com.habitica.pomodoro.ui.theme

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/* Skin-aware building blocks. Screens use these instead of raw Material containers so
 * border, corner, shadow and type follow the active skin's tokens. */

/** Page wash: background -> backgroundAlt, flat for the pixel skin. */
fun Modifier.skinBackground(skin: SkinSpec): Modifier =
    if (skin.backgroundGradient) {
        background(Brush.verticalGradient(listOf(skin.colors.background, skin.colors.backgroundAlt)))
    } else {
        background(skin.colors.background)
    }

/**
 * Draws the token shadow behind a rounded rect. Soft/lifted use a blurred shadow layer
 * (rendered on API 28+, silently flat before); hard is a solid offset ink block, no blur.
 * [pressed] hides the hard block so a pressed control looks pushed into its shadow.
 */
fun Modifier.skinShadow(skin: SkinSpec, corner: Dp, fill: Color, pressed: Boolean = false): Modifier {
    val s = skin.tokens.shadow
    if (s.opacity <= 0f) return this
    val color = skin.shadowColor
    return drawBehind {
        val r = corner.toPx()
        if (skin.hardShadow) {
            if (!pressed) {
                drawRoundRect(
                    color = color,
                    topLeft = Offset(s.x.dp.toPx(), s.y.dp.toPx()),
                    size = size,
                    cornerRadius = CornerRadius(r, r),
                )
            }
        } else {
            drawIntoCanvas { canvas ->
                val paint = Paint().asFrameworkPaint().apply {
                    isAntiAlias = true
                    this.color = fill.toArgb()
                    // Dark skins get a slightly stronger layer so the lift still reads.
                    val alpha = (s.opacity * if (skin.isDark) 2.5f else 1f).coerceAtMost(0.5f)
                    setShadowLayer(s.radius.dp.toPx() / 2f, s.x.dp.toPx(), s.y.dp.toPx(), color.copy(alpha = alpha).toArgb())
                }
                canvas.nativeCanvas.drawRoundRect(0f, 0f, size.width, size.height, r, r, paint)
            }
        }
    }
}

enum class SkinTone { Surface, Subtle, Accent, Rest, Danger }

/** Card with the skin's radius, border (none/line/ink) and shadow (none/soft/lifted/hard). */
@Composable
fun SkinCard(
    modifier: Modifier = Modifier,
    tone: SkinTone = SkinTone.Surface,
    onClick: (() -> Unit)? = null,
    onClickLabel: String? = null,
    contentPadding: PaddingValues? = null,
    verticalArrangement: Arrangement.Vertical? = null,
    elevated: Boolean = true,
    content: @Composable ColumnScope.() -> Unit,
) {
    val skin = LocalSkin.current
    val c = skin.colors
    val fill = when (tone) {
        SkinTone.Surface -> c.surface
        SkinTone.Subtle -> c.subtle
        SkinTone.Accent -> c.accentSoft
        SkinTone.Rest -> c.restSoft
        SkinTone.Danger -> MaterialTheme.colorScheme.errorContainer
    }
    val border = when {
        skin.isPixel -> skin.cardBorder
        tone == SkinTone.Surface -> skin.cardBorder
        tone == SkinTone.Danger -> BorderStroke(1.dp, c.danger.copy(alpha = 0.35f))
        else -> null
    }
    // Dense rows pass elevated = false; the pixel skin keeps its hard shadow as identity.
    val shadowed = skin.isPixel || (elevated && tone == SkinTone.Surface)
    Column(
        modifier = modifier
            .then(if (shadowed) Modifier.skinShadow(skin, skin.cardRadius, fill) else Modifier)
            .clip(skin.cardShape)
            .background(fill)
            .then(if (border != null) Modifier.border(border, skin.cardShape) else Modifier)
            .then(
                if (onClick != null) Modifier.clickable(onClickLabel = onClickLabel, role = Role.Button, onClick = onClick)
                else Modifier,
            )
            .padding(contentPadding ?: PaddingValues(skin.spacing.cardPadding)),
        verticalArrangement = verticalArrangement ?: Arrangement.spacedBy(skin.spacing.rowSpacing),
    ) {
        CompositionLocalProvider(LocalContentColor provides c.ink) { content() }
    }
}

enum class SkinButtonKind { Primary, Rest, Tonal, Quiet, Danger }

/**
 * Filled or quiet control honoring controlRadius. Pixel skin: square, ink outline and a hard
 * shadow that the button drops into while pressed.
 */
@Composable
fun SkinButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    kind: SkinButtonKind = SkinButtonKind.Primary,
    enabled: Boolean = true,
    icon: ImageVector? = null,
    compact: Boolean = false,
) {
    val skin = LocalSkin.current
    val c = skin.colors
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val (fill, content) = when (kind) {
        SkinButtonKind.Primary -> c.accent to c.onAccent
        SkinButtonKind.Rest -> c.rest to c.surface
        SkinButtonKind.Tonal -> c.accentSoft to c.ink
        SkinButtonKind.Quiet -> c.surface.copy(alpha = if (skin.isPixel) 1f else 0f) to c.ink
        SkinButtonKind.Danger -> c.surface.copy(alpha = if (skin.isPixel) 1f else 0f) to c.danger
    }
    val border = skin.controlBorder ?: when (kind) {
        SkinButtonKind.Quiet -> BorderStroke(1.dp, c.line)
        SkinButtonKind.Danger -> BorderStroke(1.dp, c.danger.copy(alpha = 0.45f))
        else -> null
    }
    val filled = kind == SkinButtonKind.Primary || kind == SkinButtonKind.Rest
    // Lifted (tomato) and hard (pixel) shadows suit buttons; soft ones only suit cards.
    val shadow = enabled && (skin.hardShadow || (filled && skin.tokens.shadow.radius > 12f))
    val pushed = skin.hardShadow && pressed
    val shift = if (pushed) skin.tokens.shadow.x.dp else 0.dp
    Box(
        modifier = modifier
            .defaultMinSize(minHeight = if (compact) 40.dp else 48.dp)
            .minimumInteractiveComponentSize()
            .offset(x = shift, y = shift)
            .alpha(if (enabled) 1f else 0.4f)
            .then(if (shadow) Modifier.skinShadow(skin, skin.controlRadius, fill, pushed) else Modifier)
            .clip(skin.controlShape)
            .background(fill)
            .then(if (border != null) Modifier.border(border, skin.controlShape) else Modifier)
            .clickable(
                interactionSource = interaction,
                indication = ripple(color = content),
                enabled = enabled,
                role = Role.Button,
                onClick = onClick,
            )
            .padding(horizontal = if (compact) 12.dp else 16.dp, vertical = 8.dp),
        contentAlignment = Alignment.Center,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            if (icon != null) Icon(icon, contentDescription = null, tint = content, modifier = Modifier.size(18.dp))
            Text(
                text,
                color = content,
                style = MaterialTheme.typography.labelLarge,
                fontWeight = if (filled) FontWeight.SemiBold else FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/** Low-emphasis text action; [color] defaults to accent, use danger for destructive ones. */
@Composable
fun SkinTextButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    color: Color = LocalSkin.current.colors.accent,
    icon: ImageVector? = null,
) {
    TextButton(
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        shape = LocalSkin.current.controlShape,
        colors = ButtonDefaults.textButtonColors(contentColor = color),
        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
        }
        Text(text, style = MaterialTheme.typography.labelLarge)
    }
}

/** Selectable pill (square in pixel). 32dp visual height, 48dp touch target. */
@Composable
fun SkinChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    color: Color = LocalSkin.current.colors.accent,
    idleColor: Color = LocalSkin.current.colors.muted,
) {
    val skin = LocalSkin.current
    val c = skin.colors
    val fill = when {
        selected && skin.isPixel -> color
        selected -> if (color == c.rest) c.restSoft else c.accentSoft
        else -> Color.Transparent
    }
    val textColor = when {
        selected && skin.isPixel -> if (color == c.rest) c.surface else c.onAccent
        selected -> color
        else -> idleColor
    }
    val border = skin.controlBorder ?: BorderStroke(1.dp, if (selected) color.copy(alpha = 0.55f) else c.line)
    Box(
        modifier = modifier
            .minimumInteractiveComponentSize()
            .height(32.dp)
            .alpha(if (enabled) 1f else 0.4f)
            .clip(skin.chipShape)
            .background(fill)
            .border(border, skin.chipShape)
            .clickable(enabled = enabled, role = Role.Tab, onClick = onClick)
            .padding(horizontal = 14.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            style = MaterialTheme.typography.labelLarge.tabular(),
            color = textColor,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium,
            maxLines = 1,
        )
    }
}

/** Large page title in the skin's title face, optional eyebrow/subtitle and trailing actions. */
@Composable
fun PageHeader(
    title: String,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    eyebrow: String? = null,
    actions: @Composable RowScope.() -> Unit = {},
) {
    val c = LocalSkin.current.colors
    Column(modifier = modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        if (eyebrow != null) Text(eyebrow, style = MaterialTheme.typography.labelMedium, color = c.muted)
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                title,
                style = MaterialTheme.typography.headlineSmall,
                color = c.ink,
                modifier = Modifier
                    .weight(1f)
                    .semantics { heading() },
            )
            actions()
        }
        if (subtitle != null) Text(subtitle, style = MaterialTheme.typography.bodySmall, color = c.muted)
    }
}

/** Section heading inside or above cards. */
@Composable
fun SectionTitle(text: String, modifier: Modifier = Modifier, trailing: String? = null, trailingColor: Color? = null) {
    val c = LocalSkin.current.colors
    Row(modifier = modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(
            text,
            style = MaterialTheme.typography.titleSmall,
            color = c.ink,
            modifier = Modifier
                .weight(1f)
                .semantics { heading() },
        )
        if (trailing != null) {
            Text(trailing, style = MaterialTheme.typography.labelMedium.tabular(), color = trailingColor ?: c.muted)
        }
    }
}

/** Label / value row with tabular figures on the value. */
@Composable
fun KeyValueRow(label: String, value: String, modifier: Modifier = Modifier, valueColor: Color? = null) {
    val c = LocalSkin.current.colors
    Row(modifier = modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = MaterialTheme.typography.bodyMedium, color = c.muted, modifier = Modifier.weight(1f))
        Text(
            value,
            style = MaterialTheme.typography.bodyMedium.tabular(),
            fontWeight = FontWeight.SemiBold,
            color = valueColor ?: c.ink,
        )
    }
}

/** Big number over a small caption; used in stat strips. */
@Composable
fun StatTile(value: String, label: String, modifier: Modifier = Modifier, color: Color? = null) {
    val skin = LocalSkin.current
    Column(modifier = modifier, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(
            value,
            style = MaterialTheme.typography.titleLarge.tabular(),
            color = color ?: skin.colors.ink,
            maxLines = 1,
        )
        Text(label, style = MaterialTheme.typography.labelSmall, color = skin.colors.muted, maxLines = 1)
    }
}

@Composable
fun SkinDivider(modifier: Modifier = Modifier) {
    HorizontalDivider(modifier = modifier, thickness = 1.dp, color = LocalSkin.current.colors.line)
}

/** Small colored dot + label; used for the timer phase. */
@Composable
fun StatusPill(text: String, color: Color, modifier: Modifier = Modifier) {
    val skin = LocalSkin.current
    Row(
        modifier = modifier
            .clip(skin.chipShape)
            .background(color.copy(alpha = if (skin.isDark) 0.16f else 0.10f))
            .padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(
            Modifier
                .size(7.dp)
                .clip(if (skin.isPixel) skin.chipShape else CircleShape)
                .background(color),
        )
        Text(text, style = MaterialTheme.typography.labelMedium, color = color, fontWeight = FontWeight.SemiBold, maxLines = 1)
    }
}

/** Calm placeholder for empty lists and unconfigured states. */
@Composable
fun EmptyState(
    icon: ImageVector,
    title: String,
    message: String,
    modifier: Modifier = Modifier,
    action: (@Composable () -> Unit)? = null,
) {
    val skin = LocalSkin.current
    val c = skin.colors
    SkinCard(modifier = modifier.fillMaxWidth(), tone = SkinTone.Subtle) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clip(if (skin.isPixel) skin.chipShape else CircleShape)
                    .background(c.accentSoft),
                contentAlignment = Alignment.Center,
            ) {
                Icon(icon, contentDescription = null, tint = c.accent, modifier = Modifier.size(22.dp))
            }
            Text(title, style = MaterialTheme.typography.titleSmall, color = c.ink, textAlign = TextAlign.Center)
            Text(message, style = MaterialTheme.typography.bodySmall, color = c.muted, textAlign = TextAlign.Center)
            if (action != null) action()
        }
    }
}

/** Inline error/notice line; danger for failures, muted otherwise. */
@Composable
fun NoticeText(text: String, modifier: Modifier = Modifier, danger: Boolean = true) {
    val c = LocalSkin.current.colors
    Text(text, modifier = modifier, style = MaterialTheme.typography.bodySmall, color = if (danger) c.danger else c.muted)
}

@Composable
fun skinTextFieldColors() = LocalSkin.current.colors.let { c ->
    OutlinedTextFieldDefaults.colors(
        focusedBorderColor = c.accent,
        focusedLabelColor = c.accent,
        cursorColor = c.accent,
        focusedContainerColor = c.surface,
        unfocusedContainerColor = c.surface,
        disabledContainerColor = c.subtle,
    )
}

@Composable
fun skinSwitchColors() = LocalSkin.current.colors.let { c ->
    SwitchDefaults.colors(
        checkedTrackColor = c.accent,
        checkedThumbColor = c.onAccent,
        uncheckedTrackColor = c.subtle,
        uncheckedBorderColor = MaterialTheme.colorScheme.outline,
        uncheckedThumbColor = MaterialTheme.colorScheme.outline,
    )
}

@Composable
fun skinCheckboxColors() = LocalSkin.current.colors.let { c ->
    CheckboxDefaults.colors(checkedColor = c.accent, checkmarkColor = c.onAccent, uncheckedColor = MaterialTheme.colorScheme.outline)
}

/** Settings row: label (+ optional hint) and a skin-colored switch; the whole row toggles. */
@Composable
fun SettingSwitchRow(label: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit, hint: String? = null) {
    val c = LocalSkin.current.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .defaultMinSize(minHeight = 48.dp)
            .toggleable(value = checked, role = Role.Switch, onValueChange = onCheckedChange),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f).padding(end = 12.dp)) {
            Text(label, style = MaterialTheme.typography.bodyLarge, color = c.ink)
            if (hint != null) Text(hint, style = MaterialTheme.typography.bodySmall, color = c.muted)
        }
        Switch(checked = checked, onCheckedChange = null, colors = skinSwitchColors())
    }
}

/** Settings row with − value + controls; value uses tabular figures so the row does not shift. */
@Composable
fun SettingStepperRow(
    label: String,
    value: String,
    onMinus: () -> Unit,
    onPlus: () -> Unit,
    minusEnabled: Boolean = true,
    plusEnabled: Boolean = true,
) {
    val c = LocalSkin.current.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .defaultMinSize(minHeight = 48.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = MaterialTheme.typography.bodyLarge, color = c.ink, modifier = Modifier.weight(1f))
        StepButton("−", "减少$label", minusEnabled, onMinus)
        Text(
            value,
            style = MaterialTheme.typography.bodyMedium.tabular(),
            color = c.ink,
            textAlign = TextAlign.Center,
            modifier = Modifier.widthIn(min = 72.dp),
        )
        StepButton("+", "增加$label", plusEnabled, onPlus)
    }
}

@Composable
private fun StepButton(symbol: String, description: String, enabled: Boolean, onClick: () -> Unit) {
    val skin = LocalSkin.current
    val c = skin.colors
    val shape = if (skin.isPixel) skin.controlShape else CircleShape
    Box(
        modifier = Modifier
            .minimumInteractiveComponentSize()
            .size(34.dp)
            .alpha(if (enabled) 1f else 0.35f)
            .clip(shape)
            .background(c.subtle)
            .border(skin.controlBorder ?: BorderStroke(1.dp, c.line), shape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Text(symbol, style = MaterialTheme.typography.titleMedium.copy(fontFamily = null), color = c.accent)
    }
}
