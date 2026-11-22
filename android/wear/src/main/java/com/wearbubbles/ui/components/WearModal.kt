package com.wearbubbles.ui.components

import android.animation.ValueAnimator
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.foundation.lazy.ScalingLazyListScope
import androidx.wear.compose.material.Icon
import androidx.wear.compose.material.Text
import androidx.wear.compose.material.dialog.Dialog
import com.google.android.horologist.annotations.ExperimentalHorologistApi
import com.google.android.horologist.compose.layout.ScalingLazyColumn
import com.google.android.horologist.compose.layout.ScalingLazyColumnDefaults
import com.google.android.horologist.compose.layout.ScreenScaffold
import com.wearbubbles.ui.theme.WearRotaryFocusScope
import com.google.android.horologist.compose.layout.rememberResponsiveColumnState
import com.wearbubbles.ui.theme.BlurFadeContent
import com.wearbubbles.ui.theme.WearPillButton
import com.wearbubbles.ui.theme.centeredTextStyle

val WearModalCanvas = Color(0xFF000000)
val WearModalSurface = Color(0xFF16181D)
val WearModalBorder = Color(0xFF282C36)
val WearModalPrimaryBlue = Color(0xFF147EFB)
val WearModalOnPrimary = Color(0xFFFFFFFF)
val WearModalDestructiveRed = Color(0xFFEA4335)
val WearModalOnDestructive = Color(0xFFFFFFFF)
val WearModalTextPrimary = Color(0xFFF3F5F8)
val WearModalTextSecondary = Color(0xFFA0A7B4)

enum class WearModalActionStyle {
    Primary,
    Destructive,
    Secondary
}

@Composable
fun rememberReducedMotion(): Boolean {
    val lifecycleOwner = LocalLifecycleOwner.current
    var reduced by remember { mutableStateOf(!ValueAnimator.areAnimatorsEnabled()) }
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                reduced = !ValueAnimator.areAnimatorsEnabled()
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    return reduced
}

@OptIn(ExperimentalHorologistApi::class)
@Composable
fun WearModalScaffold(
    showDialog: Boolean,
    onDismissRequest: () -> Unit,
    firstItemType: ScalingLazyColumnDefaults.ItemType = ScalingLazyColumnDefaults.ItemType.Icon,
    lastItemType: ScalingLazyColumnDefaults.ItemType = ScalingLazyColumnDefaults.ItemType.Chip,
    verticalSpacing: Dp = 4.dp,
    content: ScalingLazyListScope.() -> Unit
) {
    Dialog(
        showDialog = showDialog,
        onDismissRequest = onDismissRequest
    ) {
        val reducedMotion = rememberReducedMotion()
        var visible by remember(showDialog, reducedMotion) { mutableStateOf(reducedMotion) }
        LaunchedEffect(showDialog, reducedMotion) {
            if (!reducedMotion) visible = showDialog
        }
        val alpha = animateFloatAsState(
            targetValue = if (visible) 1f else 0f,
            animationSpec = if (reducedMotion) snap() else tween(160, easing = FastOutSlowInEasing),
            label = "wear_modal_alpha"
        )
        val scale = animateFloatAsState(
            targetValue = if (visible) 1f else 0.95f,
            animationSpec = if (reducedMotion) snap() else tween(180, easing = FastOutSlowInEasing),
            label = "wear_modal_scale"
        )
        val columnState = rememberResponsiveColumnState(
            contentPadding = ScalingLazyColumnDefaults.padding(
                first = firstItemType,
                last = lastItemType
            ),
            verticalArrangement = Arrangement.spacedBy(verticalSpacing)
        )

        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(WearModalCanvas)
        ) {
            WearRotaryFocusScope {
                ScreenScaffold(
                    scrollState = columnState,
                    modifier = Modifier
                        .fillMaxSize()
                        .graphicsLayer {
                            this.alpha = alpha.value
                            scaleX = scale.value
                            scaleY = scale.value
                        }
                ) {
                    ScalingLazyColumn(
                        columnState = columnState,
                        modifier = Modifier.fillMaxSize(),
                        content = content
                    )
                }
            }
        }
    }
}

