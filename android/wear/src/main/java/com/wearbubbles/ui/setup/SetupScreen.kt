package com.wearbubbles.ui.setup

import android.app.RemoteInput
import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Chat
import androidx.compose.material.icons.rounded.Dns
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.Key
import androidx.compose.material.icons.rounded.Link
import androidx.compose.material.icons.rounded.Smartphone
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.wear.compose.material.CircularProgressIndicator
import androidx.wear.compose.material.Icon
import androidx.wear.compose.material.Text
import androidx.wear.input.RemoteInputIntentHelper
import androidx.wear.input.wearableExtender
import com.google.android.horologist.annotations.ExperimentalHorologistApi
import com.google.android.horologist.compose.layout.ScalingLazyColumn
import com.google.android.horologist.compose.layout.ScalingLazyColumnDefaults
import com.google.android.horologist.compose.layout.ScreenScaffold
import com.google.android.horologist.compose.layout.rememberResponsiveColumnState
import com.wearbubbles.ui.theme.ErrorContainer
import com.wearbubbles.ui.theme.LocalWearPalette
import com.wearbubbles.ui.theme.OnErrorContainer
import com.wearbubbles.ui.theme.SuccessColor
import com.wearbubbles.ui.theme.WearPillButton
import com.wearbubbles.ui.theme.centeredTextStyle

