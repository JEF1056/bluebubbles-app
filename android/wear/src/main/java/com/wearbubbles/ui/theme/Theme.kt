package com.wearbubbles.ui.theme

import android.content.Context
import android.os.Build
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.sp
import androidx.wear.compose.material.Colors
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.material.Typography
import com.wearbubbles.R

// Wear OS 6 Material 3 tonal dark palette (pure #000000 canvas)
val Primary = Color(0xFFDCE2EE)
val OnPrimary = Color(0xFF1F1F1F)
val PrimaryAction = Primary
val OnPrimaryAction = OnPrimary
val PrimaryContainer = Color(0xFF35373B)
val OnPrimaryContainer = Color(0xFFE8EAED)

val Surface = Color(0xFF000000)
val SurfaceContainerLow = Color(0xFF17181B)
val SurfaceContainer = Color(0xFF202124)
val SurfaceContainerUnread = Color(0xFF282A2E)
val SurfaceContainerHigh = Color(0xFF35373B)
val OnSurface = Color(0xFFE8EAED)
val OnSurfaceVariant = Color(0xFF9AA0A6)
val SubtleText = Color(0xFF9AA0A6)

val SentBubble = SurfaceContainerHigh
val OnSentBubble = OnSurface
val ReceivedBubble = SurfaceContainer
val OnReceivedBubble = OnSurface

val ErrorColor = Color(0xFFF2B8B5)
val OnError = Color(0xFF601410)
val ErrorContainer = Color(0xFF8C1D18)
val OnErrorContainer = Color(0xFFF9DEDC)

val SuccessColor = Color(0xFF6DD58C)
val OnSuccess = Color(0xFF0A3818)

val GroupAvatar = Color(0xFF24374D)

@Immutable
data class WearPalette(
    val canvas: Color = Surface,
    val primary: Color = Primary,
    val onPrimary: Color = OnPrimary,
    val primaryAction: Color = PrimaryAction,
    val onPrimaryAction: Color = OnPrimaryAction,
    val primaryContainer: Color = PrimaryContainer,
    val onPrimaryContainer: Color = OnPrimaryContainer,
    val sentBubble: Color = SentBubble,
    val onSentBubble: Color = OnSentBubble,
    val receivedBubble: Color = ReceivedBubble,
    val onReceivedBubble: Color = OnReceivedBubble,
    val surfaceContainerLow: Color = SurfaceContainerLow,
    val surfaceContainer: Color = SurfaceContainer,
    val surfaceContainerHigh: Color = SurfaceContainerHigh,
    val surfaceContainerUnread: Color = SurfaceContainerUnread,
    val onSurface: Color = OnSurface,
    val onSurfaceVariant: Color = OnSurfaceVariant,
    val subtleText: Color = SubtleText
)

val DefaultWearPalette = WearPalette()

val LocalWearPalette = staticCompositionLocalOf { DefaultWearPalette }

@Immutable
data class AvatarSwatch(
    val container: Color,
    val content: Color
)

val AvatarSwatches: List<AvatarSwatch> = listOf(
    AvatarSwatch(container = Color(0xFF1B3A5C), content = Color(0xFFA8C7FA)),
    AvatarSwatch(container = Color(0xFF163F44), content = Color(0xFF80DEEA)),
    AvatarSwatch(container = Color(0xFF1C3F2A), content = Color(0xFFA8DAB5)),
    AvatarSwatch(container = Color(0xFF4A3519), content = Color(0xFFFDD663)),
    AvatarSwatch(container = Color(0xFF52292D), content = Color(0xFFF2B8B5)),
    AvatarSwatch(container = Color(0xFF372C54), content = Color(0xFFD0BCFF)),
    AvatarSwatch(container = Color(0xFF223354), content = Color(0xFF9ECAFF)),
    AvatarSwatch(container = Color(0xFF4E263D), content = Color(0xFFF8BBD0))
)

/** Deterministic Google Messages-style pastel-on-tonal swatch for a contact/chat seed. */
fun avatarSwatchFor(seed: String): AvatarSwatch {
    val index = (seed.hashCode() and 0x7fffffff) % AvatarSwatches.size
    return AvatarSwatches[index]
}

