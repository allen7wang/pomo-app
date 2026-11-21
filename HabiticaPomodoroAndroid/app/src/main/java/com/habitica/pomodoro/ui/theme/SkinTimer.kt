package com.habitica.pomodoro.ui.theme

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * Progress ring + digits for the active skin. Smooth (optional knob/glow), 60 ticks, or
 * square segmented blocks, drawn in [tint] (accent for focus, rest for breaks). Tapping toggles the timer
 * (same interaction as iOS), so the ring is exposed to accessibility as one button.
 */
@Composable
fun SkinTimerRing(
    progress: Float,
    tint: Color,
    timeText: String,
    caption: String,
    ringSize: Dp,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val skin = LocalSkin.current
    val c = skin.colors
    val color = tint
    val target = progress.coerceIn(0f, 1f)
    val animated = remember { Animatable(target) }
    LaunchedEffect(target, skin.reduceMotion) {
        // A new phase restarts at 0: snap instead of unwinding the ring backwards.
        if (skin.reduceMotion || target < animated.value) animated.snapTo(target)
        else animated.animateTo(target, tween(durationMillis = 600, easing = FastOutSlowInEasing))
    }
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val pressScale by animateFloatAsState(
        targetValue = if (pressed) 0.97f else 1f,
        animationSpec = if (skin.reduceMotion) snap() else tween(120),
        label = "ringPress",
    )

    Box(
        modifier = modifier
            .size(ringSize)
            .scale(pressScale)
            .semantics { contentDescription = "计时 $timeText，$caption" }
            .clickable(interactionSource = interaction, indication = null, role = Role.Button, onClickLabel = caption, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val p = animated.value
            when (skin.tokens.ringStyle) {
                SkinRingStyle.Smooth -> drawSmoothRing(skin, p, color)
                SkinRingStyle.Ticks -> drawTickRing(skin, p, color)
                SkinRingStyle.Segmented -> drawSegmentRing(skin, p, color)
            }
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
            TimerDigits(timeText, ringSize)
            Text(caption, style = MaterialTheme.typography.bodySmall, color = c.muted, maxLines = 1)
        }
    }
}

/** Clock digits in the skin's timer face; Pixel draws the 5x7 glyphs as crisp squares. */
@Composable
fun TimerDigits(text: String, ringSize: Dp, color: Color = LocalSkin.current.colors.ink) {
    val skin = LocalSkin.current
    val glyphs = text.map { PixelGlyphs.table[it] }
    if (skin.tokens.timerDesign == SkinFontDesign.Pixel && glyphs.none { it == null }) {
        val cells = glyphs.sumOf { it!!.first().length } + (glyphs.size - 1)
        PixelDigits(text, cell = (ringSize.value * 0.6f / cells).dp, color = color, shadow = skin.colors.line)
    } else {
        Text(
            text,
            style = TextStyle(
                fontFamily = if (skin.tokens.timerDesign == SkinFontDesign.Pixel) FontFamily.Monospace else skin.timerFamily,
                fontWeight = skin.timerWeight,
                fontSize = (ringSize.value * 0.215f).sp,
                letterSpacing = if (skin.timerFamily == FontFamily.Monospace) 0.sp else 1.sp,
                fontFeatureSettings = "tnum",
            ),
            color = color,
            maxLines = 1,
        )
    }
}

/** Draws [text] from [PixelGlyphs]; one blank column between glyphs, cells snapped to whole pixels. */
@Composable
fun PixelDigits(text: String, cell: Dp, color: Color, modifier: Modifier = Modifier, shadow: Color? = null) {
    val rows = text.map { PixelGlyphs.table.getValue(it) }
    val cols = rows.sumOf { it.first().length } + (rows.size - 1)
    Canvas(modifier = modifier.size(cell * (cols + 1), cell * (PixelGlyphs.HEIGHT + 1))) {
        val px = max(1f, floor(cell.toPx()))
        // Drop shadow by one whole cell keeps it on the glyph grid.
        val drop = px
        fun pass(tint: Color, dx: Float) {
            var x0 = 0f
            rows.forEach { glyph ->
                glyph.forEachIndexed { y, row ->
                    row.forEachIndexed { x, bit ->
                        if (bit == '1') drawRect(tint, Offset(x0 + x * px + dx, y * px + dx), Size(px, px))
                    }
                }
                x0 += (glyph.first().length + 1) * px
            }
        }
        if (shadow != null) pass(shadow, drop)
        pass(color, 0f)
    }
}

