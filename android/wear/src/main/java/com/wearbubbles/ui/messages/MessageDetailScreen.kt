package com.wearbubbles.ui.messages

import android.Manifest
import android.content.pm.PackageManager
import android.view.inputmethod.EditorInfo
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
import androidx.compose.foundation.layout.defaultMinSize
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
import androidx.compose.material.icons.outlined.AddReaction
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
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Stop
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
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
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.rotary.onRotaryScrollEvent
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import kotlinx.coroutines.delay
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.wear.compose.foundation.lazy.items
import androidx.wear.compose.foundation.lazy.itemsIndexed
import androidx.wear.compose.material.CircularProgressIndicator
import androidx.wear.compose.material.Icon
import androidx.wear.compose.material.ListHeader
import androidx.wear.compose.material.Text
import coil.Coil
import coil.ImageLoader
import coil.compose.SubcomposeAsyncImage
import coil.request.ImageRequest
import com.google.android.horologist.annotations.ExperimentalHorologistApi
import com.google.android.horologist.compose.layout.ScalingLazyColumn
import com.google.android.horologist.compose.layout.ScalingLazyColumnDefaults
import com.google.android.horologist.compose.layout.ScreenScaffold
import com.google.android.horologist.compose.layout.rememberResponsiveColumnState
import com.wearbubbles.api.dto.TapbackType
import com.wearbubbles.db.MessageDao
import com.wearbubbles.notifications.RemoteLauncher
import com.wearbubbles.ui.components.WearConfirmModal
import com.wearbubbles.ui.components.WearModalActionPill
import com.wearbubbles.ui.components.WearModalActionStyle
import com.wearbubbles.ui.components.WearModalBorder
import com.wearbubbles.ui.components.WearModalDestructiveRed
import com.wearbubbles.ui.components.WearModalHeader
import com.wearbubbles.ui.components.WearModalIconBadge
import com.wearbubbles.ui.components.WearModalPrimaryBlue
import com.wearbubbles.ui.components.WearModalScaffold
import com.wearbubbles.ui.components.WearModalSurface
import com.wearbubbles.ui.components.WearModalTextPrimary
import com.wearbubbles.ui.components.WearModalTextSecondary
import com.wearbubbles.ui.components.rememberReducedMotion
import com.wearbubbles.ui.theme.ContactAvatar
import com.wearbubbles.ui.theme.ErrorColor
import com.wearbubbles.ui.theme.ErrorContainer
import com.wearbubbles.ui.theme.LocalWearPalette
import com.wearbubbles.ui.theme.OnErrorContainer
import com.wearbubbles.ui.theme.WearCircleIconButton
import com.wearbubbles.ui.theme.WearDirectKeyboardInput
import com.wearbubbles.ui.theme.WearPillButton
import com.wearbubbles.ui.theme.WearRotaryFocusScope
import com.wearbubbles.ui.theme.WearSyncPill
import com.wearbubbles.ui.theme.centeredTextStyle
import com.wearbubbles.ui.theme.rememberSpeechInputLauncher
import java.io.File
import java.util.Locale

