package com.wearbubbles.ui.conversations

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material.icons.rounded.ChatBubbleOutline
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.PushPin
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.SystemUpdate
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
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
import androidx.wear.compose.foundation.lazy.items
import androidx.wear.compose.material.CircularProgressIndicator
import androidx.wear.compose.material.Icon
import androidx.wear.compose.material.Text
import com.google.android.horologist.annotations.ExperimentalHorologistApi
import com.google.android.horologist.compose.layout.ScalingLazyColumn
import com.google.android.horologist.compose.layout.ScalingLazyColumnDefaults
import com.google.android.horologist.compose.layout.ScreenScaffold
import com.google.android.horologist.compose.layout.rememberResponsiveColumnState
import com.wearbubbles.ui.components.WearConfirmModal
import com.wearbubbles.ui.theme.ContactAvatar
import com.wearbubbles.ui.theme.ErrorContainer
import com.wearbubbles.ui.theme.LocalWearPalette
import com.wearbubbles.ui.theme.OnErrorContainer
import com.wearbubbles.ui.theme.WearPillButton
import com.wearbubbles.ui.theme.WearRotaryFocusScope
import com.wearbubbles.ui.theme.WearSyncPill
import com.wearbubbles.ui.theme.centeredTextStyle

@OptIn(ExperimentalHorologistApi::class, ExperimentalFoundationApi::class)
@Composable
fun ConversationListScreen(
    onChatClick: (String) -> Unit,
    onSettingsClick: () -> Unit,
    onNewMessageClick: () -> Unit,
    viewModel: ConversationListViewModel = viewModel()
) {
    val palette = LocalWearPalette.current
    val chats by viewModel.chats.collectAsStateWithLifecycle()
    val isRefreshing by viewModel.isRefreshing.collectAsStateWithLifecycle()
    val updateVersion by viewModel.updateVersion.collectAsStateWithLifecycle()
    val error by viewModel.error.collectAsStateWithLifecycle()
    var chatToDelete by remember { mutableStateOf<ChatItemUi?>(null) }

    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner, viewModel) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> viewModel.onScreenResumed()
                Lifecycle.Event.ON_PAUSE, Lifecycle.Event.ON_STOP -> viewModel.onScreenPaused()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    val columnState = rememberResponsiveColumnState(
        contentPadding = ScalingLazyColumnDefaults.padding(
            first = ScalingLazyColumnDefaults.ItemType.Chip,
            last = ScalingLazyColumnDefaults.ItemType.Chip
        ),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    )

    WearRotaryFocusScope {
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
            item(key = "start_chat") {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    WearPillButton(
                        label = "Start chat",
                        onClick = onNewMessageClick,
                        leadingIcon = {
                            Icon(
                                imageVector = Icons.Outlined.ChatBubbleOutline,
                                contentDescription = null,
                                tint = palette.onPrimary,
                                modifier = Modifier.size(20.dp)
                            )
                        },
                        backgroundColor = palette.primary,
                        contentColor = palette.onPrimary,
                        centered = false,
                        minHeight = 56.dp,
                        contentPadding = PaddingValues(horizontal = 22.dp, vertical = 14.dp),
                        labelFontWeight = FontWeight.Medium
                    )
                    WearSyncPill(
                        visible = isRefreshing && chats.isNotEmpty(),
                        modifier = Modifier.padding(top = 6.dp)
                    )
                }
            }

            if (updateVersion != null) {
                item(key = "update_banner") {
                    WearPillButton(
                        label = "Update v$updateVersion",
                        secondaryLabel = "Tap to dismiss",
                        onClick = { viewModel.dismissUpdate() },
                        leadingIcon = {
                            Icon(
                                imageVector = Icons.Rounded.SystemUpdate,
                                contentDescription = null,
                                tint = palette.onPrimaryContainer,
                                modifier = Modifier.size(18.dp)
                            )
                        },
                        backgroundColor = palette.primaryContainer,
                        contentColor = palette.onPrimaryContainer,
                        minHeight = 52.dp
                    )
                }
            }

            if (error != null && chats.isNotEmpty()) {
                item(key = "error_banner") {
                    WearPillButton(
                        label = error!!,
                        secondaryLabel = "Tap to retry",
                        onClick = { viewModel.refresh() },
                        leadingIcon = {
                            Icon(
                                imageVector = Icons.Rounded.ErrorOutline,
                                contentDescription = null,
                                tint = OnErrorContainer,
                                modifier = Modifier.size(18.dp)
                            )
                        },
                        backgroundColor = ErrorContainer,
                        contentColor = OnErrorContainer,
                        minHeight = 48.dp,
                        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp)
                    )
                }
            }

            if (chats.isEmpty()) {
                item(key = "empty_state") {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 14.dp, horizontal = 12.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center
                    ) {
                        if (isRefreshing) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(24.dp),
                                strokeWidth = 2.dp,
                                indicatorColor = palette.primary
                            )
                        } else {
                            Icon(
                                imageVector = if (error != null) Icons.Rounded.ErrorOutline else Icons.Rounded.ChatBubbleOutline,
                                contentDescription = null,
                                tint = if (error != null) OnErrorContainer else palette.subtleText,
                                modifier = Modifier.size(22.dp)
                            )
                        }
                        Spacer(modifier = Modifier.height(6.dp))
                        Text(
                            text = error ?: if (isRefreshing) "Loading chats..." else "No conversations yet",
                            style = centeredTextStyle(12.sp, 16.sp),
                            color = palette.onSurfaceVariant,
                            textAlign = TextAlign.Center
                        )
                    }
                }
            } else {
                items(items = chats, key = { it.guid }) { chat ->
                    ChatRow(
                        chat = chat,
                        onClick = { onChatClick(chat.guid) },
                        onLongClick = { chatToDelete = chat }
                    )
                }
            }

            item(key = "refresh_action") {
                WearPillButton(
                    label = if (isRefreshing) "Syncing..." else "Refresh",
                    onClick = { viewModel.refresh() },
                    enabled = !isRefreshing,
                    leadingIcon = {
                        if (isRefreshing) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(16.dp),
                                strokeWidth = 2.dp,
                                indicatorColor = palette.primary
                            )
                        } else {
                            Icon(
                                imageVector = Icons.Rounded.Refresh,
                                contentDescription = null,
                                tint = palette.primary,
                                modifier = Modifier.size(18.dp)
                            )
                        }
                    },
                    backgroundColor = palette.surfaceContainer,
                    contentColor = palette.onSurface,
                    centered = true,
                    minHeight = 48.dp,
                    modifier = Modifier.padding(top = 4.dp)
                )
            }

            item(key = "settings_action") {
                WearPillButton(
                    label = "Settings",
                    onClick = onSettingsClick,
                    leadingIcon = {
                        Icon(
                            imageVector = Icons.Rounded.Settings,
                            contentDescription = null,
                            tint = palette.onSurfaceVariant,
                            modifier = Modifier.size(18.dp)
                        )
                    },
                    backgroundColor = palette.surfaceContainer,
                    contentColor = palette.onSurface,
                    centered = true,
                    minHeight = 48.dp
                )
            }
        }
        }
    }

    val target = chatToDelete
    WearConfirmModal(
        show = target != null,
        onDismiss = { chatToDelete = null },
        title = "Hide chat?",
        message = target?.let { "Removes \"${it.title}\" from your watch." } ?: "",
        confirmLabel = "Hide chat",
        onConfirm = {
            if (target != null) {
                viewModel.deleteChat(target.guid)
            }
            chatToDelete = null
        },
        dismissLabel = "Keep chat",
        icon = Icons.Outlined.VisibilityOff,
        destructive = true,
        headerBadge = if (target != null) {
            {
                ContactAvatar(
                    title = target.title,
                    seed = target.guid,
                    avatarPath = target.avatarPath,
                    isGroup = target.isGroup,
                    size = 40.dp
                )
            }
        } else null
    )
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ChatRow(
    chat: ChatItemUi,
    onClick: () -> Unit,
    onLongClick: () -> Unit
) {
    val palette = LocalWearPalette.current

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .defaultMinSize(minHeight = 60.dp)
            .clip(RoundedCornerShape(26.dp))
            .background(palette.surfaceContainer)
            .combinedClickable(
                role = Role.Button,
                onClick = onClick,
                onLongClick = onLongClick
            )
            .padding(horizontal = 20.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.Center
        ) {
            Text(
                text = chat.title,
                style = centeredTextStyle(
                    fontSize = 15.sp,
                    lineHeight = 18.sp,
                    fontWeight = FontWeight.Bold
                ),
                color = palette.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
            if (chat.subtitle.isNotBlank()) {
                Spacer(modifier = Modifier.height(2.dp))
                Text(
                    text = chat.subtitle,
                    style = centeredTextStyle(
                        fontSize = 13.5.sp,
                        lineHeight = 17.sp,
                        fontWeight = if (chat.hasUnread) FontWeight.Medium else FontWeight.Normal
                    ),
                    color = if (chat.hasUnread) palette.onSurface else palette.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
            }
        }
        if (chat.isPinned) {
            Spacer(modifier = Modifier.width(8.dp))
            Icon(
                imageVector = Icons.Rounded.PushPin,
                contentDescription = "Pinned",
                tint = palette.onSurfaceVariant.copy(alpha = 0.8f),
                modifier = Modifier.size(14.dp)
            )
        }
    }
}
