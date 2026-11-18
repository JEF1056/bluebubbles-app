package com.wearbubbles.ui.messages

import android.Manifest
import android.app.RemoteInput
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.keyframes
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.automirrored.rounded.SendToMobile
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Group
import androidx.compose.material.icons.outlined.Keyboard
import androidx.compose.material.icons.outlined.Mic
import androidx.compose.material.icons.outlined.SentimentSatisfied
import androidx.compose.material.icons.rounded.BrokenImage
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Done
import androidx.compose.material.icons.rounded.DoneAll
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.Keyboard
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Stop
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.rotary.onRotaryScrollEvent
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.wear.compose.material.CircularProgressIndicator
import androidx.wear.compose.material.Icon
import androidx.wear.compose.material.ListHeader
import androidx.wear.compose.material.Text
import androidx.wear.compose.material.dialog.Alert
import androidx.wear.compose.material.dialog.Dialog
import androidx.wear.input.RemoteInputIntentHelper
import androidx.wear.input.wearableExtender
import coil.ImageLoader
import coil.compose.SubcomposeAsyncImage
import coil.decode.GifDecoder
import coil.decode.ImageDecoderDecoder
import coil.request.ImageRequest
import com.google.android.horologist.annotations.ExperimentalHorologistApi
import com.google.android.horologist.compose.layout.ScalingLazyColumn
import com.google.android.horologist.compose.layout.ScalingLazyColumnDefaults
import com.google.android.horologist.compose.layout.ScreenScaffold
import com.google.android.horologist.compose.layout.rememberResponsiveColumnState
import com.wearbubbles.api.dto.TapbackType
import com.wearbubbles.notifications.RemoteLauncher
import com.wearbubbles.ui.theme.ErrorColor
import com.wearbubbles.ui.theme.ErrorContainer
import com.wearbubbles.ui.theme.LocalWearPalette
import com.wearbubbles.ui.theme.OnErrorContainer
import com.wearbubbles.ui.theme.WearCircleIconButton
import com.wearbubbles.ui.theme.WearPillButton
import com.wearbubbles.ui.theme.centeredTextStyle
import java.io.File
import java.util.Locale

private val QUICK_EMOJIS = listOf(
    "👍", "❤️", "😂",
    "😊", "😮", "😢",
    "🙏", "🔥", "🎉",
    "👏", "👌", "😍",
    "😅", "🤔", "💯"
)

private val AUDIO_WAVEFORM_HEIGHTS = listOf(6.dp, 12.dp, 9.dp, 14.dp, 7.dp, 11.dp)

private data class ViewerImageSource(
    val localPath: String?,
    val remoteUrl: String?,
    val headers: Map<String, String>
)

