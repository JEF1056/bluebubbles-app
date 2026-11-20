package com.wearbubbles.data

import com.wearbubbles.api.ApiClient
import com.wearbubbles.api.dto.ChatDto
import com.wearbubbles.api.dto.ChatQueryRequest
import com.wearbubbles.db.ChatDao
import com.wearbubbles.db.entities.ChatEntity
import com.wearbubbles.relay.PhoneRelayClient
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow

class ChatRepository(
    private val chatDao: ChatDao,
    private val settings: SettingsDataStore,
    private val phoneRelay: PhoneRelayClient? = null
) {

    fun getChats(): Flow<List<ChatEntity>> = chatDao.getAllChats()

    suspend fun refreshChats(): Result<Unit> {
        // Primary: Phone Relay when tethered
        if (phoneRelay != null && phoneRelay.refreshPhoneConnected()) {
            if (phoneRelay.requestChatsSyncAwait()) {
                return Result.success(Unit)
            }
        }

        // Fallback: Direct Server
        return runCatching {
            val serverUrl = settings.getServerUrl()
            val password = settings.getPassword()
            require(serverUrl.isNotBlank() && password.isNotBlank()) { "Not configured" }

            val api = ApiClient.getApi(serverUrl, settings.getCustomHeaders())
            val pinnedGuids: List<String>? = runCatching {
                api.getPinnedChats(password).data?.pinnedChatGuids
            }.getOrNull()
            val response = api.getChats(password, ChatQueryRequest(limit = 30, offset = 0))
            val recentChats = response.data ?: emptyList()

            val seenGuids = recentChats.map { it.guid }.toHashSet()
            val extraPinned = if (pinnedGuids != null) {
                val missingGuids = pinnedGuids.filter { it !in seenGuids }
                if (missingGuids.isNotEmpty()) {
                    coroutineScope {
                        missingGuids.map { guid ->
                            async { runCatching { api.getChat(guid, password).data }.getOrNull() }
                        }.awaitAll().filterNotNull()
                    }
                } else {
                    emptyList()
                }
            } else {
                emptyList()
            }

            val pinIndexByGuid = pinnedGuids?.withIndex()?.associate { it.value to it.index }
            val entities = (recentChats + extraPinned)
                .filter { it.isArchived != true && it.dateDeleted == null }
                .map { dto ->
                    val resolvedPinIndex = if (pinIndexByGuid != null) pinIndexByGuid[dto.guid] else dto.pinIndex
                    val resolvedPinned = if (pinIndexByGuid != null) resolvedPinIndex != null else (dto.isPinned == true)
                    dto.toEntity(isPinned = resolvedPinned, pinIndex = resolvedPinIndex)
                }
            val hasPinMetadata = pinnedGuids != null
            chatDao.replaceAndPrune(entities, preservePins = !hasPinMetadata)
        }
    }

    companion object {
        internal fun shouldSendStandaloneReadReceipt(privateMarkChatAsRead: Boolean): Boolean =
            privateMarkChatAsRead
    }

    suspend fun markChatRead(chatGuid: String) {
        chatDao.markRead(chatGuid)
        if (phoneRelay != null && phoneRelay.refreshPhoneConnected()) {
            phoneRelay.sendMarkReadAwait(chatGuid)
            return
        }
        if (!shouldSendStandaloneReadReceipt(settings.isPrivateMarkChatAsRead())) return
        try {
            val serverUrl = settings.getServerUrl()
            val password = settings.getPassword()
            if (serverUrl.isNotBlank() && password.isNotBlank()) {
                val api = ApiClient.getApi(serverUrl, settings.getCustomHeaders())
                api.markChatRead(chatGuid, password)
            }
        } catch (_: Exception) {
        }
    }

    suspend fun updatePinnedOrder(pinnedGuids: List<String>) {
        chatDao.updatePinnedOrder(pinnedGuids)
    }

    suspend fun deleteLocalChat(chatGuid: String) {
        chatDao.deleteChat(chatGuid)
    }

    private fun ChatDto.toEntity(
        isPinned: Boolean = this.isPinned == true,
        pinIndex: Int? = this.pinIndex
    ): ChatEntity {
        val addresses = participants?.mapNotNull { it.address }?.joinToString(",") ?: ""
        val firstAttachment = lastMessage?.attachments?.firstOrNull()
        val lastText = lastMessage?.text?.takeIf { it.isNotBlank() }
            ?: firstAttachment?.let {
                when {
                    it.mimeType?.startsWith("image/") == true -> "Image"
                    it.mimeType?.startsWith("video/") == true -> "Video"
                    it.mimeType?.startsWith("audio/") == true -> "Audio Message"
                    else -> "Attachment"
                }
            }

        return ChatEntity(
            guid = guid,
            chatIdentifier = chatIdentifier ?: guid.substringAfterLast(";").ifBlank { guid },
            displayName = displayName?.takeIf { it.isNotBlank() },
            participantAddresses = addresses,
            lastMessageText = lastText,
            lastMessageDate = lastMessage?.dateCreated ?: 0L,
            lastMessageIsFromMe = lastMessage?.isFromMe ?: false,
            hasUnreadMessage = hasUnreadMessage ?: false,
            lastMessageAttachmentGuid = firstAttachment?.guid,
            lastMessageAttachmentMimeType = firstAttachment?.mimeType,
            isPinned = isPinned,
            pinIndex = pinIndex
        )
    }
}
