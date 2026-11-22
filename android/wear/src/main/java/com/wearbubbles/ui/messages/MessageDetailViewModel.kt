package com.wearbubbles.ui.messages

import android.app.Application
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.wearbubbles.WearBubblesApp
import com.wearbubbles.api.dto.ReactionBadge
import com.wearbubbles.api.dto.TapbackType
import com.wearbubbles.api.dto.TapbackUtils
import com.wearbubbles.data.ChatRepository
import com.wearbubbles.data.ContactRepository
import com.wearbubbles.data.LinkPreviewHelper
import com.wearbubbles.data.MessageRepository
import com.wearbubbles.data.SettingsDataStore
import com.wearbubbles.data.shouldRefreshOnResume
import com.wearbubbles.db.AppDatabase
import com.wearbubbles.db.MessageDao
import com.wearbubbles.notifications.NotificationHelper
import com.wearbubbles.relay.RelayEvent
import com.wearbubbles.socket.SocketEvent
import com.wearbubbles.worker.ReplySendWorker
import com.wearbubbles.worker.shouldRetrySend
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Collections
import java.util.UUID

internal fun shouldExposeDirectAttachmentUrl(
    isPhoneConnected: Boolean,
    attachmentGuid: String?,
    failedRelayGuids: Set<String> = emptySet(),
    serverUrl: String,
    password: String
): Boolean {
    if (isPhoneConnected) return false
    if (attachmentGuid.isNullOrBlank() || serverUrl.isBlank() || password.isBlank()) return false
    return true
}

data class AttachmentUi(
    val guid: String,
    val mimeType: String?,
    val url: String?,
    val localPath: String?,
    val transferName: String? = null,
    val isLoading: Boolean = false,
    val isFetchFailed: Boolean = false
) {
    val isImage: Boolean get() = mimeType?.startsWith("image/") == true
    val isAudio: Boolean get() = mimeType?.startsWith("audio/") == true
}

data class LinkPreviewUi(
    val title: String?,
    val subtitle: String?,
    val url: String?,
    val site: String?,
    val imageAttachmentGuid: String? = null,
    val imageUrl: String? = null,
    val localImagePath: String? = null,
    val isImageLoading: Boolean = false,
    val iconUrl: String? = null
)

data class MessageUi(
    val guid: String,
    val text: String?,
    val isFromMe: Boolean,
    val senderName: String?,
    val dateCreated: Long,
    val dateDelivered: Long,
    val dateRead: Long,
    val sendFailed: Boolean,
    val reactions: List<ReactionBadge>,
    val attachmentGuid: String?,
    val attachmentMimeType: String?,
    val attachmentUrl: String?,
    val localAttachmentPath: String?,
    val customHeaders: Map<String, String>,
    val isLatestOutgoing: Boolean,
    val isLastReadOutgoing: Boolean = false,
    val isLastDeliveredOutgoing: Boolean = false,
    val isLastSentOutgoing: Boolean = false,
    val isLatestIncoming: Boolean = false,
    val handleAddress: String? = null,
    val isAttachmentLoading: Boolean = false,
    val isAttachmentFetchFailed: Boolean = false,
    val isPhoneConnected: Boolean = false,
    val dateEdited: Long = 0L,
    val translatedText: String? = null,
    val translationSourceLang: String? = null,
    val translationTargetLang: String? = null,
    val showOriginalTranslation: Boolean = false,
    val isTranslating: Boolean = false,
    val attachments: List<AttachmentUi> = emptyList(),
    val linkPreview: LinkPreviewUi? = null
)

class MessageDetailViewModel(application: Application) : AndroidViewModel(application) {

    companion object {
        private const val TAG = "MessageDetailVM"
        internal const val MAX_EAGER_ATTACHMENTS = 4
        internal const val MAX_CONCURRENT_ATTACHMENT_REQUESTS = 2
    }

    private val db = AppDatabase.getInstance(application)
    private val settings = SettingsDataStore(application)
    private val app = application as WearBubblesApp
    private val relay = app.phoneRelayClient
    private val contactRepo = ContactRepository(application, db.contactDao(), settings, relay)
    private val chatRepo = ChatRepository(db.chatDao(), settings, relay)
    private val messageRepo = MessageRepository(db.messageDao(), db.chatDao(), settings, relay)

    private val _activeChatGuid = MutableStateFlow("")
    private val chatGuid: String
        get() = _activeChatGuid.value
    private var initialChatGuid: String = ""
    private var serverUrl: String = ""
    private var password: String = ""
    private var customHeaders: Map<String, String> = emptyMap()

    private val _chatTitle = MutableStateFlow("Chat")
    val chatTitle: StateFlow<String> = _chatTitle.asStateFlow()