@OptIn(ExperimentalHorologistApi::class)
@Composable
fun MessageDetailScreen(
    chatGuid: String,
    onChatDeleted: () -> Unit = {},
    viewModel: MessageDetailViewModel = viewModel()
) {
    val context = LocalContext.current
    val palette = LocalWearPalette.current
    val screenWidthDp = LocalConfiguration.current.screenWidthDp
    val maxBubbleWidth = remember(screenWidthDp) {
        (screenWidthDp * 0.78f).coerceIn(136f, 180f).dp
    }

    val columnState = rememberResponsiveColumnState(
        contentPadding = ScalingLazyColumnDefaults.padding(
            first = ScalingLazyColumnDefaults.ItemType.Text,
            last = ScalingLazyColumnDefaults.ItemType.MultiButton
        ),
        verticalArrangement = Arrangement.spacedBy(0.dp)
    )

    val chatTitle by viewModel.chatTitle.collectAsState()
    val participants by viewModel.participants.collectAsState()
    val messages by viewModel.messages.collectAsState()
    val isSending by viewModel.isSending.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val isLoadingMore by viewModel.isLoadingMore.collectAsState()
    val isTyping by viewModel.isTyping.collectAsState()
    val isRecordingVoiceMemo by viewModel.isRecording.collectAsState()
    val recordingSeconds by viewModel.recordingSeconds.collectAsState()
    val error by viewModel.error.collectAsState()
    val sendFailedCount = remember(messages) { messages.count { it.sendFailed } }
    val playingMessageGuid by viewModel.playingMessageGuid.collectAsState()

    val grouping = remember(messages) {
        computeBubbleGrouping(
            items = messages.map { it.toBubbleGroupKey() },
            hasSenderLabel = { idx -> !messages[idx].senderName.isNullOrBlank() }
        )
    }

    val imageLoader = remember(context) {
        ImageLoader.Builder(context)
            .components {
                add(ImageDecoderDecoder.Factory())
                add(GifDecoder.Factory())
            }
            .build()
    }
    DisposableEffect(imageLoader) {
        onDispose { imageLoader.shutdown() }
    }

    var reactionTargetMsg by remember { mutableStateOf<MessageUi?>(null) }
    var showEmojiPicker by remember { mutableStateOf(false) }
    var showPeopleDialog by remember { mutableStateOf(false) }
    var showTrashConfirm by remember { mutableStateOf(false) }
    var fullscreenImage by remember { mutableStateOf<ViewerImageSource?>(null) }
    var lastScrolledGuid by remember(chatGuid) { mutableStateOf<String?>(null) }

    LaunchedEffect(chatGuid) {
        viewModel.init(chatGuid)
    }

    // Only auto-scroll when the thread first populates or a new message arrives at the bottom;
    // prepending older history via loadMore() must not yank the user away from what they are reading.
    // Centering the latest message keeps multi-line messages readable while leaving the reply cluster
    // peeking immediately below on round watch faces.
    val latestGuid = messages.lastOrNull()?.guid
    LaunchedEffect(latestGuid) {
        if (latestGuid != null && latestGuid != lastScrolledGuid) {
            val headerItems = 1 // chat_header
            val targetIndex = (headerItems + messages.size - 1).coerceAtLeast(0)
            if (lastScrolledGuid == null) {
                columnState.state.scrollToItem(targetIndex)
            } else {
                columnState.state.animateScrollToItem(targetIndex)
            }
            lastScrolledGuid = latestGuid
        }
    }

    // Automatically load older history when the user scrolls back up near the top of the thread,
    // or once for very short locally-cached threads (<= 4 messages).
    LaunchedEffect(chatGuid) {
        var armed = false
        var attemptedShortLoad = false
        snapshotFlow {
            val firstVisible = columnState.state.layoutInfo.visibleItemsInfo.firstOrNull()?.index ?: Int.MAX_VALUE
            Triple(firstVisible, lastScrolledGuid != null, messages.size)
        }.collect { (firstVisible, scrolledInitially, count) ->
            if (!scrolledInitially || count == 0) return@collect
            if (firstVisible > 3) {
                armed = true
            } else if (firstVisible <= 2 && !isLoading && !isLoadingMore) {
                if (armed || (!attemptedShortLoad && count <= 4)) {
                    armed = false
                    if (count <= 4) attemptedShortLoad = true
                    viewModel.loadMore()
                }
            }
        }
    }

    val replyLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        val data = result.data ?: return@rememberLauncherForActivityResult
        val results: Bundle? = RemoteInput.getResultsFromIntent(data)
        val text = results?.getCharSequence("reply_text")?.toString()
        if (!text.isNullOrBlank()) {
            viewModel.sendMessage(text)
        }
    }

    val launchKeyboardReply = {
        val remoteInput = RemoteInput.Builder("reply_text")
            .setLabel("Reply")
            .wearableExtender { setEmojisAllowed(true) }
            .build()
        val intent = RemoteInputIntentHelper.createActionRemoteInputIntent().also {
            RemoteInputIntentHelper.putRemoteInputsExtra(it, listOf(remoteInput))
        }
        replyLauncher.launch(intent)
    }

    val micPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { isGranted ->
        if (isGranted) {
            viewModel.startRecording()
        }
    }

    if (fullscreenImage != null) {
        FullscreenImageViewer(
            source = fullscreenImage!!,
            imageLoader = imageLoader,
            onDismiss = { fullscreenImage = null }
        )
        return
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
            item(key = "chat_header") {
                ListHeader(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(bottom = 4.dp)
                ) {
                    Text(
                        text = chatTitle,
                        style = centeredTextStyle(15.sp, 19.sp, FontWeight.Medium),
                        color = palette.onSurface,
                        textAlign = TextAlign.Center,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            }

            if (isLoading && messages.isEmpty()) {
                item(key = "loading_spinner") {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 24.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(24.dp),
                            strokeWidth = 2.dp,
                            indicatorColor = palette.primary
                        )
                    }
                }
            }

            items(messages.size, key = { messages[it].guid }) { index ->
                val msg = messages[index]
                val meta = grouping[index]
                val prevHadReactions = index > 0 && messages[index - 1].reactions.isNotEmpty()
                MessageBubble(
                    message = msg,
                    meta = meta,
                    prevHadReactions = prevHadReactions,
                    maxBubbleWidth = maxBubbleWidth,
                    imageLoader = imageLoader,
                    isPlayingAudio = playingMessageGuid == msg.guid,
                    onLongPress = { reactionTargetMsg = msg },
                    onImageClick = {
                        fullscreenImage = ViewerImageSource(
                            localPath = msg.localAttachmentPath,
                            remoteUrl = msg.attachmentUrl,
                            headers = msg.customHeaders
                        )
                    },
                    onPlayAudioClick = { viewModel.toggleAudioPlayback(msg) }
                )
            }

            if (isTyping) {
                item(key = "typing_indicator") {
                    TypingIndicatorBubble()
                }
            }

            if (sendFailedCount > 0) {
                item(key = "send_failed_banner") {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 8.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Row(
                            modifier = Modifier
                                .clip(RoundedCornerShape(50))
                                .background(ErrorContainer)
                                .padding(horizontal = 12.dp, vertical = 6.dp),
                            horizontalArrangement = Arrangement.spacedBy(5.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.ErrorOutline,
                                contentDescription = null,
                                tint = OnErrorContainer,
                                modifier = Modifier.size(14.dp)
                            )
                            Text(
                                text = "$sendFailedCount not sent",
                                style = centeredTextStyle(11.sp, 14.sp, FontWeight.Medium),
                                color = OnErrorContainer,
                                textAlign = TextAlign.Center
                            )
                        }
                    }
                }
            }

            if (error != null) {
                item(key = "error_banner") {
                    WearPillButton(
                        label = error!!,
                        secondaryLabel = "Tap to dismiss",
                        onClick = { viewModel.clearError() },
                        leadingIcon = {
                            Icon(
                                imageVector = Icons.Rounded.ErrorOutline,
                                contentDescription = null,
                                tint = OnErrorContainer,
                                modifier = Modifier.size(16.dp)
                            )
                        },
                        backgroundColor = ErrorContainer,
                        contentColor = OnErrorContainer,
                        minHeight = 44.dp,
                        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
                        modifier = Modifier.padding(top = 8.dp)
                    )
                }
            }

            item(key = "bottom_action_bar") {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 14.dp),
                    contentAlignment = Alignment.Center
                ) {
                    if (isRecordingVoiceMemo) {
                        VoiceRecordingBar(
                            seconds = recordingSeconds,
                            onCancel = { viewModel.cancelRecording() },
                            onSend = { viewModel.stopAndSendRecording() }
                        )
                    } else {
                        ReplyActionCluster(
                            isSending = isSending,
                            onVoiceClick = {
                                val granted = ContextCompat.checkSelfPermission(
                                    context,
                                    Manifest.permission.RECORD_AUDIO
                                ) == PackageManager.PERMISSION_GRANTED
                                if (granted) {
                                    viewModel.startRecording()
                                } else {
                                    micPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                                }
                            },
                            onEmojiClick = { showEmojiPicker = true },
                            onKeyboardClick = launchKeyboardReply
                        )
                    }
                }
            }

            item(key = "more_badge") {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 14.dp, bottom = 6.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(50))
                            .background(palette.surfaceContainer)
                            .padding(horizontal = 14.dp, vertical = 5.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = "More",
                            style = centeredTextStyle(12.sp, 15.sp, FontWeight.Medium),
                            color = palette.onSurfaceVariant,
                            textAlign = TextAlign.Center
                        )
                    }
                }
            }

            item(key = "action_view_people") {
                WearPillButton(
                    label = "View people",
                    onClick = { showPeopleDialog = true },
                    leadingIcon = {
                        Icon(
                            imageVector = Icons.Outlined.Group,
                            contentDescription = null,
                            tint = palette.primary,
                            modifier = Modifier.size(22.dp)
                        )
                    },
                    backgroundColor = palette.surfaceContainer,
                    contentColor = palette.onSurface,
                    minHeight = 54.dp,
                    contentPadding = PaddingValues(horizontal = 18.dp, vertical = 12.dp)
                )
            }

            item(key = "action_move_to_trash") {
                WearPillButton(
                    label = "Move to trash",
                    onClick = { showTrashConfirm = true },
                    leadingIcon = {
                        Icon(
                            imageVector = Icons.Outlined.Delete,
                            contentDescription = null,
                            tint = palette.primary,
                            modifier = Modifier.size(22.dp)
                        )
                    },
                    backgroundColor = palette.surfaceContainer,
                    contentColor = palette.onSurface,
                    minHeight = 54.dp,
                    contentPadding = PaddingValues(horizontal = 18.dp, vertical = 12.dp),
                    modifier = Modifier.padding(top = 6.dp)
                )
            }

            item(key = "action_open_on_phone") {
                WearPillButton(
                    label = "Open on phone",
                    onClick = { RemoteLauncher.openServerOnPhone(context) },
                    leadingIcon = {
                        Icon(
                            imageVector = Icons.AutoMirrored.Rounded.SendToMobile,
                            contentDescription = null,
                            tint = palette.primary,
                            modifier = Modifier.size(22.dp)
                        )
                    },
                    backgroundColor = palette.surfaceContainer,
                    contentColor = palette.onSurface,
                    minHeight = 54.dp,
                    contentPadding = PaddingValues(horizontal = 18.dp, vertical = 12.dp),
                    modifier = Modifier.padding(top = 6.dp)
                )
            }
        }
    }

    Dialog(
        showDialog = reactionTargetMsg != null,
        onDismissRequest = { reactionTargetMsg = null }
    ) {
        val target = reactionTargetMsg
        if (target != null) {
            TapbackPickerOverlay(
                activeByMeTypes = target.reactions.filter { it.isFromMe }.map { it.type }.toSet(),
                onSelect = { tapback ->
                    val activeByMe = target.reactions.any { it.type == tapback && it.isFromMe }
                    viewModel.toggleTapback(target.guid, tapback, activeByMe)
                    reactionTargetMsg = null
                },
                onDismiss = { reactionTargetMsg = null }
            )
        }
    }

    Dialog(
        showDialog = showEmojiPicker,
        onDismissRequest = { showEmojiPicker = false }
    ) {
        EmojiPickerOverlay(
            onSelectEmoji = { emoji ->
                viewModel.sendMessage(emoji)
                showEmojiPicker = false
            },
            onOpenKeyboard = {
                showEmojiPicker = false
                launchKeyboardReply()
            },
            onDismiss = { showEmojiPicker = false }
        )
    }

    Dialog(
        showDialog = showPeopleDialog,
        onDismissRequest = { showPeopleDialog = false }
    ) {
        Alert(
            title = {
                Text(
                    text = "People",
                    style = centeredTextStyle(15.sp, 19.sp, FontWeight.SemiBold),
                    color = palette.onSurface,
                    textAlign = TextAlign.Center
                )
            },
            content = {
                item {
                    Column(
                        modifier = Modifier.fillMaxWidth(),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        participants.forEach { (name, address) ->
                            Text(
                                text = if (name != address) "$name ($address)" else name,
                                style = centeredTextStyle(12.sp, 15.sp),
                                color = palette.onSurfaceVariant,
                                textAlign = TextAlign.Center,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    }
                }
                item {
                    Spacer(modifier = Modifier.height(6.dp))
                    WearPillButton(
                        label = "Close",
                        onClick = { showPeopleDialog = false },
                        backgroundColor = palette.surfaceContainerHigh,
                        contentColor = palette.onSurface,
                        centered = true,
                        minHeight = 42.dp
                    )
                }
            }
        )
    }

    Dialog(
        showDialog = showTrashConfirm,
        onDismissRequest = { showTrashConfirm = false }
    ) {
        Alert(
            title = {
                Text(
                    text = "Move to trash?",
                    style = centeredTextStyle(15.sp, 19.sp, FontWeight.SemiBold),
                    color = palette.onSurface,
                    textAlign = TextAlign.Center
                )
            },
            content = {
                Text(
                    text = "Remove this conversation from your watch.",
                    style = centeredTextStyle(12.sp, 16.sp),
                    color = palette.onSurfaceVariant,
                    textAlign = TextAlign.Center
                )
            },
            negativeButton = {
                WearPillButton(
                    label = "Cancel",
                    onClick = { showTrashConfirm = false },
                    backgroundColor = palette.surfaceContainerHigh,
                    contentColor = palette.onSurface,
                    centered = true,
                    minHeight = 44.dp
                )
            },
            positiveButton = {
                WearPillButton(
                    label = "Trash",
                    onClick = {
                        showTrashConfirm = false
                        viewModel.deleteChat(onChatDeleted)
                    },
                    backgroundColor = ErrorContainer,
                    contentColor = OnErrorContainer,
                    centered = true,
                    minHeight = 44.dp
                )
            }
        )
    }
}

@Composable
private fun ReplyActionCluster(
    isSending: Boolean,
    onVoiceClick: () -> Unit,
    onEmojiClick: () -> Unit,
    onKeyboardClick: () -> Unit
) {
    val palette = LocalWearPalette.current
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(palette.surfaceContainerLow)
            .padding(horizontal = 6.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        WearCircleIconButton(
            icon = Icons.Outlined.SentimentSatisfied,
            contentDescription = "Emoji reply",
            onClick = onEmojiClick,
            enabled = !isSending,
            backgroundColor = palette.surfaceContainerHigh,
            contentColor = palette.onSurface,
            size = 50.dp,
            iconSize = 24.dp
        )

        WearCircleIconButton(
            icon = Icons.Outlined.Mic,
            contentDescription = "Voice message",
            onClick = onVoiceClick,
            enabled = !isSending,
            backgroundColor = palette.surfaceContainerHigh,
            contentColor = palette.onSurface,
            size = 50.dp,
            iconSize = 24.dp
        )

        if (isSending) {
            Box(
                modifier = Modifier
                    .size(50.dp)
                    .clip(CircleShape)
                    .background(palette.surfaceContainerHigh),
                contentAlignment = Alignment.Center
            ) {
                CircularProgressIndicator(
                    modifier = Modifier.size(22.dp),
                    strokeWidth = 2.dp,
                    indicatorColor = palette.primary
                )
            }
        } else {
            WearCircleIconButton(
                icon = Icons.Outlined.Keyboard,
                contentDescription = "Keyboard reply",
                onClick = onKeyboardClick,
                backgroundColor = palette.surfaceContainerHigh,
                contentColor = palette.onSurface,
                size = 50.dp,
                iconSize = 24.dp
            )
        }
    }
}

@Composable
private fun VoiceRecordingBar(
    seconds: Int,
    onCancel: () -> Unit,
    onSend: () -> Unit
) {
    val palette = LocalWearPalette.current
    val mins = seconds / 60
    val secs = seconds % 60
    val durationText = String.format(Locale.US, "%d:%02d", mins, secs)

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically
    ) {
        WearCircleIconButton(
            icon = Icons.Rounded.Close,
            contentDescription = "Cancel recording",
            onClick = onCancel,
            backgroundColor = palette.surfaceContainerHigh,
            contentColor = palette.onSurface
        )
        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(50))
                .background(ErrorContainer.copy(alpha = 0.7f))
                .padding(horizontal = 10.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(5.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(7.dp)
                    .clip(CircleShape)
                    .background(ErrorColor)
            )
            Text(
                text = durationText,
                style = centeredTextStyle(12.sp, 14.sp, FontWeight.SemiBold),
                color = OnErrorContainer,
                textAlign = TextAlign.Center
            )
        }
        WearCircleIconButton(
            icon = Icons.AutoMirrored.Rounded.Send,
            contentDescription = "Send voice message",
            onClick = onSend,
            backgroundColor = palette.primaryAction,
            contentColor = palette.onPrimaryAction
        )
    }
}

