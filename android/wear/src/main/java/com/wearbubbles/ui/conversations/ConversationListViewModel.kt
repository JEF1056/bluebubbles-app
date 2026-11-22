package com.wearbubbles.ui.conversations

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.wearbubbles.WearBubblesApp
import com.wearbubbles.data.ChatRepository
import com.wearbubbles.data.ContactRepository
import com.wearbubbles.data.MessageRepository
import com.wearbubbles.data.SettingsDataStore
import com.wearbubbles.data.UpdateChecker
import com.wearbubbles.data.shouldRefreshOnResume
import com.wearbubbles.db.AppDatabase
import com.wearbubbles.db.entities.ChatEntity
import com.wearbubbles.service.MessageListenerService
import com.wearbubbles.worker.MessageSyncWorker
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class ChatItemUi(
    val guid: String,
    val title: String,
    val subtitle: String,
    val timeText: String,
    val hasUnread: Boolean,
    val isGroup: Boolean,
    val avatarPath: String? = null,
    val isPinned: Boolean = false
)

class ConversationListViewModel(application: Application) : AndroidViewModel(application) {

    private val db = AppDatabase.getInstance(application)
    private val settings = SettingsDataStore(application)
    private val app = application as WearBubblesApp
    private val relay = app.phoneRelayClient
    private val contactRepo = ContactRepository(application, db.contactDao(), settings, relay)
    private val chatRepo = ChatRepository(db.chatDao(), settings, relay)
    private val messageRepo = MessageRepository(db.messageDao(), db.chatDao(), settings, relay)

    private val _chats = MutableStateFlow<List<ChatItemUi>>(emptyList())
    val chats: StateFlow<List<ChatItemUi>> = _chats.asStateFlow()

    private val _isRefreshing = MutableStateFlow(false)
    val isRefreshing: StateFlow<Boolean> = _isRefreshing.asStateFlow()

    private val _isPhoneRelay = MutableStateFlow(false)
    val isPhoneRelay: StateFlow<Boolean> = _isPhoneRelay.asStateFlow()

    private val _updateVersion = MutableStateFlow<String?>(null)
    val updateVersion: StateFlow<String?> = _updateVersion.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private var lastRefreshStartedAtMs = 0L
    private var wasPaused = false

    init {
        viewModelScope.launch {
            withContext(Dispatchers.IO) { contactRepo.loadFromDb() }
            combine(
                chatRepo.getChats(),
                contactRepo.getContactsFlow()
            ) { entities, _ -> entities }
                .map { entities -> entities.map { it.toUi() } }
                .flowOn(Dispatchers.IO)
                .collect { uiItems ->
                    _chats.value = uiItems
                }
        }

        viewModelScope.launch {
            relay.isPhoneConnected.collect { phone ->
                _isPhoneRelay.value = phone
            }
        }

        viewModelScope.launch {
            val phoneConnected = relay.refreshPhoneConnected()
            _isPhoneRelay.value = phoneConnected
            if (!phoneConnected) {
                val configured = settings.isConfigured.first()
                if (configured) {
                    MessageSyncWorker.schedule(application)
                    MessageListenerService.start(application)
                } else {
                    MessageSyncWorker.cancel(application)
                }
            } else {
                MessageSyncWorker.cancel(application)
                MessageListenerService.stop(application)
            }
            refresh()
            if (!phoneConnected) {
                checkUpdates()
                prefetchRecentImages()
            }
        }
    }

    fun onScreenPaused() {
        wasPaused = true
    }

    fun onScreenResumed() {
        val nowMs = System.currentTimeMillis()
        if (shouldRefreshOnResume(_isRefreshing.value, wasPaused, lastRefreshStartedAtMs, nowMs)) {
            wasPaused = false
            refresh()
        } else {
            wasPaused = false
        }
    }

    fun refresh() {
        if (_isRefreshing.value) return
        viewModelScope.launch {
            lastRefreshStartedAtMs = System.currentTimeMillis()
            _isRefreshing.value = true
            _error.value = null
            try {
                // Refresh contacts in parallel without holding the chat-list sync indicator open.
                viewModelScope.launch { runCatching { contactRepo.refreshContacts() } }
                val chatResult = chatRepo.refreshChats()
                chatResult.exceptionOrNull()?.let { err ->
                    if (_chats.value.isEmpty()) {
                        _error.value = err.localizedMessage?.take(50) ?: "Refresh failed"
                    }
                }
            } catch (e: Exception) {
                _error.value = e.localizedMessage?.take(50) ?: "Refresh failed"
            } finally {
                _isRefreshing.value = false
            }
        }
    }

    fun deleteChat(guid: String) {
        viewModelScope.launch {
            chatRepo.deleteLocalChat(guid)
            messageRepo.deleteMessagesForChat(guid)
        }
    }

    fun dismissUpdate() {
        val ver = _updateVersion.value ?: return
        _updateVersion.value = null
        viewModelScope.launch {
            settings.setDismissedUpdateVersion(ver)
        }
    }

    private fun checkUpdates() {
        viewModelScope.launch {
            val latest = UpdateChecker.checkForUpdate(settings)
            if (latest != null) {
                _updateVersion.value = latest.versionName
            }
        }
    }

    private fun prefetchRecentImages() {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val url = settings.getServerUrl()
                val pass = settings.getPassword()
                val headers = settings.getCustomHeaders()
                if (url.isBlank() || pass.isBlank()) return@launch
                val recent = db.messageDao().getRecentImageMessages(5)
                val loader = coil.Coil.imageLoader(getApplication())
                for (msg in recent) {
                    val attGuid = msg.attachmentGuid ?: continue
                    val reqBuilder = coil.request.ImageRequest.Builder(getApplication())
                        .data(com.wearbubbles.api.ApiClient.getAttachmentUrl(url, pass, attGuid, msg.attachmentMimeType))
                        .size(250, 250)
                    headers.forEach { (k, v) -> reqBuilder.addHeader(k, v) }
                    loader.enqueue(reqBuilder.build())
                }
            } catch (_: Exception) {
            }
        }
    }

    private fun ChatEntity.toUi(): ChatItemUi {
        val title = contactRepo.resolveChatTitle(displayName, chatIdentifier, participantAddresses)
        val avatar = contactRepo.resolveAvatarForChat(guid, participantAddresses)
        val preview = lastMessageText ?: ""
        val subtitle = if (lastMessageIsFromMe && preview.isNotBlank()) "You: $preview" else preview
        return ChatItemUi(
            guid = guid,
            title = title,
            subtitle = subtitle,
            timeText = formatTimestamp(lastMessageDate),
            hasUnread = hasUnreadMessage,
            isGroup = isGroup,
            avatarPath = avatar,
            isPinned = isPinned
        )
    }

    private fun formatTimestamp(epochMs: Long): String {
        if (epochMs <= 0L) return ""
        val now = System.currentTimeMillis()
        val diff = now - epochMs
        return when {
            diff < 60_000 -> "now"
            diff < 3_600_000 -> "${diff / 60_000}m"
            diff < 86_400_000 -> "${diff / 3_600_000}h"
            diff < 604_800_000 -> "${diff / 86_400_000}d"
            else -> "${diff / 604_800_000}w"
        }
    }
}
