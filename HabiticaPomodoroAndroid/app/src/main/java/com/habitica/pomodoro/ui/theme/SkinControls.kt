package com.habitica.pomodoro.ui.theme

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.Palette
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

@Composable
fun SkinPaletteButton(skins: AppSkinState) {
    val context = LocalContext.current
    val current by skins.style
    val systemDark = isSystemInDarkTheme()
    val c = LocalSkin.current.colors
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) {
            Icon(Icons.Outlined.Palette, contentDescription = "切换界面风格", tint = c.muted)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            AppUiStyle.entries.forEach { style ->
                val dark = style.resolveDark(systemDark)
                val colors = skinColors(if (dark) style.tokens.dark else style.tokens.light)
                DropdownMenuItem(
                    leadingIcon = { SkinGlyph(style, colors, 28.dp) },
                    text = {
                        Column {
                            Text(
                                style.title,
                                style = TextStyle(fontFamily = SkinSpec(style, dark, true).titleFamily, fontSize = 15.sp),
                                color = c.ink,
                            )
                            Text(style.tagline, style = MaterialTheme.typography.labelSmall, color = c.muted, maxLines = 1)
                        }
                    },
                    trailingIcon = {
                        if (style == current) Icon(Icons.Filled.Check, contentDescription = "当前", tint = c.accent)
                    },
                    onClick = {
                        skins.select(context, style)
                        open = false
                    },
                )
            }
        }
    }
}

@Composable
fun AppearanceStylePicker(skins: AppSkinState) {
    val context = LocalContext.current
    val current by skins.style
    val skin = LocalSkin.current
    Column(verticalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
        Text(
            "皮肤可随时切换，选择只保存在本机，不影响任务、计时或同步。除深夜航行固定深色外，均跟随系统深浅色。",
            style = MaterialTheme.typography.bodySmall,
            color = skin.colors.muted,
        )
        AppUiStyle.entries.chunked(2).forEach { pair ->
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                pair.forEach { style ->
                    SkinPreviewTile(
                        style = style,
                        selected = style == current,
                        onClick = { skins.select(context, style) },
                        modifier = Modifier.weight(1f),
                    )
                }
                if (pair.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

/** A miniature of the skin in its own colors: wash, ring arc, rest dot, name in its title face. */
@Composable
private fun SkinPreviewTile(style: AppUiStyle, selected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val current = LocalSkin.current
    val dark = style.resolveDark(isSystemInDarkTheme())
    val preview = remember(style, dark) { SkinSpec(style, dark, reduceMotion = true) }
    val c = preview.colors
    val shape = RoundedCornerShape(min(style.tokens.cardRadius, 16f).dp)
    val border = when {
        selected -> BorderStroke(2.dp, current.colors.accent)
        preview.isPixel -> BorderStroke(2.dp, c.ink)
        else -> BorderStroke(1.dp, c.line)
    }
    Column(
        modifier = modifier
            .clip(shape)
            .background(Brush.verticalGradient(listOf(c.background, c.backgroundAlt)))
            .border(border, shape)
            .selectable(selected = selected, role = Role.RadioButton, onClick = onClick)
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SkinGlyph(style, c, 34.dp)
            Spacer(Modifier.weight(1f))
            if (selected) {
                Box(
                    Modifier
                        .size(20.dp)
                        .clip(if (current.isPixel) RoundedCornerShape(0.dp) else CircleShape)
                        .background(current.colors.accent),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Filled.Check, contentDescription = null, tint = current.colors.onAccent, modifier = Modifier.size(14.dp))
                }
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                style.title,
                style = TextStyle(fontFamily = preview.titleFamily, fontWeight = preview.titleWeight, fontSize = 15.sp),
                color = c.ink,
                maxLines = 1,
            )
            Text(
                style.tagline,
                style = MaterialTheme.typography.labelSmall,
                color = c.muted,
                minLines = 2,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            listOf(c.accent, c.rest, c.highlight).forEach { swatch ->
                Box(
                    Modifier
                        .width(18.dp)
                        .height(6.dp)
                        .clip(if (preview.isPixel) RoundedCornerShape(0.dp) else RoundedCornerShape(3.dp))
                        .background(swatch),
                )
            }
        }
    }
}

/** Tiny ring in the skin's ring style with a rest-colored center dot. */
@Composable
fun SkinGlyph(style: AppUiStyle, c: SkinColors, size: Dp) {
    val t = style.tokens
    Canvas(Modifier.size(size)) {
        val w = (size.toPx() * 0.11f).coerceAtLeast(2f)
        val d = this.size.minDimension - w
        val topLeft = Offset(w / 2f, w / 2f)
        val sweep = 0.68f
        when (t.ringStyle) {
            SkinRingStyle.Smooth -> {
                drawArc(c.line, 0f, 360f, false, topLeft, Size(d, d), style = Stroke(w))
                drawArc(c.accent, -90f, 360f * sweep, false, topLeft, Size(d, d), style = Stroke(w, cap = StrokeCap.Round))
            }
            SkinRingStyle.Ticks -> {
                val outer = this.size.minDimension / 2f
                for (i in 0 until 24) {
                    val a = Math.toRadians((i * 15f - 90f).toDouble())
                    val len = if (i % 6 == 0) w * 2.2f else w * 1.4f
                    drawLine(
                        if (i < 24 * sweep) c.accent else c.line,
                        Offset(center.x + cos(a).toFloat() * (outer - len), center.y + sin(a).toFloat() * (outer - len)),
                        Offset(center.x + cos(a).toFloat() * outer, center.y + sin(a).toFloat() * outer),
                        strokeWidth = w * 0.55f,
                        cap = StrokeCap.Round,
                    )
                }
            }
            SkinRingStyle.Segmented -> {
                val n = 12
                val chord = (Math.PI.toFloat() * d / n) * 0.6f
                for (i in 0 until n) {
                    rotate(i * 360f / n + 180f / n) {
                        drawRect(
                            if (i < n * sweep) c.accent else c.line,
                            Offset(center.x - chord / 2f, center.y - d / 2f - w / 2f),
                            Size(chord, w),
                        )
                    }
                }
            }
        }
        val dot = this.size.minDimension * 0.13f
        if (t.cardBorder == SkinCardBorder.Ink) {
            drawRect(c.rest, Offset(center.x - dot, center.y - dot), Size(dot * 2f, dot * 2f))
        } else {
            drawCircle(c.rest, dot, center)
        }
    }
}