@Composable
fun WearModalIconBadge(
    icon: ImageVector,
    accentColor: Color,
    modifier: Modifier = Modifier
) {
    Box(
        modifier = modifier
            .size(34.dp)
            .clip(CircleShape)
            .background(accentColor.copy(alpha = 0.16f))
            .border(1.dp, accentColor.copy(alpha = 0.36f), CircleShape),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = accentColor,
            modifier = Modifier.size(18.dp)
        )
    }
}

@Composable
fun WearModalHeader(
    title: String,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    subtitleMaxLines: Int = 3,
    badge: @Composable () -> Unit
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 8.dp, vertical = 1.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        badge()
        Spacer(modifier = Modifier.height(5.dp))
        BlurFadeContent(
            targetState = title,
            contentAlignment = Alignment.Center
        ) { currentTitle ->
            Text(
                text = currentTitle,
                style = centeredTextStyle(15.sp, 18.sp, FontWeight.SemiBold),
                color = WearModalTextPrimary,
                textAlign = TextAlign.Center,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )
        }
        if (!subtitle.isNullOrBlank()) {
            Spacer(modifier = Modifier.height(2.dp))
            BlurFadeContent(
                targetState = subtitle,
                contentAlignment = Alignment.Center
            ) { currentSubtitle ->
                Text(
                    text = currentSubtitle,
                    style = centeredTextStyle(12.sp, 15.sp),
                    color = WearModalTextSecondary,
                    textAlign = TextAlign.Center,
                    maxLines = subtitleMaxLines,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }
    }
}

@Composable
fun WearModalActionPill(
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    style: WearModalActionStyle = WearModalActionStyle.Secondary
) {
    val bgColor = when (style) {
        WearModalActionStyle.Primary -> WearModalPrimaryBlue
        WearModalActionStyle.Destructive -> WearModalDestructiveRed
        WearModalActionStyle.Secondary -> WearModalSurface
    }
    val fgColor = when (style) {
        WearModalActionStyle.Primary -> WearModalOnPrimary
        WearModalActionStyle.Destructive -> WearModalOnDestructive
        WearModalActionStyle.Secondary -> WearModalTextPrimary
    }
    val borderModifier = if (style == WearModalActionStyle.Secondary) {
        Modifier.border(1.dp, WearModalBorder, RoundedCornerShape(50))
    } else {
        Modifier
    }

    WearPillButton(
        label = label,
        onClick = onClick,
        leadingIcon = if (icon != null) {
            {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = fgColor,
                    modifier = Modifier.size(18.dp)
                )
            }
        } else null,
        backgroundColor = bgColor,
        contentColor = fgColor,
        centered = true,
        minHeight = 48.dp,
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 10.dp),
        labelFontWeight = if (style == WearModalActionStyle.Secondary) FontWeight.Medium else FontWeight.SemiBold,
        modifier = modifier
            .padding(horizontal = 8.dp)
            .then(borderModifier)
    )
}

@Composable
fun WearConfirmModal(
    show: Boolean,
    onDismiss: () -> Unit,
    title: String,
    message: String,
    confirmLabel: String,
    onConfirm: () -> Unit,
    dismissLabel: String,
    icon: ImageVector,
    destructive: Boolean = true,
    headerBadge: (@Composable () -> Unit)? = null
) {
    val accent = if (destructive) WearModalDestructiveRed else WearModalPrimaryBlue
    WearModalScaffold(
        showDialog = show,
        onDismissRequest = onDismiss,
        firstItemType = ScalingLazyColumnDefaults.ItemType.Icon,
        lastItemType = ScalingLazyColumnDefaults.ItemType.Chip
    ) {
        item(key = "confirm_header") {
            WearModalHeader(
                title = title,
                subtitle = message,
                badge = headerBadge ?: {
                    WearModalIconBadge(icon = icon, accentColor = accent)
                }
            )
        }
        item(key = "confirm_primary") {
            WearModalActionPill(
                label = confirmLabel,
                icon = icon,
                style = if (destructive) WearModalActionStyle.Destructive else WearModalActionStyle.Primary,
                onClick = onConfirm
            )
        }
        item(key = "confirm_secondary") {
            WearModalActionPill(
                label = dismissLabel,
                style = WearModalActionStyle.Secondary,
                onClick = onDismiss
            )
        }
    }
}