@Composable
private fun TypingIndicatorBubble() {
    val palette = LocalWearPalette.current
    val transition = rememberInfiniteTransition(label = "typing")
    val alphas = listOf(0, 180, 360).map { delayMs ->
        transition.animateFloat(
            initialValue = 0.35f,
            targetValue = 1f,
            animationSpec = infiniteRepeatable(
                animation = keyframes {
                    durationMillis = 900
                    0.35f at delayMs
                    1.0f at (delayMs + 220).coerceAtMost(900)
                    0.35f at (delayMs + 440).coerceAtMost(900)
                },
                repeatMode = RepeatMode.Restart
            ),
            label = "dot_$delayMs"
        )
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 8.dp)
            .semantics { contentDescription = "Typing" },
        contentAlignment = Alignment.CenterStart
    ) {
        Row(
            modifier = Modifier
                .clip(RoundedCornerShape(BUBBLE_OUTER_RADIUS_DP.dp))
                .background(palette.receivedBubble)
                .padding(horizontal = 12.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            alphas.forEach { dotAlpha ->
                Box(
                    modifier = Modifier
                        .size(6.dp)
                        .alpha(dotAlpha.value)
                        .clip(CircleShape)
                        .background(palette.onSurfaceVariant)
                )
            }
        }
    }
}

