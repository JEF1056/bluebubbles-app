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
import com.wearbubbles.db.AppDatabase
import com.wearbubbles.db.entities.ChatEntity
import com.wearbubbles.service.MessageListenerService
import com.wearbubbles.socket.SocketEvent
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

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

    init {
        viewModelScope.launch {
            contactRepo.loadFromDb()
            combine(
                chatRepo.getChats(),
                contactRepo.getContactsFlow()
            ) { entities, _ -> entities }.collect { entities ->
                _chats.value = entities.map { it.toUi() }
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
                    MessageListenerService.start(application)
                }
            } else {
                MessageListenerService.stop(application)
            }
            refresh()
            checkUpdates()
            if (!phoneConnected) {
                prefetchRecentImages()
            }
        }

        viewModelScope.launch {
            app.socketManager.events.collect { event ->
                when (event) {
                    is SocketEvent.NewMessage -> {
                        messageRepo.handleIncomingSocketMessage(event.message)
                    }
                    is SocketEvent.UpdatedMessage -> {
                        messageRepo.handleIncomingSocketMessage(event.message)
                    }
                    is SocketEvent.PinnedChatsUpdated -> {
                        chatRepo.updatePinnedOrder(event.pinnedChatGuids)
                    }
                    else -> {}
                }
            }
        }
    }

    fun refresh() {
        viewModelScope.launch {
            _isRefreshing.value = true
            _error.value = null
            try {
                contactRepo.refreshContacts()
                chatRepo.refreshChats()
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
        viewModelScope.launch {
            try {
                val url = settings.getServerUrl()
                val pass = settings.getPassword()
                val headers = settings.getCustomHeaders()
                if (url.isBlank() || pass.isBlank()) return@launch
                val recent = db.messageDao().getRecentImageMessages(15)
                val loader = coil.ImageLoader(getApplication())
                val normalized = url.trimEnd('/')
                for (msg in recent) {
                    val attGuid = msg.attachmentGuid ?: continue
                    val reqBuilder = coil.request.ImageRequest.Builder(getApplication())
                        .data("$normalized/api/v1/attachment/$attGuid/download?password=$pass")
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
