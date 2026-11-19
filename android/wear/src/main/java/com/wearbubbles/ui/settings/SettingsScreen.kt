package com.wearbubbles.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CloudDone
import androidx.compose.material.icons.rounded.CloudOff
import androidx.compose.material.icons.rounded.LinkOff
import androidx.compose.material.icons.rounded.Smartphone
import androidx.compose.material.icons.rounded.Sync
import androidx.compose.material.icons.rounded.Vibration
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.wear.compose.material.CircularProgressIndicator
import androidx.wear.compose.material.Icon
import androidx.wear.compose.material.ListHeader
import androidx.wear.compose.material.Switch
import androidx.wear.compose.material.Text
import com.google.android.horologist.annotations.ExperimentalHorologistApi
import com.google.android.horologist.compose.layout.ScalingLazyColumn
import com.google.android.horologist.compose.layout.ScalingLazyColumnDefaults
import com.google.android.horologist.compose.layout.ScreenScaffold
import com.google.android.horologist.compose.layout.rememberResponsiveColumnState
import com.wearbubbles.BuildConfig
import com.wearbubbles.ui.components.WearConfirmModal
import com.wearbubbles.ui.theme.ErrorColor
import com.wearbubbles.ui.theme.LocalWearPalette
import com.wearbubbles.ui.theme.SuccessColor
import com.wearbubbles.ui.theme.WearPillButton
import com.wearbubbles.ui.theme.centeredTextStyle

@OptIn(ExperimentalHorologistApi::class)
@Composable
fun SettingsScreen(
    onResetComplete: () -> Unit,
    viewModel: SettingsViewModel = viewModel()
) {
    val palette = LocalWearPalette.current
    val state by viewModel.uiState.collectAsState()
    var showResetConfirm by remember { mutableStateOf(false) }

    LaunchedEffect(state.isResetDone) {
        if (state.isResetDone) {
            onResetComplete()
        }
    }

    val columnState = rememberResponsiveColumnState(
        contentPadding = ScalingLazyColumnDefaults.padding(
            first = ScalingLazyColumnDefaults.ItemType.Text,
            last = ScalingLazyColumnDefaults.ItemType.Text
        ),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    )

    val (modeLabel, modeColor, modeIcon) = when {
        state.isPhoneRelay -> Triple("Phone relay active", SuccessColor, Icons.Rounded.Smartphone)
        state.isSocketConnected -> Triple("Direct server", palette.primary, Icons.Rounded.CloudDone)
        else -> Triple("Disconnected", ErrorColor, Icons.Rounded.CloudOff)
    }

    ScreenScaffold(
        scrollState = columnState,
        modifier = Modifier
            .fillMaxSize()
            .background(palette.canvas)
    ) {
        ScalingLazyColumn(
            columnState = columnState,
            modifier = Modifier
                .fillMaxSize()
                .background(palette.canvas)
        ) {
            item(key = "header") {
                ListHeader(modifier = Modifier.fillMaxWidth()) {
                    Text(
                        text = "Settings",
                        style = centeredTextStyle(15.sp, 20.sp, FontWeight.SemiBold),
                        color = palette.onSurface,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            }

            item(key = "transport_status") {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .defaultMinSize(minHeight = 52.dp)
                        .clip(RoundedCornerShape(26.dp))
                        .background(palette.surfaceContainer)
                        .padding(horizontal = 14.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Box(
                        modifier = Modifier
                            .size(28.dp)
                            .clip(CircleShape)
                            .background(modeColor.copy(alpha = 0.16f)),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            imageVector = modeIcon,
                            contentDescription = null,
                            tint = modeColor,
                            modifier = Modifier.size(16.dp)
                        )
                    }
                    Spacer(modifier = Modifier.width(10.dp))
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically)
                    ) {
                        Text(
                            text = "Transport",
                            style = centeredTextStyle(13.sp, 16.sp, FontWeight.Medium),
                            color = palette.onSurface,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(5.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Box(
                                modifier = Modifier
                                    .size(6.dp)
                                    .clip(CircleShape)
                                    .background(modeColor)
                            )
                            Text(
                                text = modeLabel,
                                style = centeredTextStyle(11.sp, 14.sp, FontWeight.Medium),
                                color = modeColor,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    }
                }
            }

            item(key = "sync_phone") {
                val host = state.serverUrl
                    .removePrefix("https://")
                    .removePrefix("http://")
                    .takeIf { it.isNotBlank() }
                WearPillButton(
                    label = if (state.isSyncing) "Syncing..." else "Sync from phone",
                    secondaryLabel = host,
                    onClick = { viewModel.syncFromPhone() },
                    enabled = !state.isSyncing,
                    leadingIcon = {
                        if (state.isSyncing) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(18.dp),
                                strokeWidth = 2.dp,
                                indicatorColor = palette.primary
                            )
                        } else {
                            Icon(
                                imageVector = Icons.Rounded.Sync,
                                contentDescription = null,
                                tint = palette.primary,
                                modifier = Modifier.size(18.dp)
                            )
                        }
                    },
                    backgroundColor = palette.surfaceContainer,
                    contentColor = palette.onSurface,
                    secondaryContentColor = palette.subtleText,
                    minHeight = 52.dp
                )
            }

            item(key = "haptics") {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .defaultMinSize(minHeight = 52.dp)
                        .clip(RoundedCornerShape(50))
                        .background(palette.surfaceContainer)
                        .toggleable(
                            value = state.hapticEnabled,
                            role = Role.Switch,
                            onValueChange = { viewModel.toggleHaptic(it) }
                        )
                        .padding(horizontal = 14.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        imageVector = Icons.Rounded.Vibration,
                        contentDescription = null,
                        tint = palette.onSurface,
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(modifier = Modifier.width(10.dp))
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically)
                    ) {
                        Text(
                            text = "Haptics",
                            style = centeredTextStyle(13.sp, 16.sp, FontWeight.Medium),
                            color = palette.onSurface,
                            maxLines = 1
                        )
                        Text(
                            text = if (state.hapticEnabled) "On" else "Off",
                            style = centeredTextStyle(11.sp, 14.sp),
                            color = palette.subtleText,
                            maxLines = 1
                        )
                    }
                    Spacer(modifier = Modifier.width(8.dp))
                    Switch(checked = state.hapticEnabled)
                }
            }

            item(key = "reset") {
                WearPillButton(
                    label = "Reset & disconnect",
                    onClick = { showResetConfirm = true },
                    leadingIcon = {
                        Icon(
                            imageVector = Icons.Rounded.LinkOff,
                            contentDescription = null,
                            tint = ErrorColor,
                            modifier = Modifier.size(18.dp)
                        )
                    },
                    backgroundColor = palette.surfaceContainer,
                    contentColor = ErrorColor,
                    minHeight = 50.dp,
                    contentPadding = PaddingValues(horizontal = 14.dp, vertical = 10.dp)
                )
            }

            item(key = "version") {
                Text(
                    text = "BlueBubbles Wear v${BuildConfig.VERSION_NAME}",
                    style = centeredTextStyle(10.5.sp, 14.sp),
                    color = palette.subtleText,
                    textAlign = TextAlign.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 6.dp)
                )
            }
        }
    }

    WearConfirmModal(
        show = showResetConfirm,
        onDismiss = { showResetConfirm = false },
        title = "Reset watch?",
        message = "Clears saved server credentials and local messages.",
        confirmLabel = "Reset watch",
        onConfirm = {
            showResetConfirm = false
            viewModel.resetSetup()
        },
        dismissLabel = "Keep setup",
        icon = Icons.Rounded.LinkOff,
        destructive = true
    )
}