    private val _isGroup = MutableStateFlow(false)
    val isGroup: StateFlow<Boolean> = _isGroup.asStateFlow()

    private val _participants = MutableStateFlow<List<Pair<String, String>>>(emptyList())
    val participants: StateFlow<List<Pair<String, String>>> = _participants.asStateFlow()

    private val _messages = MutableStateFlow<List<MessageUi>>(emptyList())
    val messages: StateFlow<List<MessageUi>> = _messages.asStateFlow()

    private val _showOriginalGuids = MutableStateFlow<Set<String>>(emptySet())
    private val _translatingGuids = MutableStateFlow<Set<String>>(emptySet())

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private val _isLoadingMore = MutableStateFlow(false)
    val isLoadingMore: StateFlow<Boolean> = _isLoadingMore.asStateFlow()

    private val _isSending = MutableStateFlow(false)
    val isSending: StateFlow<Boolean> = _isSending.asStateFlow()

    private val _isTyping = MutableStateFlow(false)
    val isTyping: StateFlow<Boolean> = _isTyping.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    fun clearError() {
        _error.value = null
    }

    fun deleteChat(onDeleted: () -> Unit) {
        if (chatGuid.isBlank()) return
        viewModelScope.launch {
            chatRepo.deleteLocalChat(chatGuid)
            messageRepo.deleteMessagesForChat(chatGuid)
            onDeleted()
        }
    }

    fun deleteFailedMessage(guid: String) {
        viewModelScope.launch {
            if (guid.startsWith("temp-")) {
                ReplySendWorker.cancel(app, guid)
            }
            messageRepo.deleteMessage(guid)
        }
    }

    fun deleteAllFailedMessages() {
        if (chatGuid.isBlank()) return
        viewModelScope.launch {
            _messages.value
                .filter { it.sendFailed && it.guid.startsWith("temp-") }
                .forEach { ReplySendWorker.cancel(app, it.guid) }
            messageRepo.deleteFailedMessages(chatGuid)
        }
    }

    fun retryFailedMessage(msg: MessageUi) {
        val text = msg.text?.trim()?.takeIf { it.isNotBlank() } ?: return
        viewModelScope.launch {
            val tempGuid = if (msg.guid.startsWith("temp-")) {
                ReplySendWorker.cancel(app, msg.guid)
                msg.guid
            } else {
                messageRepo.deleteMessage(msg.guid)
                "temp-${UUID.randomUUID()}"
            }
            sendWithRetryFallback(text, tempGuid)
        }
    }

    // Voice memo recording state
    private val _isRecording = MutableStateFlow(false)
    val isRecording: StateFlow<Boolean> = _isRecording.asStateFlow()

    private val _recordingSeconds = MutableStateFlow(0)
    val recordingSeconds: StateFlow<Int> = _recordingSeconds.asStateFlow()

    private var mediaRecorder: MediaRecorder? = null
    private var recordingFile: File? = null
    private var recordingTimerJob: Job? = null

    // Inline audio playback state
    private val _playingMessageGuid = MutableStateFlow<String?>(null)
    val playingMessageGuid: StateFlow<String?> = _playingMessageGuid.asStateFlow()
    private var mediaPlayer: MediaPlayer? = null

    private var typingTimeoutJob: Job? = null
    private var audioFetchJob: Job? = null
    private var initialMarkReadJob: Job? = null
    private var pendingInitialOpenRead = false
    private var collectorsStarted = false
    private var initialMessageSnapshotSeen = false
    private var lastObservedIncomingGuid: String? = null
    private var hasUnacknowledgedIncoming = false
    private var lastRefreshStartedAtMs = 0L
    private var wasPaused = false
    private val _attachmentRevision = MutableStateFlow(0)
    private val attachmentSemaphore = Semaphore(MAX_CONCURRENT_ATTACHMENT_REQUESTS)
    private val inFlightAttachments = Collections.synchronizedSet(hashSetOf<String>())
    private val failedRelayAttachments = Collections.synchronizedSet(hashSetOf<String>())