internal fun shouldAutoScrollOnMessageUpdate(
    previousLatestGuid: String?,
    newLatestGuid: String?,
    previousCount: Int,
    newCount: Int,
    newLatestIsFromMe: Boolean,
    isNearBottom: Boolean
): Boolean {
    if (newLatestGuid == null) return false
    if (previousLatestGuid == null) return true
    if (previousLatestGuid == newLatestGuid) return false
    // Reconciling an optimistic temp-* reply to its real server GUID keeps the same message at
    // the bottom; avoid yanking the user if they scrolled up while sending.
    if (
        MessageDao.isTempPlaceholderGuid(previousLatestGuid) &&
        !MessageDao.isTempPlaceholderGuid(newLatestGuid) &&
        newCount == previousCount &&
        newLatestIsFromMe
    ) {
        return false
    }
    return (newCount > previousCount && newLatestIsFromMe) || isNearBottom
}

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

    val layoutDirection = LocalLayoutDirection.current
    val baseColumnPadding = ScalingLazyColumnDefaults.padding(
        first = ScalingLazyColumnDefaults.ItemType.Text,
        last = ScalingLazyColumnDefaults.ItemType.MultiButton
    )
    val columnState = rememberResponsiveColumnState(
        contentPadding = {
            val base = baseColumnPadding()
            PaddingValues(
                start = base.calculateLeftPadding(layoutDirection),
                top = base.calculateTopPadding(),
                end = base.calculateRightPadding(layoutDirection),
                bottom = base.calculateBottomPadding() + 24.dp
            )
        },
        verticalArrangement = Arrangement.spacedBy(0.dp)
    )

    val chatTitle by viewModel.chatTitle.collectAsStateWithLifecycle()
    val participants by viewModel.participants.collectAsStateWithLifecycle()
    val messages by viewModel.messages.collectAsStateWithLifecycle()
    val isSending by viewModel.isSending.collectAsStateWithLifecycle()
    val isLoading by viewModel.isLoading.collectAsStateWithLifecycle()
    val isLoadingMore by viewModel.isLoadingMore.collectAsStateWithLifecycle()
    val isTyping by viewModel.isTyping.collectAsStateWithLifecycle()
    val isRecordingVoiceMemo by viewModel.isRecording.collectAsStateWithLifecycle()
    val recordingSeconds by viewModel.recordingSeconds.collectAsStateWithLifecycle()
    val error by viewModel.error.collectAsStateWithLifecycle()
    val sendFailedCount = remember(messages) { messages.count { it.sendFailed } }
    val playingMessageGuid by viewModel.playingMessageGuid.collectAsStateWithLifecycle()

    val messageRows = remember(messages) { buildMessageRows(messages) }

    val imageLoader = remember(context) { Coil.imageLoader(context) }

    var reactionTargetMsg by remember { mutableStateOf<MessageUi?>(null) }
    var failedActionMsg by remember { mutableStateOf<MessageUi?>(null) }
    var showClearFailedConfirm by remember { mutableStateOf(false) }
    var showEmojiPicker by remember { mutableStateOf(false) }
    var showPeopleDialog by remember { mutableStateOf(false) }
    var showTrashConfirm by remember { mutableStateOf(false) }
    var fullscreenImage by remember { mutableStateOf<ViewerImageSource?>(null) }
    val activeFailedMsg = failedActionMsg?.let { target ->
        messages.firstOrNull { it.guid == target.guid && it.sendFailed }
    }
    var lastScrolledGuid by remember(chatGuid) { mutableStateOf<String?>(null) }
    var lastScrolledCount by remember(chatGuid) { mutableIntStateOf(0) }

    LaunchedEffect(chatGuid) {
        viewModel.init(chatGuid)
    }

    val lifecycleOwner = LocalLifecycleOwner.current
    var nowMs by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var expandedMessageGuid by remember(chatGuid) { mutableStateOf<String?>(null) }
    var isResumed by remember(lifecycleOwner) {
        mutableStateOf(lifecycleOwner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
    }
    DisposableEffect(lifecycleOwner, chatGuid) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> {
                    isResumed = true
                    nowMs = System.currentTimeMillis()
                    viewModel.onScreenResumed()
                }
                Lifecycle.Event.ON_PAUSE, Lifecycle.Event.ON_STOP -> {
                    isResumed = false
                    viewModel.onScreenPaused()
                }
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    LaunchedEffect(isResumed, nowMs, messages, expandedMessageGuid) {
        if (!isResumed) return@LaunchedEffect
        val minDelayMs = nextDisplayedTimestampTickDelayMs(
            messages = messages,
            expandedMessageGuid = expandedMessageGuid,
            nowMs = nowMs
        ) ?: return@LaunchedEffect
        delay(minDelayMs)
        nowMs = System.currentTimeMillis()
    }

    // Only auto-scroll when the thread first populates or a new message arrives at the bottom;
    // prepending older history via loadMore() must not yank the user away from what they are reading.
    // Centering the latest message keeps multi-line messages readable while leaving the reply cluster
    // peeking immediately below on round watch faces.
    val latestGuid = messages.lastOrNull()?.guid
    val latestIsFromMe = messages.lastOrNull()?.isFromMe == true
    LaunchedEffect(latestGuid, messages.size) {
        if (latestGuid != null && (latestGuid != lastScrolledGuid || messages.size != lastScrolledCount)) {
            val headerItems = 1 // chat_header
            val targetIndex = (headerItems + messages.size - 1).coerceAtLeast(0)
            if (lastScrolledGuid == null) {
                columnState.state.scrollToItem(targetIndex)
            } else {
                val lastVisible = columnState.state.layoutInfo.visibleItemsInfo.maxOfOrNull { it.index }
                    ?: Int.MAX_VALUE
                val prevLastMsgIndex = headerItems + lastScrolledCount - 1
                val isNearBottom = lastVisible >= (prevLastMsgIndex - 2)
                if (
                    shouldAutoScrollOnMessageUpdate(
                        previousLatestGuid = lastScrolledGuid,
                        newLatestGuid = latestGuid,
                        previousCount = lastScrolledCount,
                        newCount = messages.size,
                        newLatestIsFromMe = latestIsFromMe,
                        isNearBottom = isNearBottom
                    )
                ) {
                    columnState.state.animateScrollToItem(targetIndex)
                }
            }
            lastScrolledGuid = latestGuid
            lastScrolledCount = messages.size
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

    var keyboardRequestToken by remember { mutableIntStateOf(0) }

    val launchKeyboardReply = {
        keyboardRequestToken = if (keyboardRequestToken <= 0) 1 else keyboardRequestToken + 1
    }

    val launchSpeechReply = rememberSpeechInputLauncher(
        prompt = "Message",
        onResult = { viewModel.sendMessage(it) },
        onUnavailable = launchKeyboardReply
    )

    val micPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { isGranted ->
        if (isGranted) {
            viewModel.startRecording()
        }
    }

    val startVoiceMemo = {
        val granted = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            viewModel.startRecording()
        } else {
            micPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
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

    LaunchedEffect(columnState.state) {
        snapshotFlow { columnState.state.isScrollInProgress }
            .collect { scrolling ->
                if (scrolling) {
                    viewModel.onUserInteraction()
                }
            }
    }

    WearRotaryFocusScope(active = keyboardRequestToken <= 0) {
        ScreenScaffold(
            scrollState = columnState,
            modifier = Modifier
                .fillMaxSize()
                .background(palette.canvas)
                .pointerInput(Unit) {
                    awaitPointerEventScope {
                        while (true) {
                            awaitPointerEvent(PointerEventPass.Initial)
                            viewModel.onUserInteraction()
                        }
                    }
                }
        ) {
            Box(modifier = Modifier.fillMaxSize()) {
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

            items(items = messageRows, key = { it.message.guid }) { row ->
                val msg = row.message
                MessageBubble(
                    message = msg,
                    meta = row.meta,
                    prevHadReactions = row.prevHadReactions,
                    maxBubbleWidth = maxBubbleWidth,
                    imageLoader = imageLoader,
                    isPlayingAudio = playingMessageGuid == msg.guid,
                    nowMs = nowMs,
                    isDetailExpanded = expandedMessageGuid == msg.guid,
                    onToggleDetailExpand = {
                        expandedMessageGuid = if (expandedMessageGuid == msg.guid) null else msg.guid
                    },
                    onLongPress = {
                        when {
                            msg.sendFailed -> failedActionMsg = msg
                            !MessageDao.isTempPlaceholderGuid(msg.guid) -> reactionTargetMsg = msg
                        }
                    },
                    onFailedClick = { failedActionMsg = msg },
                    onImageClick = {
                        if (msg.localAttachmentPath == null && msg.attachmentUrl == null) {
                            viewModel.retryAttachment(msg.attachmentGuid)
                        } else {
                            fullscreenImage = ViewerImageSource(
                                localPath = msg.localAttachmentPath,
                                remoteUrl = msg.attachmentUrl,
                                headers = msg.customHeaders
                            )
                        }
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
                    ErrorBannerPill(
                        label = "$sendFailedCount not sent",
                        secondaryLabel = if (sendFailedCount == 1) "Tap for options" else "Tap to clear all",
                        onClick = {
                            if (sendFailedCount == 1) {
                                failedActionMsg = messages.lastOrNull { it.sendFailed }
                            } else {
                                showClearFailedConfirm = true
                            }
                        }
                    )
                }
            }

            if (error != null) {
                item(key = "error_banner") {
                    ErrorBannerPill(
                        label = error!!,
                        secondaryLabel = "Tap to dismiss",
                        onClick = { viewModel.clearError() }
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
                            onMicClick = launchSpeechReply,
                            onMicLongClick = startVoiceMemo,
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

            item(key = "action_voice_message") {
                MoreActionPill(
                    label = "Voice message",
                    icon = Icons.Outlined.Mic,
                    onClick = startVoiceMemo
                )
            }

            item(key = "action_view_people") {
                MoreActionPill(
                    label = "View people",
                    icon = Icons.Outlined.Group,
                    onClick = { showPeopleDialog = true },
                    modifier = Modifier.padding(top = 6.dp)
                )
            }

            item(key = "action_move_to_trash") {
                MoreActionPill(
                    label = "Move to trash",
                    icon = Icons.Outlined.Delete,
                    onClick = { showTrashConfirm = true },
                    modifier = Modifier.padding(top = 6.dp)
                )
            }

            item(key = "action_open_on_phone") {
                MoreActionPill(
                    label = "Open on phone",
                    icon = Icons.AutoMirrored.Rounded.SendToMobile,
                    onClick = { RemoteLauncher.openChatOnPhoneAsync(context, chatGuid) },
                    modifier = Modifier.padding(top = 6.dp)
                )
            }
        }

            WearSyncPill(
                visible = isLoading && messages.isNotEmpty(),
                overlay = true,
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(top = 22.dp)
            )
        }
        }
    }

    TapbackPickerOverlay(
        showDialog = reactionTargetMsg != null,
        targetSnippet = reactionTargetMsg?.text?.trim()?.takeIf { it.isNotBlank() },
        activeByMeTypes = reactionTargetMsg?.reactions
            ?.filter { it.isFromMe }
            ?.map { it.type }
            ?.toSet()
            ?: emptySet(),
        onSelect = { tapback ->
            val target = reactionTargetMsg
            if (target != null) {
                val activeByMe = target.reactions.any { it.type == tapback && it.isFromMe }
                viewModel.toggleTapback(target.guid, tapback, activeByMe)
            }
            reactionTargetMsg = null
        },
        onDismiss = { reactionTargetMsg = null }
    )

    EmojiPickerOverlay(
        showDialog = showEmojiPicker,
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

    WearDirectKeyboardInput(
        requestToken = keyboardRequestToken,
        hint = "Reply",
        imeAction = EditorInfo.IME_ACTION_SEND,
        onSubmit = { text -> viewModel.sendMessage(text) },
        onDismiss = { keyboardRequestToken = 0 }
    )

    PeopleModal(
        showDialog = showPeopleDialog,
        participants = participants,
        onDismiss = { showPeopleDialog = false }
    )

    WearConfirmModal(
        show = showTrashConfirm,
        onDismiss = { showTrashConfirm = false },
        title = "Move to trash?",
        message = "Removes \"$chatTitle\" from this watch.",
        confirmLabel = "Trash chat",
        onConfirm = {
            showTrashConfirm = false
            viewModel.deleteChat(onChatDeleted)
        },
        dismissLabel = "Keep chat",
        icon = Icons.Outlined.Delete,
        destructive = true
    )

    FailedMessageActionsModal(
        showDialog = activeFailedMsg != null,
        messageSnippet = activeFailedMsg?.let { msg ->
            msg.text?.trim()?.takeIf { it.isNotBlank() }
                ?: if (msg.attachmentMimeType?.startsWith("audio/") == true) "Voice message" else null
        },
        canRetry = !activeFailedMsg?.text.isNullOrBlank(),
        onRetry = {
            val target = activeFailedMsg
            failedActionMsg = null
            if (target != null) {
                viewModel.retryFailedMessage(target)
            }
        },
        onDelete = {
            val target = activeFailedMsg
            failedActionMsg = null
            if (target != null) {
                viewModel.deleteFailedMessage(target.guid)
            }
        },
        onDismiss = { failedActionMsg = null }
    )

    WearConfirmModal(
        show = showClearFailedConfirm && sendFailedCount > 0,
        onDismiss = { showClearFailedConfirm = false },
        title = "Delete failed?",
        message = "Removes $sendFailedCount unsent messages from this watch.",
        confirmLabel = "Delete all",
        onConfirm = {
            showClearFailedConfirm = false
            viewModel.deleteAllFailedMessages()
        },
        dismissLabel = "Keep",
        icon = Icons.Outlined.Delete,
        destructive = true
    )
}

@Composable
internal fun FailedMessageActionsModal(
    showDialog: Boolean,
    messageSnippet: String?,
    canRetry: Boolean,
    onRetry: () -> Unit,
    onDelete: () -> Unit,
    onDismiss: () -> Unit
) {
    WearModalScaffold(
        showDialog = showDialog,
        onDismissRequest = onDismiss
    ) {
        item(key = "failed_header") {
            WearModalHeader(
                title = "Message not sent",
                subtitle = messageSnippet,
                subtitleMaxLines = 2,
                badge = {
                    WearModalIconBadge(
                        icon = Icons.Rounded.ErrorOutline,
                        accentColor = WearModalDestructiveRed
                    )
                }
            )
        }
        if (canRetry) {
            item(key = "failed_retry") {
                WearModalActionPill(
                    label = "Try again",
                    icon = Icons.Rounded.Refresh,
                    style = WearModalActionStyle.Primary,
                    onClick = onRetry
                )
            }
        }
        item(key = "failed_delete") {
            WearModalActionPill(
                label = "Delete message",
                icon = Icons.Outlined.Delete,
                style = WearModalActionStyle.Destructive,
                onClick = onDelete
            )
        }
        item(key = "failed_cancel") {
            WearModalActionPill(
                label = "Cancel",
                style = WearModalActionStyle.Secondary,
                onClick = onDismiss
            )
        }
    }
}

@Composable
private fun ErrorBannerPill(
    label: String,
    secondaryLabel: String,
    onClick: () -> Unit
) {
    WearPillButton(
        label = label,
        secondaryLabel = secondaryLabel,
        onClick = onClick,
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

@Composable
private fun MoreActionPill(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val palette = LocalWearPalette.current
    WearPillButton(
        label = label,
        onClick = onClick,
        leadingIcon = {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = palette.primary,
                modifier = Modifier.size(22.dp)
            )
        },
        backgroundColor = palette.surfaceContainer,
        contentColor = palette.onSurface,
        minHeight = 54.dp,
        contentPadding = PaddingValues(horizontal = 18.dp, vertical = 12.dp),
        modifier = modifier
    )
}

@Composable
private fun ReplyActionCluster(
    isSending: Boolean,
    onMicClick: () -> Unit,
    onMicLongClick: () -> Unit,
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
            contentDescription = "Voice reply",
            onClick = onMicClick,
            onLongClick = onMicLongClick,
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
    val reducedMotion = rememberReducedMotion()
    val lifecycleOwner = LocalLifecycleOwner.current
    val lifecycleState by lifecycleOwner.lifecycle.currentStateFlow.collectAsStateWithLifecycle()
    val animateTyping = !reducedMotion && lifecycleState.isAtLeast(Lifecycle.State.RESUMED)
    val alphas = if (!animateTyping) {
        listOf(0.7f, 0.7f, 0.7f)
    } else {
        val transition = rememberInfiniteTransition(label = "typing")
        listOf(0, 180, 360).map { delayMs ->
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
            ).value
        }
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
                        .alpha(dotAlpha)
                        .clip(CircleShape)
                        .background(palette.onSurfaceVariant)
                )
            }
        }
    }
}

@Composable
internal fun PeopleModal(
    showDialog: Boolean,
    participants: List<Pair<String, String>>,
    onDismiss: () -> Unit
) {
    WearModalScaffold(
        showDialog = showDialog,
        onDismissRequest = onDismiss,
        firstItemType = ScalingLazyColumnDefaults.ItemType.Icon,
        lastItemType = ScalingLazyColumnDefaults.ItemType.Chip
    ) {
        item(key = "people_header") {
            val countText = if (participants.isEmpty()) {
                "No members synced"
            } else {
                "${participants.size} ${if (participants.size == 1) "member" else "members"}"
            }
            WearModalHeader(
                title = "Chat people",
                subtitle = countText
            ) {
                WearModalIconBadge(
                    icon = Icons.Outlined.Group,
                    accentColor = WearModalPrimaryBlue
                )
            }
        }

        itemsIndexed(items = participants, key = { index, _ -> "participant_$index" }) { _, (name, address) ->
            val showAddress = address.isNotBlank() && address != name
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 8.dp)
                    .defaultMinSize(minHeight = 48.dp)
                    .clip(RoundedCornerShape(24.dp))
                    .background(WearModalSurface)
                    .border(1.dp, WearModalBorder, RoundedCornerShape(24.dp))
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                ContactAvatar(
                    title = name,
                    seed = address.ifBlank { name },
                    size = 32.dp,
                    badgeCutoutColor = WearModalSurface
                )
                Spacer(modifier = Modifier.width(10.dp))
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(1.dp, Alignment.CenterVertically)
                ) {
                    Text(
                        text = name,
                        style = centeredTextStyle(13.5.sp, 17.sp, FontWeight.Medium),
                        color = WearModalTextPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    if (showAddress) {
                        Text(
                            text = address,
                            style = centeredTextStyle(11.sp, 14.sp),
                            color = WearModalTextSecondary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                }
            }
        }

        item(key = "people_close") {
            WearModalActionPill(
                label = "Close people",
                style = WearModalActionStyle.Secondary,
                onClick = onDismiss,
                modifier = Modifier.padding(top = 4.dp)
            )
        }
    }
}

@Composable
internal fun EmojiPickerOverlay(
    showDialog: Boolean,
    onSelectEmoji: (String) -> Unit,
    onOpenKeyboard: () -> Unit,
    onDismiss: () -> Unit
) {
    val rows = remember { QUICK_EMOJIS.chunked(3) }

    WearModalScaffold(
        showDialog = showDialog,
        onDismissRequest = onDismiss,
        firstItemType = ScalingLazyColumnDefaults.ItemType.Icon,
        lastItemType = ScalingLazyColumnDefaults.ItemType.Chip
    ) {
        item(key = "emoji_header") {
            WearModalHeader(title = "Send emoji") {
                WearModalIconBadge(
                    icon = Icons.Outlined.SentimentSatisfied,
                    accentColor = WearModalPrimaryBlue
                )
            }
        }

        itemsIndexed(items = rows, key = { rowIndex, _ -> "emoji_row_$rowIndex" }) { _, rowEmojis ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
                verticalAlignment = Alignment.CenterVertically
            ) {
                rowEmojis.forEach { emoji ->
                    Box(
                        modifier = Modifier
                            .size(48.dp)
                            .clip(CircleShape)
                            .background(WearModalSurface)
                            .border(1.dp, WearModalBorder, CircleShape)
                            .semantics { contentDescription = "Send $emoji" }
                            .clickable(role = Role.Button, onClick = { onSelectEmoji(emoji) }),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = emoji,
                            style = centeredTextStyle(22.sp, 24.sp),
                            textAlign = TextAlign.Center
                        )
                    }
                }
            }
        }

        item(key = "emoji_keyboard") {
            WearModalActionPill(
                label = "Open keyboard",
                icon = Icons.Rounded.Keyboard,
                style = WearModalActionStyle.Primary,
                onClick = onOpenKeyboard,
                modifier = Modifier.padding(top = 4.dp)
            )
        }

        item(key = "emoji_close") {
            WearModalActionPill(
                label = "Close picker",
                style = WearModalActionStyle.Secondary,
                onClick = onDismiss
            )
        }
    }
}

@Composable
internal fun TapbackPickerOverlay(
    showDialog: Boolean,
    targetSnippet: String?,
    activeByMeTypes: Set<TapbackType>,
    onSelect: (TapbackType) -> Unit,
    onDismiss: () -> Unit
) {
    val tapbacks = TapbackType.pickerEntries

    WearModalScaffold(
        showDialog = showDialog,
        onDismissRequest = onDismiss,
        firstItemType = ScalingLazyColumnDefaults.ItemType.Icon,
        lastItemType = ScalingLazyColumnDefaults.ItemType.Chip
    ) {
        item(key = "tapback_header") {
            WearModalHeader(
                title = "React to message",
                subtitle = targetSnippet,
                subtitleMaxLines = 1
            ) {
                WearModalIconBadge(
                    icon = Icons.Outlined.AddReaction,
                    accentColor = WearModalPrimaryBlue
                )
            }
        }

        item(key = "tapback_row_1") {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
                verticalAlignment = Alignment.CenterVertically
            ) {
                tapbacks.take(3).forEach { type ->
                    TapbackPill(
                        type = type,
                        isSelected = type in activeByMeTypes,
                        onClick = { onSelect(type) }
                    )
                }
            }
        }

        item(key = "tapback_row_2") {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
                verticalAlignment = Alignment.CenterVertically
            ) {
                tapbacks.drop(3).forEach { type ->
                    TapbackPill(
                        type = type,
                        isSelected = type in activeByMeTypes,
                        onClick = { onSelect(type) }
                    )
                }
            }
        }

        item(key = "tapback_close") {
            WearModalActionPill(
                label = "Close reactions",
                style = WearModalActionStyle.Secondary,
                onClick = onDismiss
            )
        }
    }
}

