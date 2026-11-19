package com.habitica.pomodoro.ui.theme

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

/** Same three skins as Mac/iOS. Choice stays on this device, not in synced JSON. */
enum class AppUiStyle(val storageValue: String, val title: String, val tagline: String) {
    Mint("mint", "清新原生", "紧凑、有序，日常好用"),
    Garden("garden", "留白花园", "安静、舒展，专注优先"),
    Studio("studio", "效率工作台", "专注与任务并排");

    companion object {
        fun fromStorage(raw: String?): AppUiStyle =
            entries.firstOrNull { it.storageValue == raw } ?: Mint
    }
}

data class SkinPalette(
    val background: Long,
    val surface: Long,
    val subtle: Long,
    val line: Long,
    val ink: Long,
    val muted: Long,
    val accent: Long,
    val accentSoft: Long,
    val onAccent: Long,
) {
    fun color(hex: Long): Color = Color(0xFF000000 or hex)
}

fun skinPalette(style: AppUiStyle, dark: Boolean): SkinPalette = when (style) {
    AppUiStyle.Mint -> if (dark) mintDark else mintLight
    AppUiStyle.Garden -> if (dark) gardenDark else gardenLight
    AppUiStyle.Studio -> if (dark) studioDark else studioLight
}

private val mintLight = SkinPalette(0xFBFCF9, 0xFFFFFF, 0xF0F4EC, 0xDCE5D8, 0x263A31, 0x627166, 0x2D7055, 0xE4EEE1, 0xFFFFFF)
private val mintDark = SkinPalette(0x111B16, 0x1B2A22, 0x22362A, 0x38503E, 0xEDF3E9, 0xB7C8B7, 0xA9D6B1, 0x2A4330, 0x15271B)
private val gardenLight = SkinPalette(0xF9F9F1, 0xFCFCF6, 0xF0F1E7, 0xDCE1CE, 0x38432F, 0x68725E, 0x576F48, 0xE8EDD9, 0xFFFFFF)
private val gardenDark = SkinPalette(0x151A13, 0x1E251B, 0x262E22, 0x3C4636, 0xEDF1E4, 0xBAC4AE, 0xB7CDA5, 0x2E3A28, 0x17200F)
private val studioLight = SkinPalette(0xFCFDFA, 0xFFFFFF, 0xF0F4EE, 0xDDE5DD, 0x263B35, 0x607269, 0x286C61, 0xE4EEE7, 0xFFFFFF)
private val studioDark = SkinPalette(0x0F1A17, 0x182622, 0x20332C, 0x35504A, 0xEDF4EF, 0xAFC6BF, 0xA5D3C6, 0x27443C, 0x0E211C)

private const val PREFS = "habitica_pomodoro_ui"
private const val KEY = "app.uiStyle.v1"

fun readAppSkin(context: Context): AppUiStyle {
    val raw = context.applicationContext
        .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        .getString(KEY, null)
    return AppUiStyle.fromStorage(raw)
}

fun writeAppSkin(context: Context, style: AppUiStyle) {
    context.applicationContext
        .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        .edit()
        .putString(KEY, style.storageValue)
        .apply()
}

class AppSkinState(initial: AppUiStyle) {
    var style = mutableStateOf(initial)
        private set

    fun select(context: Context, next: AppUiStyle) {
        writeAppSkin(context, next)
        style.value = next
    }
}

val LocalAppSkin = compositionLocalOf { AppUiStyle.Mint }

@Composable
fun rememberAppSkinState(): AppSkinState {
    val context = LocalContext.current
    return remember { AppSkinState(readAppSkin(context)) }
}