    fun init(guid: String) {
        if (initialChatGuid == guid) {
            onScreenResumed()
            return
        }
        initialChatGuid = guid
        _activeChatGuid.value = guid
        initialMessageSnapshotSeen = false
        lastObservedIncomingGuid = null
        hasUnacknowledgedIncoming = false

        if (NotificationHelper.shouldActivateChat(guid)) {
            pendingInitialOpenRead = false
            NotificationHelper.setActiveChat(guid)
            NotificationHelper.cancelNotification(getApplication(), guid)
            initialMarkReadJob = viewModelScope.launch { markChatReadAndAck(guid) }
        } else {
            pendingInitialOpenRead = true
        }

        if (!collectorsStarted) {
            collectorsStarted = true
            startCollectors()
        }

        refresh()
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    private fun startCollectors() {
        viewModelScope.launch {
            withContext(Dispatchers.IO) {
                serverUrl = settings.getServerUrl().trimEnd('/')
                password = settings.getPassword()
                customHeaders = settings.getCustomHeaders()
                contactRepo.loadFromDb()
            }

            launch {
                _activeChatGuid
                    .filter { it.isNotBlank() }
                    .distinctUntilChanged()
                    .collectLatest { guid ->
                        val headerState = withContext(Dispatchers.IO) {
                            messageRepo.markStalePendingFailed(guid)
                            val chat = db.chatDao().getChat(guid)
                            if (chat != null) {
                                val title = contactRepo.resolveChatTitle(
                                    chat.displayName,
                                    chat.chatIdentifier,
                                    chat.participantAddresses
                                )
                                val addrs = chat.participantAddresses.split(",")
                                    .map { it.trim() }
                                    .filter { it.isNotBlank() }
                                    .ifEmpty { listOf(chat.chatIdentifier) }
                                val people = addrs.map { addr -> contactRepo.resolveDisplayName(addr) to addr }
                                Triple(chat.isGroup, title, people)
                            } else {
                                val addr = guid.substringAfterLast(";-;")
                                val resolved = contactRepo.resolveDisplayName(addr)
                                Triple(false, resolved, listOf(resolved to addr))
                            }
                        }
                        _isGroup.value = headerState.first
                        _chatTitle.value = headerState.second
                        _participants.value = headerState.third
                    }
            }

            launch {
                _activeChatGuid
                    .filter { it.isNotBlank() }
                    .distinctUntilChanged()
                    .flatMapLatest { guid ->
                        val uiRevisionFlow = combine(
                            _attachmentRevision,
                            _showOriginalGuids,
                            _translatingGuids
                        ) { rev, showOrig, translating ->
                            Triple(rev, showOrig, translating)
                        }
                        combine(
                            messageRepo.getMessages(guid),
                            uiRevisionFlow,
                            contactRepo.getContactsFlow(),
                            relay.isPhoneConnected,
                            _isGroup
                        ) { allEntities, (_, showOrigGuids, translatingGuids), _, phoneConnected, isGroupChat ->
                            Triple(Triple(allEntities, phoneConnected, isGroupChat), showOrigGuids, translatingGuids)
                        }
                    }
                    .map { (core, showOrigGuids, translatingGuids) ->
                        val (allEntities, phoneConnected, isGroupChat) = core
                        val reactionsByTarget = TapbackUtils.computeReactions(allEntities)
                        val visible = allEntities.filter { !TapbackUtils.isTapbackCode(it.associatedMessageType) }
                        val receiptFlags = computeMessageReceiptFlags(
                            visible.map {
                                MessageReceiptCandidate(
                                    guid = it.guid,
                                    isFromMe = it.isFromMe,
                                    sendFailed = it.sendFailed,
                                    isPending = MessageDao.isTempPlaceholderGuid(it.guid),
                                    dateRead = it.dateRead ?: 0L,
                                    dateDelivered = it.dateDelivered ?: 0L,
                                    dateCreated = it.dateCreated
                                )
                            }
                        )

                        val parsedAttachmentsByMsg = HashMap<String, List<com.wearbubbles.api.dto.AttachmentDto>>(visible.size)
                        val parsedPreviewByMsg = HashMap<String, com.wearbubbles.api.dto.LinkPreviewDto?>(visible.size)
                        val cachedFiles = HashMap<String, String>()
                        for (entity in visible) {
                            val atts = LinkPreviewHelper.parseAttachments(
                                entity.attachmentsJson,
                                entity.attachmentGuid,
                                entity.attachmentMimeType
                            )
                            parsedAttachmentsByMsg[entity.guid] = atts
                            val preview = LinkPreviewHelper.parseLinkPreview(entity.linkPreviewJson)
                            parsedPreviewByMsg[entity.guid] = preview

                            for (att in atts) {
                                if (att.guid.isNotBlank() && att.guid !in cachedFiles) {
                                    relay.getCachedAttachmentFile(att.guid)?.absolutePath?.let { path ->
                                        cachedFiles[att.guid] = path
                                    }
                                }
                            }
                            val previewAttGuid = preview?.imageAttachmentGuid
                            if (!previewAttGuid.isNullOrBlank() && previewAttGuid !in cachedFiles) {
                                relay.getCachedAttachmentFile(previewAttGuid)?.absolutePath?.let { path ->
                                    cachedFiles[previewAttGuid] = path
                                }
                            }
                        }

                        val inFlightSnapshot = synchronized(inFlightAttachments) { inFlightAttachments.toSet() }
                        val failedSnapshot = synchronized(failedRelayAttachments) { failedRelayAttachments.toSet() }

                        val eagerGuids = if (phoneConnected) {
                            selectEagerAttachmentGuids(
                                messages = visible,
                                cachedGuids = cachedFiles.keys,
                                failedGuids = failedSnapshot
                            )
                        } else {
                            emptyList()
                        }

                        val uiList = visible.map { entity ->
                            val reactions = reactionsByTarget[entity.guid].orEmpty()
                            val senderName = if (!entity.isFromMe && isGroupChat && entity.handleAddress != null) {
                                contactRepo.resolveDisplayName(entity.handleAddress)
                            } else null

                            val parsedPreview = parsedPreviewByMsg[entity.guid]
                            val rawAtts = parsedAttachmentsByMsg[entity.guid].orEmpty()
                            val displayAtts = if (parsedPreview != null) {
                                rawAtts.filterNot { att ->
                                    LinkPreviewHelper.isPluginPayloadAttachment(att.transferName) ||
                                        att.guid == parsedPreview.imageAttachmentGuid
                                }
                            } else {
                                rawAtts
                            }
                            val uiAttachments = displayAtts.map { att ->
                                val directUrl = if (shouldExposeDirectAttachmentUrl(
                                        isPhoneConnected = phoneConnected,
                                        attachmentGuid = att.guid,
                                        failedRelayGuids = failedSnapshot,
                                        serverUrl = serverUrl,
                                        password = password
                                    )
                                ) {
                                    com.wearbubbles.api.ApiClient.getAttachmentUrl(
                                        serverUrl,
                                        password,
                                        att.guid,
                                        att.mimeType
                                    )
                                } else null
                                val local = cachedFiles[att.guid]
                                AttachmentUi(
                                    guid = att.guid,
                                    mimeType = att.mimeType,
                                    url = directUrl,
                                    localPath = local,
                                    transferName = att.transferName,
                                    isLoading = local == null && att.guid in inFlightSnapshot,
                                    isFetchFailed = local == null && att.guid in failedSnapshot
                                )
                            }
                            val primaryAtt = uiAttachments.firstOrNull()
                            val attGuid = primaryAtt?.guid ?: entity.attachmentGuid
                            val localPath = primaryAtt?.localPath ?: attGuid?.let { cachedFiles[it] }
                            val attUrl = primaryAtt?.url ?: if (shouldExposeDirectAttachmentUrl(
                                    isPhoneConnected = phoneConnected,
                                    attachmentGuid = attGuid,
                                    failedRelayGuids = failedSnapshot,
                                    serverUrl = serverUrl,
                                    password = password
                                )
                            ) {
                                com.wearbubbles.api.ApiClient.getAttachmentUrl(
                                    serverUrl,
                                    password,
                                    attGuid!!,
                                    entity.attachmentMimeType
                                )
                            } else null

                            val previewUi = parsedPreview?.let { base ->
                                val previewAttGuid = base.imageAttachmentGuid
                                val localPreviewImg = previewAttGuid?.let { cachedFiles[it] }
                                val directPreviewImgUrl = if (!previewAttGuid.isNullOrBlank() &&
                                    shouldExposeDirectAttachmentUrl(
                                        isPhoneConnected = phoneConnected,
                                        attachmentGuid = previewAttGuid,
                                        failedRelayGuids = failedSnapshot,
                                        serverUrl = serverUrl,
                                        password = password
                                    )
                                ) {
                                    com.wearbubbles.api.ApiClient.getAttachmentUrl(
                                        serverUrl,
                                        password,
                                        previewAttGuid,
                                        "image/jpeg"
                                    )
                                } else null
                                val targetUrl = base.url
                                LinkPreviewUi(
                                    title = base.title,
                                    subtitle = base.subtitle,
                                    url = targetUrl,
                                    site = base.site ?: LinkPreviewHelper.deriveSiteHost(targetUrl),
                                    imageAttachmentGuid = previewAttGuid,
                                    imageUrl = directPreviewImgUrl ?: base.imageUrl,
                                    localImagePath = localPreviewImg,
                                    isImageLoading = previewAttGuid != null &&
                                        localPreviewImg == null &&
                                        previewAttGuid in inFlightSnapshot,
                                    iconUrl = base.iconUrl
                                )
                            }

                            MessageUi(
                                guid = entity.guid,
                                text = entity.text,
                                isFromMe = entity.isFromMe,
                                senderName = senderName,
                                dateCreated = entity.dateCreated,
                                dateDelivered = entity.dateDelivered ?: 0L,
                                dateRead = entity.dateRead ?: 0L,
                                sendFailed = entity.sendFailed,
                                reactions = reactions,
                                attachmentGuid = attGuid,
                                attachmentMimeType = primaryAtt?.mimeType ?: entity.attachmentMimeType,
                                attachmentUrl = attUrl,
                                localAttachmentPath = localPath,
                                customHeaders = customHeaders,
                                isLatestOutgoing = entity.guid == receiptFlags.latestOutgoingGuid,
                                isLastReadOutgoing = entity.guid == receiptFlags.lastReadOutgoingGuid,
                                isLastDeliveredOutgoing = entity.guid == receiptFlags.lastDeliveredOutgoingGuid,
                                isLastSentOutgoing = entity.guid == receiptFlags.lastSentOutgoingGuid,
                                isLatestIncoming = entity.guid == receiptFlags.latestIncomingGuid,
                                handleAddress = entity.handleAddress,
                                isAttachmentLoading = primaryAtt?.isLoading ?: (attGuid != null && localPath == null && attGuid in inFlightSnapshot),
                                isAttachmentFetchFailed = primaryAtt?.isFetchFailed ?: (attGuid != null && localPath == null && attGuid in failedSnapshot),
                                isPhoneConnected = phoneConnected,
                                dateEdited = entity.dateEdited ?: 0L,
                                translatedText = entity.translatedText,
                                translationSourceLang = entity.translationSourceLang,
                                translationTargetLang = entity.translationTargetLang,
                                showOriginalTranslation = entity.guid in showOrigGuids,
                                isTranslating = entity.guid in translatingGuids,
                                attachments = uiAttachments,
                                linkPreview = previewUi
                            )
                        }
                        uiList to eagerGuids
                    }
                    .flowOn(Dispatchers.IO)
                    .collect { (uiList, eagerGuids) ->
                        val latestIncomingGuid = uiList.lastOrNull { !it.isFromMe }?.guid
                        if (!initialMessageSnapshotSeen) {
                            initialMessageSnapshotSeen = true
                            lastObservedIncomingGuid = latestIncomingGuid
                        } else if (latestIncomingGuid != null && latestIncomingGuid != lastObservedIncomingGuid) {
                            lastObservedIncomingGuid = latestIncomingGuid
                            hasUnacknowledgedIncoming = true
                        }
                        _messages.value = uiList
                        eagerGuids.forEach { requestAttachmentIfNeeded(it) }
                    }
            }
        }

        // Socket typing indicators (DB persistence is owned by WearBubblesApp)
        viewModelScope.launch {
            app.socketManager.events.collect { event ->
                when (event) {
                    is SocketEvent.NewMessage -> {
                        val msg = event.message
                        if (msg.chats?.firstOrNull()?.guid == chatGuid && !msg.isFromMe) {
                            _isTyping.value = false
                            hasUnacknowledgedIncoming = true
                        }
                    }
                    is SocketEvent.TypingIndicator -> {
                        if (event.chatGuid == chatGuid) {
                            setTypingIndicator(event.display)
                        }
                    }
                    else -> {}
                }
            }
        }

        // Phone-Relay typing & streamed attachment events
        viewModelScope.launch {
            relay.events.collect { event ->
                when (event) {
                    is RelayEvent.TypingIndicator -> {
                        if (event.chatGuid == chatGuid) {
                            setTypingIndicator(event.isTyping)
                        }
                    }
                    is RelayEvent.AttachmentDownloaded -> {
                        _attachmentRevision.value += 1
                    }
                    is RelayEvent.NewMessage -> {
                        val msg = event.message
                        if (msg.chatGuid == chatGuid && !msg.isFromMe) {
                            _isTyping.value = false
                            hasUnacknowledgedIncoming = true
                        }
                    }
                    is RelayEvent.UpdatedMessage -> {}
                }
            }
        }
    }

    fun retryAttachment(attGuid: String?) {
        if (attGuid.isNullOrBlank()) return
        synchronized(failedRelayAttachments) {
            failedRelayAttachments.remove(attGuid)
        }
        _attachmentRevision.update { it + 1 }
        viewModelScope.launch(Dispatchers.IO) {
            relay.refreshPhoneConnected(force = true)
            requestAttachmentIfNeeded(attGuid)
        }
    }

    fun requestAttachmentIfNeeded(attGuid: String?) {
        if (attGuid.isNullOrBlank() || !relay.isPhoneConnected.value) return
        val added = synchronized(inFlightAttachments) {
            if (attGuid in failedRelayAttachments) false else inFlightAttachments.add(attGuid)
        }
        if (!added) return
        _attachmentRevision.update { it + 1 }
        viewModelScope.launch(Dispatchers.IO) {
            try {
                if (relay.getCachedAttachmentFile(attGuid) != null) {
                    return@launch
                }
                val fetched = attachmentSemaphore.withPermit {
                    relay.getOrRequestAttachment(attGuid)
                }
                if (fetched != null) {
                    synchronized(failedRelayAttachments) { failedRelayAttachments.remove(attGuid) }
                } else {
                    synchronized(failedRelayAttachments) { failedRelayAttachments.add(attGuid) }
                }
            } finally {
                synchronized(inFlightAttachments) { inFlightAttachments.remove(attGuid) }
                _attachmentRevision.update { it + 1 }
            }
        }
    }

    fun onScreenPaused() {
        wasPaused = true
    }

    fun onScreenResumed() {
        val guid = chatGuid
        if (guid.isBlank()) return
        val nowMs = System.currentTimeMillis()
        if (shouldRefreshOnResume(_isLoading.value, wasPaused, lastRefreshStartedAtMs, nowMs, minIntervalMs = 2_000L)) {
            wasPaused = false
            refresh()
        } else {
            wasPaused = false
        }

        if (!NotificationHelper.shouldActivateChat(guid)) return
        if (NotificationHelper.activeChatGuid.value != guid) {
            NotificationHelper.setActiveChat(guid)
        }
        NotificationHelper.cancelNotification(getApplication(), guid)

        if (pendingInitialOpenRead) {
            pendingInitialOpenRead = false
            if (initialMarkReadJob?.isActive == true) return
            initialMarkReadJob = viewModelScope.launch {
                markChatReadAndAck(guid)
            }
        }
    }

    fun onUserInteraction() {
        val guid = chatGuid
        if (guid.isBlank() || !NotificationHelper.isAppResumedOrUnbound()) return
        if (!hasUnacknowledgedIncoming) return
        if (initialMarkReadJob?.isActive == true) return
        initialMarkReadJob = viewModelScope.launch {
            markChatReadAndAck(guid)
        }
    }

    private suspend fun markChatReadAndAck(guid: String) {
        hasUnacknowledgedIncoming = false
        chatRepo.markChatRead(guid)
    }

    private suspend fun markChatReadIfResumed(guid: String) {
        if (guid.isNotBlank() && NotificationHelper.isAppResumedOrUnbound()) {
            markChatReadAndAck(guid)
        }
    }

    private fun switchChatGuidIfResolved(resolvedGuid: String?) {
        val current = chatGuid
        val next = resolveEffectiveChatGuid(current, resolvedGuid)
        if (next != current) {
            _activeChatGuid.value = next
            if (NotificationHelper.activeChatGuid.value == current) {
                NotificationHelper.setActiveChat(next)
            }
        }
    }

    private fun setTypingIndicator(display: Boolean) {
        _isTyping.value = display
        typingTimeoutJob?.cancel()
        if (display) {
            typingTimeoutJob = viewModelScope.launch {
                delay(15_000)
                _isTyping.value = false
            }
        }
    }

    fun refresh() {
        val guid = chatGuid
        if (guid.isBlank() || _isLoading.value) return
        viewModelScope.launch {
            lastRefreshStartedAtMs = System.currentTimeMillis()
            _isLoading.value = true
            _error.value = null
            try {
                val result = messageRepo.refreshMessages(guid)
                result.exceptionOrNull()?.let { err ->
                    if (_messages.value.isEmpty()) {
                        _error.value = err.localizedMessage?.take(50)
                    }
                }
            } catch (e: Exception) {
                if (_messages.value.isEmpty()) {
                    _error.value = e.localizedMessage?.take(50)
                }
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun loadMore() {
        if (_isLoadingMore.value) return
        viewModelScope.launch {
            _isLoadingMore.value = true
            try {
                messageRepo.loadMoreMessages(chatGuid)
            } finally {
                _isLoadingMore.value = false
            }
        }
    }

    fun sendMessage(text: String) {
        val trimmed = text.trim()
        if (trimmed.isBlank()) return
        viewModelScope.launch {
            val tempGuid = "temp-${UUID.randomUUID()}"
            sendWithRetryFallback(trimmed, tempGuid)
        }
    }

    private suspend fun sendWithRetryFallback(text: String, tempGuid: String) {
        _isSending.value = true
        _error.value = null
        val res = messageRepo.sendMessage(
            chatGuid = chatGuid,
            text = text,
            existingTempGuid = tempGuid,
            shouldMarkFailed = { err -> relay.isPhoneConnected.value || !shouldRetrySend(err, 0) }
        )
        if (res.isFailure) {
            val err = res.exceptionOrNull()
            if (!relay.isPhoneConnected.value && shouldRetrySend(err, 0)) {
                ReplySendWorker.enqueue(
                    context = app,
                    chatGuid = chatGuid,
                    senderName = _chatTitle.value,
                    replyText = text,
                    tempGuid = tempGuid,
                    fromNotification = false
                )
                _error.value = "Queued"
            } else {
                _error.value = err?.localizedMessage?.take(50) ?: "Failed to send"
            }
        } else {
            val resolvedGuid = res.getOrNull()?.chatGuid ?: chatGuid
            switchChatGuidIfResolved(resolvedGuid)
            markChatReadIfResumed(resolvedGuid)
        }
        _isSending.value = false
    }

    fun toggleTapback(messageGuid: String, tapback: TapbackType, currentlyActiveByMe: Boolean) {
        viewModelScope.launch {
            val guid = chatGuid
            val res = messageRepo.reactToMessage(guid, messageGuid, tapback, remove = currentlyActiveByMe)
            if (res.isFailure) {
                _error.value = "Reaction failed"
            } else {
                markChatReadIfResumed(guid)
            }
        }
    }

    fun toggleOriginalTranslation(messageGuid: String) {
        _showOriginalGuids.update { current ->
            if (messageGuid in current) current - messageGuid else current + messageGuid
        }
    }

    fun translateMessage(messageGuid: String) {
        if (messageGuid.isBlank() || messageGuid in _translatingGuids.value) return
        viewModelScope.launch {
            _translatingGuids.update { it + messageGuid }
            val res = messageRepo.translateMessage(messageGuid)
            _translatingGuids.update { it - messageGuid }
            if (res.isFailure) {
                _error.value = res.exceptionOrNull()?.localizedMessage?.take(40) ?: "Translation failed"
            } else {
                _showOriginalGuids.update { it - messageGuid }
            }
        }
    }

    fun startRecording() {
        if (_isRecording.value) return
        try {
            stopAudioPlayback()
            val outFile = File(getApplication<Application>().cacheDir, "voice_${System.currentTimeMillis()}.m4a")
            val recorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(getApplication())
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }
            recorder.apply {
                setAudioSource(MediaRecorder.AudioSource.MIC)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setAudioSamplingRate(16_000)
                setAudioEncodingBitRate(32_000)
                setOutputFile(outFile.absolutePath)
                prepare()
                start()
            }
            mediaRecorder = recorder
            recordingFile = outFile
            _isRecording.value = true
            _recordingSeconds.value = 0

            recordingTimerJob?.cancel()
            recordingTimerJob = viewModelScope.launch {
                while (_isRecording.value) {
                    delay(1_000)
                    _recordingSeconds.value += 1
                    if (_recordingSeconds.value >= 120) {
                        stopAndSendRecording()
                        break
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start recording: ${e.message}")
            _error.value = "Mic unavailable"
            cleanupRecorder(deleteFile = true)
        }
    }

    fun stopAndSendRecording() {
        if (!_isRecording.value) return
        val file = recordingFile
        try {
            mediaRecorder?.stop()
        } catch (e: Exception) {
            Log.w(TAG, "Recorder stop failed: ${e.message}")
            cleanupRecorder(deleteFile = true)
            return
        }
        cleanupRecorder(deleteFile = false)
        if (file != null && file.exists() && file.length() > 0) {
            viewModelScope.launch {
                _isSending.value = true
                val res = messageRepo.sendVoiceMemo(chatGuid, file)
                if (res.isFailure) {
                    _error.value = res.exceptionOrNull()?.localizedMessage?.take(50) ?: "Voice memo send failed"
                } else {
                    val resolvedGuid = res.getOrNull()?.chatGuid ?: chatGuid
                    switchChatGuidIfResolved(resolvedGuid)
                    markChatReadIfResumed(resolvedGuid)
                }
                file.delete()
                _isSending.value = false
            }
        }
    }

    fun cancelRecording() {
        try {
            mediaRecorder?.stop()
        } catch (_: Exception) {
        }
        cleanupRecorder(deleteFile = true)
    }

    private fun cleanupRecorder(deleteFile: Boolean) {
        recordingTimerJob?.cancel()
        recordingTimerJob = null
        try {
            mediaRecorder?.release()
        } catch (_: Exception) {
        }
        mediaRecorder = null
        _isRecording.value = false
        _recordingSeconds.value = 0
        if (deleteFile) {
            recordingFile?.delete()
        }
        recordingFile = null
    }

    fun toggleAudioPlayback(msg: MessageUi) {
        if (_playingMessageGuid.value == msg.guid) {
            stopAudioPlayback()
            return
        }
        stopAudioPlayback()

        val localFile = msg.localAttachmentPath?.let { File(it) }?.takeIf { it.exists() }
        if (localFile != null) {
            startMediaPlayer(msg.guid, localFile, null, msg.customHeaders)
            return
        }

        val attGuid = msg.attachmentGuid
        if (relay.isPhoneConnected.value && !attGuid.isNullOrBlank()) {
            failedRelayAttachments.remove(attGuid)
            _error.value = "Downloading audio..."
            audioFetchJob = viewModelScope.launch {
                val fetched = relay.getOrRequestAttachment(attGuid)
                if (fetched != null && fetched.exists()) {
                    failedRelayAttachments.remove(attGuid)
                    _attachmentRevision.value += 1
                    _error.value = null
                    startMediaPlayer(msg.guid, fetched, null, msg.customHeaders)
                } else {
                    failedRelayAttachments.add(attGuid)
                    _attachmentRevision.value += 1
                    if (shouldExposeDirectAttachmentUrl(
                            isPhoneConnected = relay.isPhoneConnected.value,
                            attachmentGuid = attGuid,
                            failedRelayGuids = failedRelayAttachments,
                            serverUrl = serverUrl,
                            password = password
                        )
                    ) {
                        val fallbackUrl = com.wearbubbles.api.ApiClient.getAttachmentUrl(
                            serverUrl,
                            password,
                            attGuid,
                            msg.attachmentMimeType
                        )
                        _error.value = null
                        startMediaPlayer(msg.guid, null, fallbackUrl, msg.customHeaders)
                    } else {
                        _error.value = "Audio unavailable"
                    }
                }
            }
            return
        }

        val url = msg.attachmentUrl
        if (!url.isNullOrBlank()) {
            startMediaPlayer(msg.guid, null, url, msg.customHeaders)
        } else {
            _error.value = "Audio unavailable"
        }
    }

    private fun startMediaPlayer(
        msgGuid: String,
        localFile: File?,
        remoteUrl: String?,
        customHeaders: Map<String, String>
    ) {
        try {
            val player = MediaPlayer().apply {
                if (localFile != null) {
                    setDataSource(localFile.absolutePath)
                } else {
                    setDataSource(getApplication(), Uri.parse(remoteUrl!!), customHeaders)
                }
                setOnPreparedListener {
                    _playingMessageGuid.value = msgGuid
                    it.start()
                }
                setOnCompletionListener {
                    stopAudioPlayback()
                }
                setOnErrorListener { _, _, _ ->
                    stopAudioPlayback()
                    _error.value = "Audio playback failed"
                    true
                }
                prepareAsync()
            }
            mediaPlayer = player
        } catch (e: Exception) {
            Log.e(TAG, "Audio playback error: ${e.message}")
            stopAudioPlayback()
            _error.value = "Audio error"
        }
    }

    fun stopAudioPlayback() {
        audioFetchJob?.cancel()
        audioFetchJob = null
        try {
            mediaPlayer?.stop()
        } catch (_: Exception) {
        }
        try {
            mediaPlayer?.release()
        } catch (_: Exception) {
        }
        mediaPlayer = null
        _playingMessageGuid.value = null
    }

    override fun onCleared() {
        if (chatGuid.isNotBlank() && NotificationHelper.activeChatGuid.value == chatGuid) {
            NotificationHelper.setActiveChat(null)
        }
        cleanupRecorder(deleteFile = true)
        stopAudioPlayback()
        super.onCleared()
    }
}

internal fun resolveEffectiveChatGuid(currentGuid: String, resolvedGuid: String?): String =
    resolvedGuid?.takeIf { it.isNotBlank() } ?: currentGuid

internal fun selectEagerAttachmentGuids(
    messages: List<com.wearbubbles.db.entities.MessageEntity>,
    cachedGuids: Set<String>,
    failedGuids: Set<String>,
    limit: Int = MessageDetailViewModel.MAX_EAGER_ATTACHMENTS
): List<String> {
    if (limit <= 0) return emptyList()
    val picked = ArrayList<String>(limit)
    for (entity in messages.asReversed()) {
        val attachments = LinkPreviewHelper.parseAttachments(
            entity.attachmentsJson,
            entity.attachmentGuid,
            entity.attachmentMimeType
        )
        for (att in attachments) {
            val attGuid = att.guid
            val mime = att.mimeType ?: ""
            if (attGuid.isNotBlank() &&
                attGuid !in failedGuids &&
                attGuid !in cachedGuids &&
                attGuid !in picked &&
                mime.startsWith("image/")
            ) {
                picked.add(attGuid)
                if (picked.size >= limit) return picked
            }
        }
        val previewGuid = LinkPreviewHelper.parseLinkPreview(entity.linkPreviewJson)?.imageAttachmentGuid
        if (!previewGuid.isNullOrBlank() &&
            previewGuid !in failedGuids &&
            previewGuid !in cachedGuids &&
            previewGuid !in picked
        ) {
            picked.add(previewGuid)
            if (picked.size >= limit) return picked
        }
    }
    return picked
}