@OptIn(ExperimentalHorologistApi::class)
@Composable
fun SetupScreen(
    onConnected: () -> Unit,
    viewModel: SetupViewModel = viewModel()
) {
    val palette = LocalWearPalette.current
    val state by viewModel.uiState.collectAsState()

    LaunchedEffect(state.isSuccess) {
        if (state.isSuccess) {
            onConnected()
        }
    }

    val urlInputLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        val data = result.data ?: return@rememberLauncherForActivityResult
        val results = RemoteInput.getResultsFromIntent(data)
        val text = results?.getCharSequence("server_url")?.toString()
        if (!text.isNullOrBlank()) {
            viewModel.updateServerUrl(text)
        }
    }

    val passwordInputLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        val data = result.data ?: return@rememberLauncherForActivityResult
        val results = RemoteInput.getResultsFromIntent(data)
        val text = results?.getCharSequence("password")?.toString()
        if (!text.isNullOrBlank()) {
            viewModel.updatePassword(text)
        }
    }

    val columnState = rememberResponsiveColumnState(
        contentPadding = ScalingLazyColumnDefaults.padding(
            first = ScalingLazyColumnDefaults.ItemType.Icon,
            last = ScalingLazyColumnDefaults.ItemType.Chip
        ),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    )

    val hasManualCreds = state.serverUrl.isNotBlank() && state.password.isNotBlank()

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
            item(key = "brand_header") {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(bottom = 2.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .size(34.dp)
                            .clip(CircleShape)
                            .background(palette.primaryAction),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Rounded.Chat,
                            contentDescription = null,
                            tint = palette.onPrimaryAction,
                            modifier = Modifier.size(19.dp)
                        )
                    }
                    Text(
                        text = "BlueBubbles",
                        style = centeredTextStyle(15.sp, 20.sp, FontWeight.SemiBold),
                        color = palette.onSurface,
                        textAlign = TextAlign.Center
                    )
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(5.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        if (state.isPhoneConnected) {
                            Box(
                                modifier = Modifier
                                    .size(6.dp)
                                    .clip(CircleShape)
                                    .background(SuccessColor)
                            )
                        }
                        Text(
                            text = if (state.isPhoneConnected) {
                                "Phone paired"
                            } else {
                                "Sync or connect direct"
                            },
                            style = centeredTextStyle(11.sp, 14.sp),
                            color = if (state.isPhoneConnected) SuccessColor else palette.subtleText,
                            textAlign = TextAlign.Center
                        )
                    }
                }
            }

            item(key = "sync_phone") {
                WearPillButton(
                    label = if (state.isSyncingFromPhone) "Syncing..." else "Sync from phone",
                    onClick = { viewModel.syncFromPhone() },
                    enabled = !state.isSyncingFromPhone && !state.isTesting,
                    leadingIcon = {
                        if (state.isSyncingFromPhone) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(18.dp),
                                strokeWidth = 2.dp,
                                indicatorColor = if (state.isPhoneConnected) {
                                    palette.onPrimaryAction
                                } else {
                                    palette.primary
                                }
                            )
                        } else {
                            Icon(
                                imageVector = Icons.Rounded.Smartphone,
                                contentDescription = null,
                                tint = if (state.isPhoneConnected) {
                                    palette.onPrimaryAction
                                } else {
                                    palette.onSurface
                                },
                                modifier = Modifier.size(18.dp)
                            )
                        }
                    },
                    backgroundColor = if (state.isPhoneConnected) {
                        palette.primaryAction
                    } else {
                        palette.surfaceContainerHigh
                    },
                    contentColor = if (state.isPhoneConnected) {
                        palette.onPrimaryAction
                    } else {
                        palette.onSurface
                    },
                    centered = true,
                    minHeight = 50.dp
                )
            }

            item(key = "manual_label") {
                Text(
                    text = "Direct server",
                    style = centeredTextStyle(11.sp, 14.sp, FontWeight.Medium),
                    color = palette.subtleText,
                    textAlign = TextAlign.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 6.dp, bottom = 2.dp)
                )
            }

            item(key = "server_url") {
                val displayUrl = state.serverUrl
                    .removePrefix("https://")
                    .removePrefix("http://")
                WearPillButton(
                    label = if (state.serverUrl.isBlank()) "Server URL" else displayUrl,
                    secondaryLabel = if (state.serverUrl.isNotBlank()) "Tap to change" else null,
                    onClick = {
                        val intent = createRemoteInputIntent("server_url", "Server URL (https://...)")
                        urlInputLauncher.launch(intent)
                    },
                    leadingIcon = {
                        Icon(
                            imageVector = Icons.Rounded.Dns,
                            contentDescription = null,
                            tint = palette.onSurfaceVariant,
                            modifier = Modifier.size(18.dp)
                        )
                    },
                    backgroundColor = palette.surfaceContainer,
                    contentColor = palette.onSurface,
                    secondaryContentColor = palette.subtleText,
                    minHeight = 50.dp
                )
            }

            item(key = "password") {
                WearPillButton(
                    label = if (state.password.isBlank()) "Password" else "••••••••",
                    secondaryLabel = if (state.password.isNotBlank()) "Tap to change" else null,
                    onClick = {
                        val intent = createRemoteInputIntent("password", "Server Password")
                        passwordInputLauncher.launch(intent)
                    },
                    leadingIcon = {
                        Icon(
                            imageVector = Icons.Rounded.Key,
                            contentDescription = null,
                            tint = palette.onSurfaceVariant,
                            modifier = Modifier.size(18.dp)
                        )
                    },
                    backgroundColor = palette.surfaceContainer,
                    contentColor = palette.onSurface,
                    secondaryContentColor = palette.subtleText,
                    minHeight = 50.dp
                )
            }

            if (state.error != null) {
                item(key = "error") {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(20.dp))
                            .background(ErrorContainer)
                            .padding(horizontal = 12.dp, vertical = 8.dp),
                        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(
                            imageVector = Icons.Rounded.ErrorOutline,
                            contentDescription = null,
                            tint = OnErrorContainer,
                            modifier = Modifier.size(15.dp)
                        )
                        Text(
                            text = state.error!!,
                            style = centeredTextStyle(11.5.sp, 15.sp, FontWeight.Medium),
                            color = OnErrorContainer,
                            textAlign = TextAlign.Center
                        )
                    }
                }
            }

            item(key = "connect_direct") {
                WearPillButton(
                    label = if (state.isTesting) "Connecting..." else "Connect direct",
                    onClick = { viewModel.testAndConnect() },
                    enabled = !state.isTesting && !state.isSyncingFromPhone,
                    leadingIcon = {
                        if (state.isTesting) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(18.dp),
                                strokeWidth = 2.dp,
                                indicatorColor = if (hasManualCreds) palette.onPrimaryAction else palette.onPrimaryContainer
                            )
                        } else {
                            Icon(
                                imageVector = Icons.Rounded.Link,
                                contentDescription = null,
                                tint = if (hasManualCreds) palette.onPrimaryAction else palette.onPrimaryContainer,
                                modifier = Modifier.size(18.dp)
                            )
                        }
                    },
                    backgroundColor = if (hasManualCreds) palette.primaryAction else palette.primaryContainer,
                    contentColor = if (hasManualCreds) palette.onPrimaryAction else palette.onPrimaryContainer,
                    centered = true,
                    minHeight = 50.dp,
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 10.dp),
                    modifier = Modifier.padding(top = 4.dp)
                )
            }
        }
    }
}

private fun createRemoteInputIntent(key: String, label: String): Intent {
    val remoteInput = RemoteInput.Builder(key)
        .setLabel(label)
        .wearableExtender { setEmojisAllowed(false) }
        .build()

    return RemoteInputIntentHelper.createActionRemoteInputIntent().also {
        RemoteInputIntentHelper.putRemoteInputsExtra(it, listOf(remoteInput))
    }
}
