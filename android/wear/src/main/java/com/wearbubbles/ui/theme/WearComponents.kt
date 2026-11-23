package com.wearbubbles.ui.theme

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.os.Build
import android.speech.RecognizerIntent
import android.text.InputType
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterExitState
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Group
import androidx.compose.material.icons.rounded.Person
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.BlurEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.wear.compose.foundation.ExperimentalWearFoundationApi
import androidx.wear.compose.foundation.HierarchicalFocusCoordinator
import androidx.wear.compose.material.CircularProgressIndicator
import androidx.wear.compose.material.Icon
import androidx.wear.compose.material.Text
import coil.compose.AsyncImage
import coil.request.ImageRequest
import com.wearbubbles.ui.components.rememberReducedMotion
import kotlinx.coroutines.delay
import java.io.File

internal const val BLUR_FADE_ENTER_MS = 200
internal const val BLUR_FADE_EXIT_MS = 180
internal const val BLUR_FADE_MAX_DP = 2.5f
internal const val BLUR_FADE_THRESHOLD_DP = 0.1f

internal fun resolveBlurFadeDp(
    fraction: Float,
    sdkInt: Int = Build.VERSION.SDK_INT,
    reducedMotion: Boolean = false,
    maxBlurDp: Float = BLUR_FADE_MAX_DP
): Float {
    if (reducedMotion || sdkInt < Build.VERSION_CODES.S) return 0f
    val blurDp = maxBlurDp * fraction.coerceIn(0f, 1f)
    return if (blurDp > BLUR_FADE_THRESHOLD_DP) blurDp else 0f
}

/**
 * Transitions changing content with a subtle 2.5dp Gaussian blur-fade on API 31+ (fade-only on
 * API 30, instant swap when reduced motion is enabled). Reads blur fraction only in graphicsLayer
 * so content never recomposes per frame and carries zero offscreen layer overhead at rest.
 */
@Composable
fun <T> BlurFadeContent(
    targetState: T,
    modifier: Modifier = Modifier,
    contentAlignment: Alignment = Alignment.Center,
    animateSize: Boolean = false,
    contentKey: (T) -> Any? = { it },
    content: @Composable (T) -> Unit
) {
    if (rememberReducedMotion()) {
        Box(modifier = modifier, contentAlignment = contentAlignment) {
            content(targetState)
        }
        return
    }
    AnimatedContent(
        targetState = targetState,
        modifier = modifier,
        contentAlignment = contentAlignment,
        contentKey = contentKey,
        transitionSpec = {
            (fadeIn(tween(BLUR_FADE_ENTER_MS, easing = FastOutSlowInEasing)) togetherWith
                fadeOut(tween(BLUR_FADE_EXIT_MS, easing = FastOutSlowInEasing)))
                .using(
                    if (animateSize) {
                        SizeTransform(clip = false) { _, _ ->
                            tween(BLUR_FADE_ENTER_MS, easing = FastOutSlowInEasing)
                        }
                    } else {
                        null
                    }
                )
        },
        label = "blur_fade_content"
    ) { state ->
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val blurFraction = transition.animateFloat(
                transitionSpec = {
                    tween(
                        durationMillis = if (targetState == EnterExitState.Visible) {
                            BLUR_FADE_ENTER_MS
                        } else {
                            BLUR_FADE_EXIT_MS
                        },
                        easing = FastOutSlowInEasing
                    )
                },
                label = "blur_fade_fraction"
            ) { enterExit ->
                if (enterExit == EnterExitState.Visible) 0f else 1f
            }
            Box(
                modifier = Modifier.graphicsLayer {
                    val blurDp = resolveBlurFadeDp(blurFraction.value)
                    renderEffect = if (blurDp > 0f) {
                        val px = blurDp.dp.toPx()
                        if (px > 0f) BlurEffect(px, px, TileMode.Decal) else null
                    } else {
                        null
                    }
                },
                contentAlignment = contentAlignment
            ) {
                content(state)
            }
        } else {
            content(state)
        }
    }
}