@OptIn(ExperimentalHorologistApi::class)
@Composable
private fun EmojiPickerOverlay(
    onSelectEmoji: (String) -> Unit,
    onOpenKeyboard: () -> Unit,
    onDismiss: () -> Unit
) {
    val palette = LocalWearPalette.current
    val columnState = rememberResponsiveColumnState(
        contentPadding = ScalingLazyColumnDefaults.padding(
            first = ScalingLazyColumnDefaults.ItemType.Text,
            last = ScalingLazyColumnDefaults.ItemType.Chip
        ),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    )
    val rows = remember { QUICK_EMOJIS.chunked(3) }

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
            item(key = "emoji_header") {
                ListHeader(modifier = Modifier.fillMaxWidth()) {
                    Text(
                        text = "Emoji",
                        style = centeredTextStyle(14.sp, 18.sp, FontWeight.SemiBold),
                        color = palette.onSurface,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth()
                    )
                }
            }

            items(rows.size, key = { "emoji_row_$it" }) { rowIndex ->
                val rowEmojis = rows[rowIndex]
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    rowEmojis.forEach { emoji ->
                        Box(
                            modifier = Modifier
                                .size(48.dp)
                                .clip(CircleShape)
                                .background(palette.surfaceContainerHigh)
                                .clickable(role = Role.Button, onClick = { onSelectEmoji(emoji) }),
                            contentAlignment = Alignment.Center
                        ) {
                            Text(
                                text = emoji,
                                style = centeredTextStyle(21.sp, 22.sp),
                                textAlign = TextAlign.Center
                            )
                        }
                    }
                }
            }

            item(key = "emoji_more") {
                WearPillButton(
                    label = "More",
                    onClick = onOpenKeyboard,
                    leadingIcon = {
                        Icon(
                            imageVector = Icons.Rounded.Keyboard,
                            contentDescription = null,
                            tint = palette.onPrimaryAction,
                            modifier = Modifier.size(16.dp)
                        )
                    },
                    backgroundColor = palette.primaryAction,
                    contentColor = palette.onPrimaryAction,
                    centered = true,
                    minHeight = 46.dp,
                    modifier = Modifier.padding(top = 4.dp)
                )
            }

            item(key = "emoji_cancel") {
                WearPillButton(
                    label = "Cancel",
                    onClick = onDismiss,
                    backgroundColor = palette.surfaceContainer,
                    contentColor = palette.onSurface,
                    centered = true,
                    minHeight = 46.dp
                )
            }
        }
    }
}

