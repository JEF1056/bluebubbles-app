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
import com.wearbubbles.api.dto.TapbackType
import com.wearbubbles.api.dto.TapbackUtils
import com.wearbubbles.data.ChatRepository
import com.wearbubbles.data.ContactRepository
import com.wearbubbles.data.MessageRepository
import com.wearbubbles.data.SettingsDataStore
import com.wearbubbles.db.AppDatabase
import com.wearbubbles.notifications.NotificationHelper
import com.wearbubbles.relay.RelayEvent
import com.wearbubbles.socket.SocketEvent
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import java.io.File
import java.util.Collections

data class ReactionBadgeUi(
    val type: TapbackType,
    val count: Int,
    val isFromMe: Boolean
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
    val reactions: List<ReactionBadgeUi>,
    val attachmentGuid: String?,
    val attachmentMimeType: String?,
    val attachmentUrl: String?,
    val localAttachmentPath: String?,
    val customHeaders: Map<String, String>,
    val isLatestOutgoing: Boolean,
    val handleAddress: String? = null
)

class MessageDetailViewModel(application: Application) : AndroidViewModel(application) {

    companion object {
        private const val TAG = "MessageDetailVM"
    }

    private val db = AppDatabase.getInstance(application)
    private val settings = SettingsDataStore(application)
    private val app = application as WearBubblesApp
    private val relay = app.phoneRelayClient
    private val contactRepo = ContactRepository(application, db.contactDao(), settings, relay)
    private val chatRepo = ChatRepository(db.chatDao(), settings, relay)
    private val messageRepo = MessageRepository(db.messageDao(), db.chatDao(), settings, relay)

    private var chatGuid: String = ""
    private var serverUrl: String = ""
    private var password: String = ""
    private var customHeaders: Map<String, String> = emptyMap()

    private val _chatTitle = MutableStateFlow("Chat")
    val chatTitle: StateFlow<String> = _chatTitle.asStateFlow()

    private val _chatAvatarPath = MutableStateFlow<String?>(null)
    val chatAvatarPath: StateFlow<String?> = _chatAvatarPath.asStateFlow()

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
            onDeleted()
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
    private val _attachmentRevision = MutableStateFlow(0)
    private val inFlightAttachments = Collections.synchronizedSet(hashSetOf<String>())

