package com.habitica.pomodoro.ui.theme

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

@Composable
fun SkinPaletteButton(skins: AppSkinState) {
    val context = LocalContext.current
    val current by skins.style
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) {
            Icon(Icons.Outlined.Palette, contentDescription = "切换界面风格")
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            AppUiStyle.entries.forEach { style ->
                DropdownMenuItem(
                    text = {
                        Text(if (style == current) "✓ ${style.title} · ${style.tagline}" else "${style.title} · ${style.tagline}")
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
    Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
        Text(
            "三种皮肤可随时切换。选择保存在本机，不影响任务、计时或同步。",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        AppUiStyle.entries.forEach { style ->
            val selected = style == current
            val preview = skinPalette(style, dark = false)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(if (selected) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surface)
                    .border(
                        1.dp,
                        if (selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline,
                        RoundedCornerShape(10.dp),
                    )
                    .clickable { skins.select(context, style) }
                    .padding(12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Dot(preview.color(preview.accent))
                    Dot(preview.color(preview.accentSoft))
                    Dot(preview.color(preview.background), bordered = true)
                }
                Column(modifier = Modifier.weight(1f)) {
                    Text(style.title, fontWeight = FontWeight.Medium)
                    Text(style.tagline, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (selected) Text("✓", color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.Bold)
            }
        }
    }
}

@Composable
private fun Dot(color: androidx.compose.ui.graphics.Color, bordered: Boolean = false) {
    Spacer(
        Modifier
            .size(12.dp)
            .clip(CircleShape)
            .background(color)
            .then(if (bordered) Modifier.border(1.dp, MaterialTheme.colorScheme.outline, CircleShape) else Modifier),
    )
}