@Composable
private fun TapbackPickerOverlay(
    activeByMeTypes: Set<TapbackType>,
    onSelect: (TapbackType) -> Unit,
    onDismiss: () -> Unit
) {
    val palette = LocalWearPalette.current
    val tapbacks = TapbackType.entries
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(palette.canvas)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text(
            text = "React",
            style = centeredTextStyle(13.sp, 16.sp, FontWeight.SemiBold),
            color = palette.onSurface,
            textAlign = TextAlign.Center
        )
        Spacer(modifier = Modifier.height(6.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            tapbacks.take(3).forEach { type ->
                TapbackPill(
                    type = type,
                    selected = type in activeByMeTypes,
                    onClick = { onSelect(type) }
                )
            }
        }
        Spacer(modifier = Modifier.height(6.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            tapbacks.drop(3).forEach { type ->
                TapbackPill(
                    type = type,
                    selected = type in activeByMeTypes,
                    onClick = { onSelect(type) }
                )
            }
        }
        Spacer(modifier = Modifier.height(8.dp))
        WearPillButton(
            label = "Cancel",
            onClick = onDismiss,
            backgroundColor = palette.surfaceContainerHigh,
            contentColor = palette.onSurface,
            centered = true,
            minHeight = 38.dp,
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 6.dp),
            modifier = Modifier.widthIn(min = 96.dp, max = 116.dp)
        )
    }
}