    fun init(guid: String) {
        if (chatGuid == guid) return
        chatGuid = guid
        NotificationHelper.setActiveChat(guid)
        NotificationHelper.cancelNotification(getApplication(), guid)

        viewModelScope.launch {
            serverUrl = settings.getServerUrl().trimEnd('/')
            password = settings.getPassword()
            customHeaders = settings.getCustomHeaders()
            contactRepo.loadFromDb()

            val chat = db.chatDao().getChat(guid)
            if (chat != null) {
                _isGroup.value = chat.isGroup
                _chatTitle.value = contactRepo.resolveChatTitle(
                    chat.displayName,
                    chat.chatIdentifier,
                    chat.participantAddresses
                )
                _chatAvatarPath.value = contactRepo.resolveAvatarForChat(chat.guid, chat.participantAddresses)
                val addrs = chat.participantAddresses.split(",")
                    .map { it.trim() }
                    .filter { it.isNotBlank() }
                    .ifEmpty { listOf(chat.chatIdentifier) }
                _participants.value = addrs.map { addr -> contactRepo.resolveDisplayName(addr) to addr }
            } else {
                val addr = guid.substringAfterLast(";-;")
                val resolved = contactRepo.resolveDisplayName(addr)
                _chatTitle.value = resolved
                _chatAvatarPath.value = contactRepo.resolveAvatarPath(addr)
                _participants.value = listOf(resolved to addr)
            }

            chatRepo.markChatRead(guid)
        }

        viewModelScope.launch {
            combine(
                messageRepo.getMessages(guid),
                _attachmentRevision,
                contactRepo.getContactsFlow()
            ) { allEntities, _, _ ->
                allEntities
            }.collect { allEntities ->
                val reactionsByTarget = TapbackUtils.computeReactions(allEntities)
                val visible = allEntities.filter { !TapbackUtils.isTapbackCode(it.associatedMessageType) }
                val latestOutgoingGuid = visible.lastOrNull { it.isFromMe }?.guid

                // Request attachment streaming from phone when tethered and not cached yet
                if (relay.isPhoneConnected.value) {
                    visible.forEach { entity ->
                        val attGuid = entity.attachmentGuid
                        val mime = entity.attachmentMimeType ?: ""
                        if (!attGuid.isNullOrBlank() &&
                            relay.getCachedAttachmentFile(attGuid) == null &&
                            (mime.startsWith("image/") || mime.startsWith("audio/")) &&
                            inFlightAttachments.add(attGuid)
                        ) {
                            viewModelScope.launch {
                                try {
                                    if (relay.getOrRequestAttachment(attGuid) != null) {
                                        _attachmentRevision.value += 1
                                    }
                                } finally {
                                    inFlightAttachments.remove(attGuid)
                                }
                            }
                        }
                    }
                }

                _messages.value = visible.map { entity ->
                    val reactions = reactionsByTarget[entity.guid].orEmpty().map {
                        ReactionBadgeUi(it.type, it.count, it.isFromMe)
                    }
                    val senderName = if (!entity.isFromMe && _isGroup.value && entity.handleAddress != null) {
                        contactRepo.resolveDisplayName(entity.handleAddress)
                    } else null

                    val attUrl = if (entity.attachmentGuid != null && serverUrl.isNotBlank() && password.isNotBlank()) {
                        "$serverUrl/api/v1/attachment/${entity.attachmentGuid}/download?password=$password"
                    } else null

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
                        attachmentGuid = entity.attachmentGuid,
                        attachmentMimeType = entity.attachmentMimeType,
                        attachmentUrl = attUrl,
                        localAttachmentPath = entity.attachmentGuid?.let { relay.getCachedAttachmentFile(it)?.absolutePath },
                        customHeaders = customHeaders,
                        isLatestOutgoing = entity.guid == latestOutgoingGuid,
                        handleAddress = entity.handleAddress
                    )
                }
            }
        }

        // Socket events (Direct Server mode)
        viewModelScope.launch {
            app.socketManager.events.collect { event ->
                when (event) {
                    is SocketEvent.NewMessage -> {
                        val msg = event.message
                        val msgChatGuid = msg.chats?.firstOrNull()?.guid
                        if (msgChatGuid == chatGuid) {
                            messageRepo.handleIncomingSocketMessage(msg)
                            if (!msg.isFromMe) {
                                _isTyping.value = false
                                chatRepo.markChatRead(chatGuid)
                            }
                        }
                    }
                    is SocketEvent.UpdatedMessage -> {
                        val msg = event.message
                        if (msg.chats?.firstOrNull()?.guid == chatGuid) {
                            messageRepo.handleIncomingSocketMessage(msg)
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
                    is RelayEvent.NewMessage, is RelayEvent.UpdatedMessage -> {}
                }
            }
        }

        refresh()
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
            }
            _isSending.value = false
        }
    }

    fun toggleTapback(messageGuid: String, tapback: TapbackType, currentlyActiveByMe: Boolean) {
        viewModelScope.launch {
            val res = messageRepo.reactToMessage(chatGuid, messageGuid, tapback, remove = currentlyActiveByMe)
            if (res.isFailure) {
                _error.value = "Reaction failed"
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
        val url = msg.attachmentUrl
        if (localFile == null && url.isNullOrBlank()) {
            val attGuid = msg.attachmentGuid
            if (!attGuid.isNullOrBlank()) {
                _error.value = "Downloading audio..."
                viewModelScope.launch {
                    val fetched = relay.getOrRequestAttachment(attGuid)
                    if (fetched != null) {
                        _attachmentRevision.value += 1
                    } else {
                        _error.value = "Audio unavailable"
                    }
                }
            } else {
                _error.value = "Audio unavailable"
            }
            return
        }

        try {
            val player = MediaPlayer().apply {
                if (localFile != null) {
                    setDataSource(localFile.absolutePath)
                } else {
                    setDataSource(getApplication(), Uri.parse(url!!), msg.customHeaders)
                }
                setOnPreparedListener {
                    _playingMessageGuid.value = msg.guid
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
