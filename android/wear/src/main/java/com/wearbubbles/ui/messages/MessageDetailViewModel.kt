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
import com.wearbubbles.data.MessageRepository
import com.wearbubbles.data.SettingsDataStore
import com.wearbubbles.db.AppDatabase
import com.wearbubbles.db.MessageDao
import com.wearbubbles.notifications.NotificationHelper
import com.wearbubbles.relay.RelayEvent
import com.wearbubbles.socket.SocketEvent
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

internal fun shouldExposeDirectAttachmentUrl(
    isPhoneConnected: Boolean,
    attachmentGuid: String?,
    failedRelayGuids: Set<String>,
    serverUrl: String,
    password: String
): Boolean {
    if (attachmentGuid.isNullOrBlank() || serverUrl.isBlank() || password.isBlank()) return false
    return !isPhoneConnected || attachmentGuid in failedRelayGuids
}

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
    val isLatestIncoming: Boolean = false,
    val handleAddress: String? = null,
    val isAttachmentLoading: Boolean = false,
    val isAttachmentFetchFailed: Boolean = false,
    val isPhoneConnected: Boolean = false
)

class MessageDetailViewModel(application: Application) : AndroidViewModel(application) {

    companion object {
        private const val TAG = "MessageDetailVM"
        internal const val MAX_EAGER_ATTACHMENTS = 8
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
            messageRepo.deleteMessage(guid)
        }
    }

    fun deleteAllFailedMessages() {
        if (chatGuid.isBlank()) return
        viewModelScope.launch {
            messageRepo.deleteFailedMessages(chatGuid)
        }
    }

    fun retryFailedMessage(msg: MessageUi) {
        val text = msg.text?.trim()?.takeIf { it.isNotBlank() } ?: return
        viewModelScope.launch {
            messageRepo.deleteMessage(msg.guid)
            _isSending.value = true
            _error.value = null
            val res = messageRepo.sendMessage(chatGuid, text)
            if (res.isFailure) {
                _error.value = res.exceptionOrNull()?.localizedMessage?.take(50) ?: "Failed to send"
            } else {
                val resolvedGuid = res.getOrNull()?.chatGuid ?: chatGuid
                switchChatGuidIfResolved(resolvedGuid)
                markChatReadIfResumed(resolvedGuid)
            }
            _isSending.value = false
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
                        combine(
                            messageRepo.getMessages(guid),
                            _attachmentRevision,
                            contactRepo.getContactsFlow(),
                            relay.isPhoneConnected,
                            _isGroup
                        ) { allEntities, _, _, phoneConnected, isGroupChat ->
                            Triple(allEntities, phoneConnected, isGroupChat)
                        }
                    }
                    .map { (allEntities, phoneConnected, isGroupChat) ->
                        val reactionsByTarget = TapbackUtils.computeReactions(allEntities)
                        val visible = allEntities.filter { !TapbackUtils.isTapbackCode(it.associatedMessageType) }
                        val receiptFlags = computeMessageReceiptFlags(
                            visible.map {
                                MessageReceiptCandidate(
                                    guid = it.guid,
                                    isFromMe = it.isFromMe,
                                    sendFailed = it.sendFailed,
                                    isPending = MessageDao.isTempPlaceholderGuid(it.guid),
                                    dateRead = it.dateRead ?: 0L
                                )
                            }
                        )

                        val cachedFiles = HashMap<String, String>()
                        for (entity in visible) {
                            val attGuid = entity.attachmentGuid
                            if (!attGuid.isNullOrBlank() && attGuid !in cachedFiles) {
                                relay.getCachedAttachmentFile(attGuid)?.absolutePath?.let { path ->
                                    cachedFiles[attGuid] = path
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

                            val attUrl = if (shouldExposeDirectAttachmentUrl(
                                    isPhoneConnected = phoneConnected,
                                    attachmentGuid = entity.attachmentGuid,
                                    failedRelayGuids = failedSnapshot,
                                    serverUrl = serverUrl,
                                    password = password
                                )
                            ) {
                                com.wearbubbles.api.ApiClient.getAttachmentUrl(serverUrl, password, entity.attachmentGuid!!)
                            } else null

                            val attGuid = entity.attachmentGuid
                            val localPath = attGuid?.let { cachedFiles[it] }
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
                                attachmentMimeType = entity.attachmentMimeType,
                                attachmentUrl = attUrl,
                                localAttachmentPath = localPath,
                                customHeaders = customHeaders,
                                isLatestOutgoing = entity.guid == receiptFlags.latestOutgoingGuid,
                                isLastReadOutgoing = entity.guid == receiptFlags.lastReadOutgoingGuid,
                                isLatestIncoming = entity.guid == receiptFlags.latestIncomingGuid,
                                handleAddress = entity.handleAddress,
                                isAttachmentLoading = attGuid != null && localPath == null && attGuid in inFlightSnapshot,
                                isAttachmentFetchFailed = attGuid != null && localPath == null && attGuid in failedSnapshot,
                                isPhoneConnected = phoneConnected
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

    fun onScreenResumed() {
        val guid = chatGuid
        if (guid.isBlank() || !NotificationHelper.shouldActivateChat(guid)) return
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
        viewModelScope.launch {
            _isLoading.value = true
            _error.value = null
            try {
                messageRepo.refreshMessages(chatGuid)
            } catch (e: Exception) {
                _error.value = e.localizedMessage?.take(50)
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
        if (text.isBlank()) return
        viewModelScope.launch {
            _isSending.value = true
            _error.value = null
            val res = messageRepo.sendMessage(chatGuid, text.trim())
            if (res.isFailure) {
                _error.value = res.exceptionOrNull()?.localizedMessage?.take(50) ?: "Failed to send"
            } else {
                val resolvedGuid = res.getOrNull()?.chatGuid ?: chatGuid
                switchChatGuidIfResolved(resolvedGuid)
                markChatReadIfResumed(resolvedGuid)
            }
            _isSending.value = false
        }
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
        if (relay.isPhoneConnected.value && !attGuid.isNullOrBlank() && attGuid !in failedRelayAttachments) {
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
                        val fallbackUrl = com.wearbubbles.api.ApiClient.getAttachmentUrl(serverUrl, password, attGuid)
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
        val attGuid = entity.attachmentGuid
        val mime = entity.attachmentMimeType ?: ""
        if (!attGuid.isNullOrBlank() &&
            attGuid !in failedGuids &&
            attGuid !in cachedGuids &&
            (mime.startsWith("image/") || mime.startsWith("audio/"))
        ) {
            picked.add(attGuid)
            if (picked.size >= limit) break
        }
    }
    return picked
}