@Composable
private fun TapbackPill(
    type: TapbackType,
    isSelected: Boolean,
    onClick: () -> Unit
) {
    val bgColor = if (isSelected) WearModalPrimaryBlue else WearModalSurface
    val borderColor = if (isSelected) Color(0xFF72B5FF) else WearModalBorder
    val borderWidth = if (isSelected) 1.5.dp else 1.dp

    Box(
        modifier = Modifier
            .size(48.dp)
            .clip(CircleShape)
            .background(bgColor)
            .border(borderWidth, borderColor, CircleShape)
            .semantics {
                contentDescription = "${type.label} reaction"
                selected = isSelected
            }
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = type.emoji,
            style = centeredTextStyle(20.sp, 22.sp),
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
    nowMs: Long,
    isDetailExpanded: Boolean,
    onToggleDetailExpand: () -> Unit,
    onLongPress: () -> Unit,
    onFailedClick: () -> Unit,
    onImageClick: () -> Unit,
    onPlayAudioClick: () -> Unit
) {
    val context = LocalContext.current
    val palette = LocalWearPalette.current
    val alignment = if (message.isFromMe) Alignment.CenterEnd else Alignment.CenterStart
    val bubbleShape = remember(meta.corners) { meta.corners.toShape() }
    val detailStatus = remember(
        message.isFromMe,
        message.sendFailed,
        message.guid,
        message.dateCreated,
        message.dateDelivered,
        message.dateRead,
        message.isLatestOutgoing,
        message.isLastReadOutgoing,
        message.isLatestIncoming,
        nowMs
    ) {
        resolveMessageDetailStatus(
            isFromMe = message.isFromMe,
            sendFailed = message.sendFailed,
            isPending = MessageDao.isTempPlaceholderGuid(message.guid),
            dateCreated = message.dateCreated,
            dateDelivered = message.dateDelivered,
            dateRead = message.dateRead,
            isLatestOutgoing = message.isLatestOutgoing,
            isLastReadOutgoing = message.isLastReadOutgoing,
            isLatestIncoming = message.isLatestIncoming,
            nowMs = nowMs
        )
    }

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
        message.localAttachmentPath?.let(::File) ?: message.attachmentUrl
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
                val hasImagePreview = isImageAttachment && (imageModelData != null || !message.attachmentGuid.isNullOrBlank())
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
                                onClick = if (message.sendFailed) onFailedClick else onImageClick,
                                onLongClick = onLongPress
                            )
                    )
                } else if (hasImagePreview) {
                    if (message.isAttachmentLoading) {
                        Box(
                            modifier = Modifier
                                .size(116.dp)
                                .clip(bubbleShape)
                                .background(palette.surfaceContainer)
                                .combinedClickable(
                                    onClick = { if (message.sendFailed) onFailedClick() },
                                    onLongClick = onLongPress
                                ),
                            contentAlignment = Alignment.Center
                        ) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(20.dp),
                                strokeWidth = 2.dp,
                                indicatorColor = palette.primary
                            )
                        }
                    } else {
                        val chipLabel = when {
                            message.isAttachmentFetchFailed -> "Retry photo"
                            !message.isPhoneConnected -> "Offline"
                            else -> "Tap to load"
                        }
                        Row(
                            modifier = Modifier
                                .clip(bubbleShape)
                                .background(palette.surfaceContainer)
                                .combinedClickable(
                                    role = Role.Button,
                                    onClick = if (message.sendFailed) onFailedClick else onImageClick,
                                    onLongClick = onLongPress
                                )
                                .padding(horizontal = 12.dp, vertical = 9.dp),
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Refresh,
                                contentDescription = chipLabel,
                                tint = palette.primary,
                                modifier = Modifier.size(16.dp)
                            )
                            Text(
                                text = chipLabel,
                                style = centeredTextStyle(12.sp, 15.sp),
                                color = palette.onSurface
                            )
                        }
                    }
                }

                if (isAudioAttachment) {
                    if (hasImagePreview) {
                        Spacer(modifier = Modifier.height(3.dp))
                    }
                    Row(
                        modifier = Modifier
                            .widthIn(min = 122.dp, max = maxBubbleWidth)
                            .clip(bubbleShape)
                            .background(bubbleColor)
                            .combinedClickable(
                                role = Role.Button,
                                onClick = if (message.sendFailed) onFailedClick else onPlayAudioClick,
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
                    if (hasImagePreview || isAudioAttachment) {
                        Spacer(modifier = Modifier.height(3.dp))
                    }
                    Box(
                        modifier = Modifier
                            .widthIn(min = 36.dp, max = maxBubbleWidth)
                            .clip(bubbleShape)
                            .background(bubbleColor)
                            .combinedClickable(
                                onClick = {
                                    when {
                                        message.sendFailed -> onFailedClick()
                                        detailStatus != null && !detailStatus.showAlways -> onToggleDetailExpand()
                                    }
                                },
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
                                    text = badge.displayEmoji,
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

        if (detailStatus != null && detailStatus.kind == MessageDetailKind.FAILED) {
            Row(
                modifier = Modifier
                    .padding(end = 2.dp, top = 2.dp)
                    .clip(RoundedCornerShape(50))
                    .clickable(role = Role.Button, onClick = onFailedClick)
                    .padding(horizontal = 6.dp, vertical = 3.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(
                    imageVector = Icons.Rounded.ErrorOutline,
                    contentDescription = null,
                    tint = ErrorColor,
                    modifier = Modifier.size(12.dp)
                )
                Text(
                    text = detailStatus.label,
                    style = centeredTextStyle(11.sp, 13.sp, FontWeight.Medium),
                    color = ErrorColor
                )
            }
        } else if (detailStatus != null && (detailStatus.showAlways || isDetailExpanded)) {
            val detailColor = if (detailStatus.kind == MessageDetailKind.READ && message.isLatestOutgoing) {
                palette.onSurface.copy(alpha = 0.88f)
            } else {
                palette.subtleText
            }
            Row(
                modifier = Modifier.padding(
                    start = if (message.isFromMe) 0.dp else 10.dp,
                    end = if (message.isFromMe) 6.dp else 0.dp,
                    top = 4.dp
                ),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = detailStatus.label,
                    style = centeredTextStyle(11.sp, 13.sp, FontWeight.Medium),
                    color = detailColor,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    textAlign = if (message.isFromMe) TextAlign.End else TextAlign.Start
                )
                when (detailStatus.kind) {
                    MessageDetailKind.READ -> {
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
                    MessageDetailKind.DELIVERED -> {
                        Icon(
                            imageVector = Icons.Rounded.Done,
                            contentDescription = "Delivered",
                            tint = palette.subtleText,
                            modifier = Modifier.size(13.dp)
                        )
                    }
                    else -> {}
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
        source.localPath?.let(::File) ?: source.remoteUrl
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
