package com.wearbubbles.ui.theme

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Group
import androidx.compose.material.icons.rounded.Person
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.material.Icon
import androidx.wear.compose.material.Text
import coil.compose.AsyncImage
import coil.request.ImageRequest
import java.io.File

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
        avatarPath?.takeIf { it.isNotBlank() }?.let { File(it) }?.takeIf { it.exists() }
    }
    val swatch = remember(seed) { avatarSwatchFor(seed) }
    val monogram = remember(title) { avatarMonogram(title) }
    val iconSize = (size.value * 0.52f).dp
    val monogramFontSize = (size.value * 0.43f).sp

    Box(modifier = modifier.size(size), contentAlignment = Alignment.Center) {
        if (avatarFile != null) {
            AsyncImage(
                model = ImageRequest.Builder(context)
                    .data(avatarFile)
                    .crossfade(true)
                    .build(),
                contentDescription = title,
                contentScale = ContentScale.Crop,
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
                when {
                    isGroup -> Icon(
                        imageVector = Icons.Rounded.Group,
                        contentDescription = null,
                        tint = contentColor,
                        modifier = Modifier.size(iconSize)
                    )
                    monogram != null -> Text(
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
                    else -> Icon(
                        imageVector = Icons.Rounded.Person,
                        contentDescription = null,
                        tint = contentColor,
                        modifier = Modifier.size(iconSize)
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
            Text(
                text = label,
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
            if (!secondaryLabel.isNullOrBlank()) {
                Spacer(modifier = Modifier.height(2.dp))
                Text(
                    text = secondaryLabel,
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

/**
 * Circular M3 Expressive icon button meeting Wear OS 48dp minimum touch target.
 */
@Composable
fun WearCircleIconButton(
    icon: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
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
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
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