/**
 * Shared Google Messages-style circular contact/group avatar with deterministic pastel-on-tonal
 * monogram fallback, Person icon fallback for phone numbers, and optional unread cutout badge.
 */
@Composable
fun ContactAvatar(
    title: String,
    seed: String,
    modifier: Modifier = Modifier,
    avatarPath: String? = null,
    isGroup: Boolean = false,
    size: Dp = 36.dp,
    showUnreadDot: Boolean = false,
    badgeCutoutColor: Color = SurfaceContainer
) {
    val context = LocalContext.current
    val palette = LocalWearPalette.current
    val avatarFile = remember(avatarPath) {
        avatarPath?.substringBefore("?")?.takeIf { it.isNotBlank() }?.let { File(it) }
    }
    var imageFailed by remember(avatarPath) { mutableStateOf(false) }
    val swatch = remember(seed) { avatarSwatchFor(seed) }
    val monogram = remember(title) { avatarMonogram(title) }
    val iconSize = (size.value * 0.52f).dp
    val monogramFontSize = (size.value * 0.43f).sp

    Box(modifier = modifier.size(size), contentAlignment = Alignment.Center) {
        if (avatarFile != null && !imageFailed) {
            AsyncImage(
                model = ImageRequest.Builder(context)
                    .data(avatarFile)
                    .memoryCacheKey(avatarPath)
                    .crossfade(true)
                    .build(),
                contentDescription = title,
                contentScale = ContentScale.Crop,
                onError = { imageFailed = true },
                modifier = Modifier
                    .size(size)
                    .clip(CircleShape)
            )
        } else {
            val containerColor = if (isGroup) GroupAvatar else swatch.container
            val contentColor = if (isGroup) palette.primary else swatch.content
            Box(
                modifier = Modifier
                    .size(size)
                    .clip(CircleShape)
                    .background(containerColor),
                contentAlignment = Alignment.Center
            ) {
                if (isGroup) {
                    Icon(
                        imageVector = Icons.Rounded.Group,
                        contentDescription = null,
                        tint = contentColor,
                        modifier = Modifier.size(iconSize)
                    )
                } else if (monogram == null) {
                    Icon(
                        imageVector = Icons.Rounded.Person,
                        contentDescription = null,
                        tint = contentColor,
                        modifier = Modifier.size(iconSize)
                    )
                } else {
                    Text(
                        text = monogram,
                        style = centeredTextStyle(
                            fontSize = monogramFontSize,
                            lineHeight = monogramFontSize,
                            fontWeight = FontWeight.Medium
                        ),
                        color = contentColor,
                        textAlign = TextAlign.Center,
                        maxLines = 1
                    )
                }
            }
        }

        if (showUnreadDot) {
            Box(
                modifier = Modifier
                    .size(11.dp)
                    .align(Alignment.TopEnd)
                    .clip(CircleShape)
                    .background(palette.primary)
                    .border(width = 1.5.dp, color = badgeCutoutColor, shape = CircleShape)
            )
        }
    }
}

/**
 * Material 3 Expressive full-stadium Wear OS pill button with symmetric vertical padding and
 * optically centered text (using includeFontPadding=false + LineHeightStyle Center/Trim.Both).
 */