@Composable
private fun TapbackPill(
    type: TapbackType,
    selected: Boolean,
    onClick: () -> Unit
) {
    val palette = LocalWearPalette.current
    Box(
        modifier = Modifier
            .size(44.dp)
            .clip(CircleShape)
            .background(if (selected) palette.primaryAction else palette.surfaceContainerHigh)
            .then(
                if (selected) Modifier.border(1.5.dp, palette.primary, CircleShape)
                else Modifier
            )
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = type.emoji,
            style = centeredTextStyle(19.sp, 21.sp),
            textAlign = TextAlign.Center
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun MessageBubble(
    message: MessageUi,
    meta: GroupedMessageMeta,
    prevHadReactions: Boolean,
    maxBubbleWidth: Dp,
    imageLoader: ImageLoader,
    isPlayingAudio: Boolean,
    onLongPress: () -> Unit,
    onImageClick: () -> Unit,
    onPlayAudioClick: () -> Unit
) {
    val context = LocalContext.current
    val palette = LocalWearPalette.current
    val alignment = if (message.isFromMe) Alignment.CenterEnd else Alignment.CenterStart
    val bubbleShape = remember(meta.corners) { meta.corners.toShape() }

    val bubbleColor = when {
        message.sendFailed -> ErrorContainer
        message.isFromMe -> palette.sentBubble
        else -> palette.receivedBubble
    }
    val textColor = when {
        message.sendFailed -> OnErrorContainer
        message.isFromMe -> palette.onSentBubble
        else -> palette.onReceivedBubble
    }
    val isImageAttachment = message.attachmentMimeType?.startsWith("image/") == true
    val isAudioAttachment = message.attachmentMimeType?.startsWith("audio/") == true
    val imageModelData: Any? = remember(message.localAttachmentPath, message.attachmentUrl) {
        message.localAttachmentPath?.let { File(it) }?.takeIf { it.exists() } ?: message.attachmentUrl
    }

    val topGap = when {
        meta.showTimestampHeader -> 4.dp
        prevHadReactions -> 6.dp
        meta.connectUpper -> 4.dp
        else -> 8.dp
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = topGap),
        horizontalAlignment = if (message.isFromMe) Alignment.End else Alignment.Start
    ) {
        if (meta.showTimestampHeader) {
            val timestampLabel = remember(message.dateCreated) {
                formatMessageTimestampHeader(message.dateCreated)
            }
            if (timestampLabel.isNotBlank()) {
                Text(
                    text = timestampLabel,
                    style = centeredTextStyle(12.5.sp, 16.sp, FontWeight.Medium),
                    color = palette.onSurface.copy(alpha = 0.88f),
                    textAlign = TextAlign.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 6.dp, bottom = 8.dp)
                )
            }
        }

        if (meta.showSenderName && !message.senderName.isNullOrBlank()) {
            Text(
                text = message.senderName,
                style = centeredTextStyle(10.5.sp, 13.sp, FontWeight.Medium),
                color = palette.subtleText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(start = 10.dp, bottom = 3.dp)
            )
        }

        Box(
            modifier = Modifier.fillMaxWidth(),
            contentAlignment = alignment
        ) {
            Column(
                horizontalAlignment = if (message.isFromMe) Alignment.End else Alignment.Start
            ) {
                if (isImageAttachment && imageModelData != null) {
                    val reqBuilder = ImageRequest.Builder(context)
                        .data(imageModelData)
                        .size(250, 250)
                        .crossfade(true)
                    if (imageModelData is String) {
                        message.customHeaders.forEach { (k, v) -> reqBuilder.addHeader(k, v) }
                    }
                    SubcomposeAsyncImage(
                        model = reqBuilder.build(),
                        imageLoader = imageLoader,
                        contentDescription = "Image attachment",
                        contentScale = ContentScale.Crop,
                        loading = {
                            Box(
                                modifier = Modifier
                                    .size(116.dp)
                                    .clip(bubbleShape)
                                    .background(palette.surfaceContainer),
                                contentAlignment = Alignment.Center
                            ) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(20.dp),
                                    strokeWidth = 2.dp,
                                    indicatorColor = palette.primary
                                )
                            }
                        },
                        error = {
                            Row(
                                modifier = Modifier
                                    .clip(bubbleShape)
                                    .background(bubbleColor)
                                    .padding(horizontal = 12.dp, vertical = 9.dp),
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Icon(
                                    imageVector = Icons.Rounded.BrokenImage,
                                    contentDescription = null,
                                    tint = textColor,
                                    modifier = Modifier.size(16.dp)
                                )
                                Text(
                                    text = "Photo",
                                    style = centeredTextStyle(12.sp, 15.sp),
                                    color = textColor
                                )
                            }
                        },
                        modifier = Modifier
                            .size(124.dp)
                            .clip(bubbleShape)
                            .combinedClickable(
                                onClick = onImageClick,
                                onLongClick = onLongPress
                            )
                    )
                }

                if (isAudioAttachment) {
                    if (isImageAttachment && imageModelData != null) {
                        Spacer(modifier = Modifier.height(3.dp))
                    }
                    Row(
                        modifier = Modifier
                            .widthIn(min = 122.dp, max = maxBubbleWidth)
                            .clip(bubbleShape)
                            .background(bubbleColor)
                            .combinedClickable(
                                role = Role.Button,
                                onClick = onPlayAudioClick,
                                onLongClick = onLongPress
                            )
                            .padding(horizontal = 10.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Box(
                            modifier = Modifier
                                .size(26.dp)
                                .clip(CircleShape)
                                .background(textColor.copy(alpha = 0.16f)),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                imageVector = if (isPlayingAudio) Icons.Rounded.Stop else Icons.Rounded.PlayArrow,
                                contentDescription = if (isPlayingAudio) "Stop audio" else "Play audio",
                                tint = textColor,
                                modifier = Modifier.size(16.dp)
                            )
                        }
                        Spacer(modifier = Modifier.width(8.dp))
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(2.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            AUDIO_WAVEFORM_HEIGHTS.forEach { barHeight ->
                                Box(
                                    modifier = Modifier
                                        .width(2.dp)
                                        .height(barHeight)
                                        .clip(RoundedCornerShape(1.dp))
                                        .background(textColor.copy(alpha = if (isPlayingAudio) 0.95f else 0.55f))
                                )
                            }
                        }
                        Spacer(modifier = Modifier.width(7.dp))
                        Text(
                            text = if (isPlayingAudio) "Playing" else "Voice",
                            style = centeredTextStyle(11.5.sp, 14.sp, FontWeight.Medium),
                            color = textColor,
                            maxLines = 1
                        )
                    }
                }

                val displayText = message.text?.takeIf { it.isNotBlank() }
                    ?: if (!isImageAttachment && !isAudioAttachment && message.attachmentGuid != null) {
                        "Attachment"
                    } else null

                if (displayText != null) {
                    if ((isImageAttachment && imageModelData != null) || isAudioAttachment) {
                        Spacer(modifier = Modifier.height(3.dp))
                    }
                    Box(
                        modifier = Modifier
                            .widthIn(min = 36.dp, max = maxBubbleWidth)
                            .clip(bubbleShape)
                            .background(bubbleColor)
                            .combinedClickable(
                                onClick = {},
                                onLongClick = onLongPress
                            )
                            .padding(horizontal = 16.dp, vertical = 10.dp),
                        contentAlignment = Alignment.CenterStart
                    ) {
                        Text(
                            text = displayText,
                            style = centeredTextStyle(14.sp, 18.sp),
                            color = textColor
                        )
                    }
                }

                if (message.reactions.isNotEmpty()) {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.padding(top = 3.dp, start = 4.dp, end = 4.dp)
                    ) {
                        message.reactions.forEach { badge ->
                            Row(
                                modifier = Modifier
                                    .clip(RoundedCornerShape(50))
                                    .background(if (badge.isFromMe) palette.primaryContainer else palette.surfaceContainerHigh)
                                    .border(1.dp, palette.canvas, RoundedCornerShape(50))
                                    .padding(horizontal = 7.dp, vertical = 3.dp),
                                horizontalArrangement = Arrangement.spacedBy(2.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(
                                    text = badge.type.emoji,
                                    style = centeredTextStyle(11.sp, 13.sp),
                                    textAlign = TextAlign.Center
                                )
                                if (badge.count > 1) {
                                    Text(
                                        text = badge.count.toString(),
                                        style = centeredTextStyle(10.sp, 12.sp, FontWeight.SemiBold),
                                        color = if (badge.isFromMe) palette.onPrimaryContainer else palette.onSurface,
                                        textAlign = TextAlign.Center
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }

        if (message.isLatestOutgoing) {
            val timeStr = remember(message.dateCreated) {
                formatReceiptTime(message.dateCreated)
            }
            Row(
                modifier = Modifier.padding(end = 6.dp, top = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                when {
                    message.sendFailed -> {
                        Icon(
                            imageVector = Icons.Rounded.ErrorOutline,
                            contentDescription = null,
                            tint = ErrorColor,
                            modifier = Modifier.size(12.dp)
                        )
                        Text(
                            text = "Not sent",
                            style = centeredTextStyle(11.sp, 13.sp, FontWeight.Medium),
                            color = ErrorColor
                        )
                    }
                    message.guid.startsWith("temp-") -> {
                        Text(
                            text = "Sending...",
                            style = centeredTextStyle(11.sp, 13.sp, FontWeight.Medium),
                            color = palette.subtleText
                        )
                    }
                    message.dateRead > 0L -> {
                        if (timeStr.isNotBlank()) {
                            Text(
                                text = "$timeStr ·",
                                style = centeredTextStyle(11.sp, 13.sp, FontWeight.Medium),
                                color = palette.onSurface
                            )
                        }
                        Box(
                            modifier = Modifier
                                .size(15.dp)
                                .clip(CircleShape)
                                .background(palette.onSurface),
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.DoneAll,
                                contentDescription = "Read",
                                tint = palette.canvas,
                                modifier = Modifier.size(11.dp)
                            )
                        }
                    }
                    message.dateDelivered > 0L -> {
                        if (timeStr.isNotBlank()) {
                            Text(
                                text = "$timeStr ·",
                                style = centeredTextStyle(11.sp, 13.sp, FontWeight.Medium),
                                color = palette.subtleText
                            )
                        }
                        Icon(
                            imageVector = Icons.Rounded.Done,
                            contentDescription = "Delivered",
                            tint = palette.subtleText,
                            modifier = Modifier.size(13.dp)
                        )
                    }
                    timeStr.isNotBlank() -> {
                        Text(
                            text = timeStr,
                            style = centeredTextStyle(11.sp, 13.sp, FontWeight.Medium),
                            color = palette.subtleText
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun FullscreenImageViewer(
    source: ViewerImageSource,
    imageLoader: ImageLoader,
    onDismiss: () -> Unit
) {
    val context = LocalContext.current
    val focusRequester = remember { FocusRequester() }
    var scale by remember { mutableFloatStateOf(1f) }
    var offsetX by remember { mutableFloatStateOf(0f) }
    var offsetY by remember { mutableFloatStateOf(0f) }

    val modelData: Any? = remember(source.localPath, source.remoteUrl) {
        source.localPath?.let { File(it) }?.takeIf { it.exists() } ?: source.remoteUrl
    }
    val reqBuilder = ImageRequest.Builder(context)
        .data(modelData)
        .crossfade(true)
    if (modelData is String) {
        source.headers.forEach { (k, v) -> reqBuilder.addHeader(k, v) }
    }

    LaunchedEffect(Unit) {
        focusRequester.requestFocus()
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .focusRequester(focusRequester)
            .focusable()
            .onRotaryScrollEvent { event ->
                val delta = -event.verticalScrollPixels * 0.005f
                scale = (scale + delta).coerceIn(1f, 4f)
                if (scale <= 1.05f) {
                    offsetX = 0f
                    offsetY = 0f
                }
                true
            }
            .pointerInput(Unit) {
                detectTapGestures(
                    onDoubleTap = {
                        if (scale > 1.5f) {
                            scale = 1f
                            offsetX = 0f
                            offsetY = 0f
                        } else {
                            scale = 2.5f
                        }
                    },
                    onTap = { onDismiss() }
                )
            }
            .pointerInput(Unit) {
                detectDragGestures { change, dragAmount ->
                    if (scale > 1.05f) {
                        change.consume()
                        offsetX += dragAmount.x
                        offsetY += dragAmount.y
                    }
                }
            },
        contentAlignment = Alignment.Center
    ) {
        SubcomposeAsyncImage(
            model = reqBuilder.build(),
            imageLoader = imageLoader,
            contentDescription = "Fullscreen image",
            contentScale = ContentScale.Fit,
            loading = {
                CircularProgressIndicator(modifier = Modifier.size(28.dp), strokeWidth = 2.dp)
            },
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer(
                    scaleX = scale,
                    scaleY = scale,
                    translationX = offsetX,
                    translationY = offsetY
                )
        )
    }
}