private fun DrawScope.ringGeometry(width: Float): Pair<Offset, Float> {
    val radius = (min(size.width, size.height) - width) / 2f
    return center to radius
}

private fun DrawScope.drawSmoothRing(skin: SkinSpec, p: Float, color: Color) {
    val c = skin.colors
    val w = skin.tokens.ringWidth.dp.toPx()
    val knobR = if (skin.tokens.ringKnob) max(w * 0.9f, 5.dp.toPx()) else 0f
    val glowPad = if (skin.tokens.ringGlow) w * 3f else 0f
    val inset = max(w, knobR * 2f) / 2f + glowPad
    val diameter = min(size.width, size.height) - inset * 2f
    val topLeft = Offset((size.width - diameter) / 2f, (size.height - diameter) / 2f)
    val arcSize = Size(diameter, diameter)
    drawArc(c.line, -90f, 360f, false, topLeft, arcSize, style = Stroke(w))
    val sweep = 360f * p
    if (skin.tokens.ringGlow && p > 0f) {
        listOf(6f to 0.05f, 3.5f to 0.09f, 2f to 0.16f).forEach { (k, a) ->
            drawArc(color.copy(alpha = a), -90f, sweep, false, topLeft, arcSize, style = Stroke(w * k, cap = StrokeCap.Round))
        }
    }
    if (p > 0f) drawArc(color, -90f, sweep, false, topLeft, arcSize, style = Stroke(w, cap = StrokeCap.Round))
    if (skin.tokens.ringKnob) {
        val r = diameter / 2f
        val angle = Math.toRadians((sweep - 90f).toDouble())
        val knob = Offset(center.x + r * cos(angle).toFloat(), center.y + r * sin(angle).toFloat())
        if (skin.tokens.ringGlow) drawCircle(color.copy(alpha = 0.22f), knobR * 2.2f, knob)
        drawCircle(color, knobR, knob)
        drawCircle(c.surface, knobR * 0.42f, knob)
    }
}

private fun DrawScope.drawTickRing(skin: SkinSpec, p: Float, color: Color) {
    val c = skin.colors
    val w = max(skin.tokens.ringWidth.dp.toPx(), 1.5f)
    val (center, _) = ringGeometry(w)
    val outer = min(size.width, size.height) / 2f - w
    val lit = p * 60f
    for (i in 0 until 60) {
        val major = i % 5 == 0
        val len = (if (major) 14.dp else 8.dp).toPx()
        val fraction = (lit - i).coerceIn(0f, 1f)
        val tint = if (fraction > 0f) lerpColor(c.line, color, fraction) else c.line
        val angle = Math.toRadians((i * 6f - 90f).toDouble())
        val dx = cos(angle).toFloat()
        val dy = sin(angle).toFloat()
        drawLine(
            tint,
            Offset(center.x + dx * (outer - len), center.y + dy * (outer - len)),
            Offset(center.x + dx * outer, center.y + dy * outer),
            strokeWidth = if (major) w * 1.25f else w,
            cap = StrokeCap.Round,
        )
    }
}

/** Straight square blocks around the dial; whole blocks light up, pixel-game style. */
private fun DrawScope.drawSegmentRing(skin: SkinSpec, p: Float, color: Color) {
    val c = skin.colors
    val w = skin.tokens.ringWidth.dp.toPx()
    val segments = 30
    val shadow = skin.tokens.shadow.x.dp.toPx() * 0.67f
    val radius = min(size.width, size.height) / 2f - w / 2f - shadow
    val chord = (2f * Math.PI.toFloat() * radius / segments) * 0.62f
    val lit = floor(p * segments + 0.0001f).toInt()
    val topLeft = Offset(center.x - chord / 2f, center.y - radius - w / 2f)
    fun angle(i: Int) = i * 360f / segments + 180f / segments
    // Shadows first and in screen space, so every block drops toward the bottom-right.
    translate(shadow, shadow) {
        for (i in 0 until lit) rotate(angle(i)) { drawRect(c.ink, topLeft, Size(chord, w)) }
    }
    for (i in 0 until segments) {
        rotate(angle(i)) { drawRect(if (i < lit) color else c.line, topLeft, Size(chord, w)) }
    }
}

private fun lerpColor(a: Color, b: Color, t: Float) = androidx.compose.ui.graphics.lerp(a, b, t)