/**
 * Returns the single uppercase monogram letter for a contact name, or null when the title
 * looks like a phone number / symbol string (caller renders a Person icon instead).
 */
fun avatarMonogram(title: String): String? {
    val trimmed = title.trim()
    val first = trimmed.firstOrNull() ?: return null
    return if (first.isLetter()) first.uppercaseChar().toString() else null
}

/**
 * Resolves Wear OS dynamic Material You palette directly from Android platform system color
 * resources (API 34+ dark surface containers, API 31+ system accent1/neutral1) without pulling
 * wear compose-material3 1.5 (which breaks Horologist 0.6.x's foundation 1.4 OnFocusChange ABI).
 */
fun resolveWearPalette(context: Context, dynamicColor: Boolean): WearPalette {
    if (!dynamicColor || Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
        return DefaultWearPalette
    }
    return runCatching {
        fun resColor(id: Int): Color = Color(context.getColor(id))
        val primary = resColor(android.R.color.system_accent1_100)
        val onPrimary = resColor(android.R.color.system_accent1_900)
        val primaryContainer = resColor(android.R.color.system_accent1_700)
        val onPrimaryContainer = resColor(android.R.color.system_accent1_100)
        val containerLow = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            resColor(android.R.color.system_surface_container_low_dark)
        } else {
            SurfaceContainerLow
        }
        val container = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            resColor(android.R.color.system_surface_container_dark)
        } else {
            SurfaceContainer
        }
        val containerHigh = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            resColor(android.R.color.system_surface_container_high_dark)
        } else {
            SurfaceContainerHigh
        }
        val onSurface = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            resColor(android.R.color.system_on_surface_dark)
        } else {
            OnSurface
        }
        val onSurfaceVariant = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            resColor(android.R.color.system_on_surface_variant_dark)
        } else {
            OnSurfaceVariant
        }
        DefaultWearPalette.copy(
            canvas = Surface,
            primary = primary,
            onPrimary = onPrimary,
            primaryAction = primary,
            onPrimaryAction = onPrimary,
            primaryContainer = primaryContainer,
            onPrimaryContainer = onPrimaryContainer,
            sentBubble = containerHigh,
            onSentBubble = onSurface,
            receivedBubble = container,
            onReceivedBubble = onSurface,
            surfaceContainerLow = containerLow,
            surfaceContainer = container,
            surfaceContainerHigh = containerHigh,
            surfaceContainerUnread = containerHigh,
            onSurface = onSurface,
            onSurfaceVariant = onSurfaceVariant,
            subtleText = onSurfaceVariant
        )
    }.getOrDefault(DefaultWearPalette)
}

// Official OFL Google Sans bundled in res/font/ to match Google Messages on Wear OS.
@OptIn(ExperimentalTextApi::class)
val GoogleSansFontFamily = FontFamily(
    Font(
        resId = R.font.google_sans,
        weight = FontWeight.Normal,
        variationSettings = FontVariation.Settings(FontVariation.weight(400)),
    ),
    Font(
        resId = R.font.google_sans,
        weight = FontWeight.Medium,
        variationSettings = FontVariation.Settings(FontVariation.weight(500)),
    ),
    Font(
        resId = R.font.google_sans,
        weight = FontWeight.SemiBold,
        variationSettings = FontVariation.Settings(FontVariation.weight(600)),
    ),
    Font(
        resId = R.font.google_sans,
        weight = FontWeight.Bold,
        variationSettings = FontVariation.Settings(FontVariation.weight(700)),
    ),
    Font(
        resId = R.font.google_sans_italic,
        weight = FontWeight.Normal,
        style = FontStyle.Italic,
        variationSettings = FontVariation.Settings(FontVariation.weight(400)),
    ),
    Font(
        resId = R.font.google_sans_italic,
        weight = FontWeight.Medium,
        style = FontStyle.Italic,
        variationSettings = FontVariation.Settings(FontVariation.weight(500)),
    ),
    Font(
        resId = R.font.google_sans_italic,
        weight = FontWeight.SemiBold,
        style = FontStyle.Italic,
        variationSettings = FontVariation.Settings(FontVariation.weight(600)),
    ),
    Font(
        resId = R.font.google_sans_italic,
        weight = FontWeight.Bold,
        style = FontStyle.Italic,
        variationSettings = FontVariation.Settings(FontVariation.weight(700)),
    ),
)

