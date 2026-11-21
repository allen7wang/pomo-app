package com.habitica.pomodoro.ui.theme

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.platform.LocalContext

/**
 * Same skins as Mac/iOS, in picker order. Storage values are the token ids from
 * design/skins.json; the choice stays on this device, not in synced JSON.
 */
enum class AppUiStyle(val storageValue: String) {
    Mint("mint"),
    Garden("garden"),
    Studio("studio"),
    Tomato("tomato"),
    Midnight("midnight"),
    Pixel("pixel"),
    Sakura("sakura");

    val tokens: SkinTokens = SkinCatalog.all.first { it.id == storageValue }
    val title: String get() = tokens.title
    val tagline: String get() = tokens.tagline

    companion object {
        fun fromStorage(raw: String?): AppUiStyle =
            entries.firstOrNull { it.storageValue == raw } ?: Mint
    }
}

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

val LocalAppSkin = staticCompositionLocalOf { AppUiStyle.Mint }

/** [preview] is a debug-only launch override; it is shown but not persisted. */
@Composable
fun rememberAppSkinState(preview: AppUiStyle? = null): AppSkinState {
    val context = LocalContext.current
    return remember { AppSkinState(preview ?: readAppSkin(context)) }
}