@Composable
fun WearPillButton(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    secondaryLabel: String? = null,
    leadingIcon: (@Composable () -> Unit)? = null,
    backgroundColor: Color = LocalWearPalette.current.surfaceContainer,
    contentColor: Color = LocalWearPalette.current.onSurface,
    secondaryContentColor: Color = contentColor.copy(alpha = 0.78f),
    centered: Boolean = false,
    enabled: Boolean = true,
    minHeight: Dp = 52.dp,
    shape: Shape = RoundedCornerShape(50),
    contentPadding: PaddingValues = PaddingValues(horizontal = 16.dp, vertical = 10.dp),
    labelFontWeight: FontWeight = FontWeight.Medium
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .defaultMinSize(minHeight = minHeight)
            .alpha(if (enabled) 1f else 0.48f)
            .clip(shape)
            .background(backgroundColor)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .padding(contentPadding),
        horizontalArrangement = if (centered) Arrangement.Center else Arrangement.Start,
        verticalAlignment = Alignment.CenterVertically
    ) {
        if (leadingIcon != null) {
            Box(contentAlignment = Alignment.Center) {
                leadingIcon()
            }
            Spacer(modifier = Modifier.width(10.dp))
        }
        Column(
            modifier = if (centered) Modifier else Modifier.weight(1f),
            horizontalAlignment = if (centered) Alignment.CenterHorizontally else Alignment.Start,
            verticalArrangement = Arrangement.Center
        ) {
            val textAlignment = if (centered) Alignment.Center else Alignment.CenterStart
            BlurFadeContent(
                targetState = label,
                contentAlignment = textAlignment
            ) { currentLabel ->
                Text(
                    text = currentLabel,
                    style = centeredTextStyle(
                        fontSize = 14.sp,
                        lineHeight = 17.sp,
                        fontWeight = labelFontWeight
                    ),
                    color = contentColor,
                    textAlign = if (centered) TextAlign.Center else TextAlign.Start,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
            if (!secondaryLabel.isNullOrBlank()) {
                Spacer(modifier = Modifier.height(2.dp))
                BlurFadeContent(
                    targetState = secondaryLabel,
                    contentAlignment = textAlignment
                ) { currentSecondary ->
                    Text(
                        text = currentSecondary,
                        style = centeredTextStyle(
                            fontSize = 11.sp,
                            lineHeight = 14.sp,
                            fontWeight = FontWeight.Normal
                        ),
                        color = secondaryContentColor,
                        textAlign = if (centered) TextAlign.Center else TextAlign.Start,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
        }
    }
}

/**
 * Circular M3 Expressive icon button meeting Wear OS 48dp minimum touch target.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun WearCircleIconButton(
    icon: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    onLongClick: (() -> Unit)? = null,
    size: Dp = 48.dp,
    iconSize: Dp = 22.dp,
    backgroundColor: Color = LocalWearPalette.current.surfaceContainerHigh,
    contentColor: Color = LocalWearPalette.current.onSurface,
    enabled: Boolean = true
) {
    Box(
        modifier = modifier
            .size(size)
            .alpha(if (enabled) 1f else 0.48f)
            .clip(CircleShape)
            .background(backgroundColor)
            .combinedClickable(
                enabled = enabled,
                role = Role.Button,
                onClick = onClick,
                onLongClick = onLongClick
            ),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            imageVector = icon,
            contentDescription = contentDescription,
            tint = contentColor,
            modifier = Modifier.size(iconSize)
        )
    }
}

internal fun extractSpokenText(results: List<String>?): String? =
    results?.firstOrNull { it.isNotBlank() }?.trim()

internal fun submitDirectKeyboardText(raw: String): String? =
    raw.trim().takeIf { it.isNotEmpty() }

/**
 * Re-claims Wear Compose rotary focus after inline View focus changes (e.g. WearDirectKeyboardInput)
 * or window focus transitions (waking from AOD, closing a modal, or returning from voice/notifications).
 */
@OptIn(ExperimentalWearFoundationApi::class)
@Composable
fun WearRotaryFocusScope(
    active: Boolean = true,
    content: @Composable () -> Unit
) {
    val windowFocused = LocalWindowInfo.current.isWindowFocused
    HierarchicalFocusCoordinator(
        requiresFocus = { active && windowFocused },
        content = content
    )
}

/**
 * Opens the system IME (Gboard) directly without Wear OS's RemoteInput voice/emoji/keyboard
 * chooser, and tears down cleanly when submitted, dismissed, or backed out.
 */
@Composable
fun WearDirectKeyboardInput(
    requestToken: Int,
    hint: String = "Message",
    imeAction: Int = EditorInfo.IME_ACTION_SEND,
    inputType: Int = InputType.TYPE_CLASS_TEXT or
        InputType.TYPE_TEXT_FLAG_CAP_SENTENCES or
        InputType.TYPE_TEXT_FLAG_AUTO_CORRECT,
    onSubmit: (String) -> Unit,
    onDismiss: () -> Unit
) {
    if (requestToken <= 0) return

    val context = LocalContext.current
    val hostView = LocalView.current
    val imm = remember(context) {
        context.getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
    }
    val currentOnSubmit by rememberUpdatedState(onSubmit)
    val currentOnDismiss by rememberUpdatedState(onDismiss)

    var editTextRef by remember { mutableStateOf<EditText?>(null) }
    var dismissedToken by remember { mutableIntStateOf(0) }

    fun restoreHostFocus() {
        if (hostView.isAttachedToWindow && !hostView.hasFocus()) {
            hostView.requestFocus()
        }
        hostView.post {
            if (hostView.isAttachedToWindow && !hostView.hasFocus()) {
                hostView.requestFocus()
            }
        }
    }

    fun dismiss(et: EditText?) {
        if (dismissedToken == requestToken) return
        dismissedToken = requestToken
        et?.let {
            it.setText("")
            it.clearFocus()
            imm?.hideSoftInputFromWindow(it.windowToken, 0)
        }
        restoreHostFocus()
        currentOnDismiss()
    }

    BackHandler(enabled = true) {
        dismiss(editTextRef)
    }

    val imeVisible = WindowInsets.ime.getBottom(LocalDensity.current) > 0
    var sawImeVisible by remember(requestToken) { mutableStateOf(false) }
    LaunchedEffect(requestToken, imeVisible) {
        if (imeVisible) {
            sawImeVisible = true
        } else if (sawImeVisible) {
            dismiss(editTextRef)
        }
    }

    LaunchedEffect(editTextRef, requestToken) {
        val et = editTextRef ?: return@LaunchedEffect
        var shown = false
        // Wait briefly for window focus (e.g. while an overlay Dialog finishes dismissing).
        for (attempt in 0 until 24) {
            if (et.isAttachedToWindow && et.hasWindowFocus()) {
                et.requestFocus()
                // Flag 0 (explicit user action); SHOW_IMPLICIT lets Wear OS IMEs decline.
                if (imm?.showSoftInput(et, 0) == true) {
                    shown = true
                    break
                }
            }
            delay(25L)
        }
        if (!shown) dismiss(et)
    }

    DisposableEffect(Unit) {
        onDispose {
            editTextRef?.let { imm?.hideSoftInputFromWindow(it.windowToken, 0) }
            restoreHostFocus()
        }
    }

    AndroidView(
        modifier = Modifier
            .size(1.dp)
            .alpha(0f),
        factory = { ctx ->
            object : EditText(ctx) {
                override fun onKeyPreIme(keyCode: Int, event: KeyEvent?): Boolean {
                    if (keyCode == KeyEvent.KEYCODE_BACK && event?.action == KeyEvent.ACTION_UP) {
                        dismiss(this)
                        return true
                    }
                    return super.onKeyPreIme(keyCode, event)
                }
            }.apply {
                isFocusable = true
                isFocusableInTouchMode = true
                background = null
                this.hint = hint
                this.inputType = inputType
                maxLines = 1
                imeOptions = imeAction
                setOnEditorActionListener { v, actionId, event ->
                    val isSubmitAction = actionId == imeAction ||
                        actionId == EditorInfo.IME_ACTION_SEND ||
                        actionId == EditorInfo.IME_ACTION_DONE ||
                        actionId == EditorInfo.IME_ACTION_SEARCH ||
                        actionId == EditorInfo.IME_ACTION_GO ||
                        (actionId == EditorInfo.IME_NULL &&
                            event?.keyCode == KeyEvent.KEYCODE_ENTER &&
                            event.action == KeyEvent.ACTION_DOWN)
                    if (isSubmitAction) {
                        submitDirectKeyboardText(v.text?.toString().orEmpty())?.let(currentOnSubmit)
                        dismiss(this)
                        true
                    } else {
                        actionId == EditorInfo.IME_NULL && event?.keyCode == KeyEvent.KEYCODE_ENTER
                    }
                }
                editTextRef = this
            }
        }
    )
}

/**
 * Quiet M3 Expressive syncing pill for round Wear OS displays.
 * Used inline beneath primary actions in lists or as a compact top overlay in active threads
 * so cached content remains immediately scrollable while syncing continues in the background.
 */
@Composable
fun WearSyncPill(
    visible: Boolean,
    modifier: Modifier = Modifier,
    label: String = "Syncing…",
    overlay: Boolean = false,
    debounceMs: Long = 300L
) {
    // Match Flutter's 300ms debounce so fast refreshes don't flash a pill over cached content.
    var debouncedVisible by remember { mutableStateOf(false) }
    LaunchedEffect(visible, debounceMs) {
        if (!visible) {
            debouncedVisible = false
        } else {
            if (debounceMs > 0L) delay(debounceMs)
            debouncedVisible = true
        }
    }

    val palette = LocalWearPalette.current
    val reducedMotion = rememberReducedMotion()
    val enter = when {
        reducedMotion -> EnterTransition.None
        overlay -> fadeIn(tween(180)) + slideInVertically(tween(180)) { -it / 3 }
        else -> fadeIn(tween(180)) + expandVertically(tween(180))
    }
    val exit = when {
        reducedMotion -> ExitTransition.None
        overlay -> fadeOut(tween(260)) + slideOutVertically(tween(260)) { -it / 3 }
        else -> fadeOut(tween(260)) + shrinkVertically(tween(260))
    }

    AnimatedVisibility(
        visible = debouncedVisible,
        enter = enter,
        exit = exit,
        modifier = modifier
    ) {
        val bgColor = if (overlay) {
            palette.surfaceContainerLow.copy(alpha = 0.94f)
        } else {
            palette.surfaceContainerLow
        }
        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(999.dp))
                .background(bgColor)
                .border(1.dp, palette.surfaceContainerHigh.copy(alpha = 0.72f), RoundedCornerShape(999.dp))
                .semantics(mergeDescendants = true) { contentDescription = label }
                .padding(horizontal = 11.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center
        ) {
            CircularProgressIndicator(
                modifier = Modifier.size(12.dp),
                strokeWidth = 1.75.dp,
                indicatorColor = palette.primary,
                trackColor = palette.primary.copy(alpha = 0.22f)
            )
            Spacer(modifier = Modifier.width(6.dp))
            Text(
                text = label,
                style = centeredTextStyle(
                    fontSize = 11.sp,
                    lineHeight = 14.sp,
                    fontWeight = FontWeight.Medium
                ),
                color = palette.onSurfaceVariant,
                maxLines = 1
            )
        }
    }
}

@Composable
fun rememberSpeechInputLauncher(
    prompt: String,
    onResult: (String) -> Unit,
    onUnavailable: () -> Unit
): () -> Unit {
    val currentOnUnavailable by rememberUpdatedState(onUnavailable)
    val launcher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK) {
            extractSpokenText(
                result.data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
            )?.let(onResult)
        }
    }
    return remember(prompt, launcher) {
        {
            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_PROMPT, prompt)
            }
            try {
                launcher.launch(intent)
            } catch (_: ActivityNotFoundException) {
                currentOnUnavailable()
            }
        }
    }
}