// Disables legacy Android font ascent/descent padding and trims leading top/bottom so text sits
// optically centered inside pills, bubbles, chips, and circular avatars.
val CenteredPlatformStyle = PlatformTextStyle(includeFontPadding = false)
val CenteredLineHeightStyle = LineHeightStyle(
    alignment = LineHeightStyle.Alignment.Center,
    trim = LineHeightStyle.Trim.Both
)

fun centeredTextStyle(
    fontSize: TextUnit,
    lineHeight: TextUnit = fontSize * 1.25f,
    fontWeight: FontWeight = FontWeight.Normal,
    letterSpacing: TextUnit = TextUnit.Unspecified
): TextStyle = TextStyle(
    fontFamily = GoogleSansFontFamily,
    fontSize = fontSize,
    lineHeight = lineHeight,
    fontWeight = fontWeight,
    letterSpacing = letterSpacing,
    platformStyle = CenteredPlatformStyle,
    lineHeightStyle = CenteredLineHeightStyle
)

private fun TextStyle.withOpticalCentering(): TextStyle = copy(
    platformStyle = CenteredPlatformStyle,
    lineHeightStyle = CenteredLineHeightStyle
)

private val BaseWearTypography = Typography(defaultFontFamily = GoogleSansFontFamily)
val WearTypography = Typography(
    display1 = BaseWearTypography.display1.withOpticalCentering(),
    display2 = BaseWearTypography.display2.withOpticalCentering(),
    display3 = BaseWearTypography.display3.withOpticalCentering(),
    title1 = BaseWearTypography.title1.withOpticalCentering(),
    title2 = BaseWearTypography.title2.copy(
        fontSize = 18.sp,
        lineHeight = 22.sp,
        fontWeight = FontWeight.SemiBold
    ).withOpticalCentering(),
    title3 = BaseWearTypography.title3.copy(
        fontSize = 15.sp,
        lineHeight = 19.sp,
        fontWeight = FontWeight.SemiBold
    ).withOpticalCentering(),
    body1 = BaseWearTypography.body1.copy(
        fontSize = 14.sp,
        lineHeight = 18.sp
    ).withOpticalCentering(),
    body2 = BaseWearTypography.body2.copy(
        fontSize = 13.sp,
        lineHeight = 17.sp
    ).withOpticalCentering(),
    button = BaseWearTypography.button.copy(
        fontSize = 14.sp,
        lineHeight = 18.sp,
        fontWeight = FontWeight.Medium
    ).withOpticalCentering(),
    caption1 = BaseWearTypography.caption1.copy(
        fontSize = 12.sp,
        lineHeight = 15.sp
    ).withOpticalCentering(),
    caption2 = BaseWearTypography.caption2.copy(
        fontSize = 11.sp,
        lineHeight = 14.sp
    ).withOpticalCentering(),
    caption3 = BaseWearTypography.caption3.copy(
        fontSize = 10.sp,
        lineHeight = 13.sp
    ).withOpticalCentering()
)

private fun WearPalette.toWearColors(): Colors = Colors(
    primary = primary,
    primaryVariant = primaryContainer,
    secondary = SuccessColor,
    secondaryVariant = SuccessColor,
    background = canvas,
    surface = surfaceContainer,
    error = ErrorColor,
    onPrimary = onPrimary,
    onSecondary = OnSuccess,
    onBackground = onSurface,
    onSurface = onSurface,
    onSurfaceVariant = onSurfaceVariant,
    onError = OnError
)

@Composable
fun WearBubblesTheme(
    dynamicColor: Boolean = true,
    content: @Composable () -> Unit
) {
    val context = LocalContext.current
    val palette = remember(context, dynamicColor) { resolveWearPalette(context, dynamicColor) }
    val wearColors = remember(palette) { palette.toWearColors() }

    CompositionLocalProvider(LocalWearPalette provides palette) {
        MaterialTheme(
            colors = wearColors,
            typography = WearTypography,
            content = content
        )
    }
}
