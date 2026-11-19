package com.wearbubbles.data

import com.wearbubbles.api.ApiClient
import com.wearbubbles.api.dto.MessageDto
import com.wearbubbles.api.dto.MessageQueryRequest
import com.wearbubbles.api.dto.ReactRequest
import com.wearbubbles.api.dto.SendMessageRequest
import com.wearbubbles.api.dto.TapbackType
import com.wearbubbles.api.dto.TapbackUtils
import com.wearbubbles.api.dto.WhereClause
import com.wearbubbles.db.ChatDao
import com.wearbubbles.db.MessageDao
import com.wearbubbles.db.entities.ChatEntity
import com.wearbubbles.db.entities.MessageEntity
import com.wearbubbles.relay.PhoneRelayClient
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.util.UUID

class MessageRepository(
    private val messageDao: MessageDao,
    private val chatDao: ChatDao,
    private val settings: SettingsDataStore,
    private val phoneRelay: PhoneRelayClient? = null
) {

    fun getMessages(chatGuid: String): Flow<List<MessageEntity>> =
        messageDao.getMessagesForChat(chatGuid)

    suspend fun deleteMessage(guid: String) = messageDao.deleteByGuid(guid)

    suspend fun deleteFailedMessages(chatGuid: String) = messageDao.deleteFailedForChat(chatGuid)

    suspend fun deleteMessagesForChat(chatGuid: String) = messageDao.deleteMessagesForChat(chatGuid)

    suspend fun markStalePendingFailed(chatGuid: String, nowMs: Long = System.currentTimeMillis()) {
        messageDao.markStalePendingFailed(chatGuid, nowMs - MessageDao.STALE_PENDING_TIMEOUT_MS)
    }

    suspend fun refreshMessages(chatGuid: String): Result<Unit> {
        if (phoneRelay != null && phoneRelay.refreshPhoneConnected()) {
            if (phoneRelay.requestMessagesSync(chatGuid)) {
                return Result.success(Unit)
            }
        }

        return runCatching {
            val serverUrl = settings.getServerUrl()
            val password = settings.getPassword()
            require(serverUrl.isNotBlank() && password.isNotBlank()) { "Not configured" }

            val api = ApiClient.getApi(serverUrl, settings.getCustomHeaders())
            val response = api.getMessages(
                password,
                MessageQueryRequest(chatGuid = chatGuid, limit = 40, offset = 0, sort = "DESC")
            )
            val messages = response.data ?: emptyList()
            val entities = messages.map { it.toEntity(chatGuid) }
            val staleCutoff = System.currentTimeMillis() - MessageDao.STALE_PENDING_TIMEOUT_MS
            messageDao.upsertAndReconcileBatch(chatGuid, entities, staleCutoff)
        }
    }

    suspend fun loadMoreMessages(chatGuid: String): Result<Boolean> {
        val oldestDate = messageDao.getOldestMessageDate(chatGuid) ?: return Result.success(false)
        if (phoneRelay != null && phoneRelay.refreshPhoneConnected()) {
            phoneRelay.requestMessagesSync(chatGuid, before = oldestDate)
            return Result.success(true)
        }

        return runCatching {
            val serverUrl = settings.getServerUrl()
            val password = settings.getPassword()
            require(serverUrl.isNotBlank() && password.isNotBlank()) { "Not configured" }

            val api = ApiClient.getApi(serverUrl, settings.getCustomHeaders())
            val response = api.getMessages(
                password,
                MessageQueryRequest(
                    chatGuid = chatGuid,
                    limit = 30,
                    offset = 0,
                    sort = "DESC",
                    where = listOf(
                        WhereClause(
                            statement = "message.date_created < :before",
                            args = mapOf("before" to oldestDate)
                        )
                    )
                )
            )
            val messages = response.data ?: emptyList()
            if (messages.isEmpty()) return@runCatching false

            val entities = messages.map { it.toEntity(chatGuid) }
            messageDao.upsertAll(entities)
            messages.size >= 30
        }
    }

    suspend fun sendMessage(chatGuid: String, text: String): Result<MessageEntity> {
        val tempGuid = "temp-${UUID.randomUUID()}"
        val now = System.currentTimeMillis()
        val tempEntity = MessageEntity(
            guid = tempGuid,
            chatGuid = chatGuid,
            text = text,
            isFromMe = true,
            dateCreated = now,
            handleAddress = null
        )
        messageDao.upsert(tempEntity)

        // Primary: Phone Relay when tethered
        if (phoneRelay != null && phoneRelay.refreshPhoneConnected()) {
            val relayRes = phoneRelay.sendMessage(chatGuid, text, tempGuid)
            if (relayRes != null && relayRes.success) {
                val realEntity = relayRes.message?.let {
                    MessageEntity(
                        guid = it.guid,
                        chatGuid = chatGuid,
                        text = it.text ?: text,
                        isFromMe = true,
                        dateCreated = it.dateCreated,
                        handleAddress = it.handleAddress,
                        attachmentGuid = it.attachmentGuid,
                        attachmentMimeType = it.attachmentMimeType,
                        dateDelivered = it.dateDelivered,
                        dateRead = it.dateRead
                    )
                } ?: tempEntity.copy(guid = "sent-$tempGuid")
                messageDao.replaceTempMessage(tempGuid, realEntity)
                updateChatLastMessage(chatGuid, text, realEntity.dateCreated)
                return Result.success(realEntity)
            }
            if (relayRes != null && !relayRes.success) {
                messageDao.markSendFailed(tempGuid)
                return Result.failure(IllegalStateException(relayRes.error ?: "Relay send failed"))
            }
        }

        // Fallback: Direct Server
        return runCatching {
            val serverUrl = settings.getServerUrl()
            val password = settings.getPassword()
            require(serverUrl.isNotBlank() && password.isNotBlank()) { "Not configured" }

            val api = ApiClient.getApi(serverUrl, settings.getCustomHeaders())
            val method = if (settings.isPrivateApiSend()) "private-api" else null
            val response = api.sendMessage(
                password,
                SendMessageRequest(
                    chatGuid = chatGuid,
                    tempGuid = tempGuid,
                    message = text,
                    method = method
                )
            )
            val sentDto = response.data
            val realEntity = sentDto?.toEntity(chatGuid) ?: tempEntity.copy(guid = "sent-$tempGuid")
            messageDao.replaceTempMessage(tempGuid, realEntity)
            updateChatLastMessage(chatGuid, text, realEntity.dateCreated)
            realEntity
        }.onFailure { err ->
            withContext(NonCancellable) {
                messageDao.markSendFailed(tempGuid)
            }
            if (err is CancellationException) throw err
        }
    }

    suspend fun sendVoiceMemo(chatGuid: String, audioFile: File): Result<MessageEntity> {
        val tempGuid = "temp-audio-${UUID.randomUUID()}"
        val now = System.currentTimeMillis()
        val tempEntity = MessageEntity(
            guid = tempGuid,
            chatGuid = chatGuid,
            text = null,
            isFromMe = true,
            dateCreated = now,
            handleAddress = null,
            attachmentGuid = tempGuid,
            attachmentMimeType = "audio/mp4"
        )
        messageDao.upsert(tempEntity)

        if (phoneRelay != null && phoneRelay.refreshPhoneConnected()) {
            val relayRes = phoneRelay.sendAudioFile(chatGuid, tempGuid, audioFile)
            if (relayRes != null && relayRes.success) {
                val realEntity = relayRes.message?.let {
                    MessageEntity(
                        guid = it.guid,
                        chatGuid = chatGuid,
                        text = it.text,
                        isFromMe = true,
                        dateCreated = it.dateCreated,
                        handleAddress = it.handleAddress,
                        attachmentGuid = it.attachmentGuid ?: tempGuid,
                        attachmentMimeType = it.attachmentMimeType ?: "audio/mp4",
                        dateDelivered = it.dateDelivered,
                        dateRead = it.dateRead
                    )
                } ?: tempEntity.copy(guid = "sent-$tempGuid")
                messageDao.replaceTempMessage(tempGuid, realEntity)
                updateChatLastMessage(chatGuid, "Audio Message", realEntity.dateCreated)
                return Result.success(realEntity)
            }
            if (relayRes != null && !relayRes.success) {
                messageDao.markSendFailed(tempGuid)
                return Result.failure(IllegalStateException(relayRes.error ?: "Audio relay failed"))
            }
        }

        return runCatching {
            val serverUrl = settings.getServerUrl()
            val password = settings.getPassword()
            require(serverUrl.isNotBlank() && password.isNotBlank()) { "Not configured" }

            val api = ApiClient.getApi(serverUrl, settings.getCustomHeaders())
            val plain = "text/plain".toMediaType()
            val method = if (settings.isPrivateApiSend()) "private-api" else "apple-script"
            val part = MultipartBody.Part.createFormData(
                "attachment",
                audioFile.name.ifBlank { "Audio Message.m4a" },
                audioFile.asRequestBody("audio/mp4".toMediaType())
            )
            val response = api.sendAttachment(
                password = password,
                chatGuid = chatGuid.toRequestBody(plain),
                tempGuid = tempGuid.toRequestBody(plain),
                name = (audioFile.name.ifBlank { "Audio Message.m4a" }).toRequestBody(plain),
                method = method.toRequestBody(plain),
                isAudioMessage = "true".toRequestBody(plain),
                attachment = part
            )
            val sentDto = response.data
            val realEntity = sentDto?.toEntity(chatGuid) ?: tempEntity.copy(guid = "sent-$tempGuid")
            messageDao.replaceTempMessage(tempGuid, realEntity)
            updateChatLastMessage(chatGuid, "Audio Message", realEntity.dateCreated)
            realEntity
        }.onFailure { err ->
            withContext(NonCancellable) {
                messageDao.markSendFailed(tempGuid)
            }
            if (err is CancellationException) throw err
        }
    }

    suspend fun reactToMessage(
        chatGuid: String,
        messageGuid: String,
        tapback: TapbackType,
        remove: Boolean = false
    ): Result<Unit> {
        val reactionName = if (remove) "-${tapback.apiName}" else tapback.apiName
        val optimisticCode = if (remove) tapback.removeCode else tapback.addCode
        val optimisticEntity = MessageEntity(
            guid = "temp-react-${UUID.randomUUID()}",
            chatGuid = chatGuid,
            text = null,
            isFromMe = true,
            dateCreated = System.currentTimeMillis(),
            handleAddress = null,
            associatedMessageGuid = "p:0/$messageGuid",
            associatedMessageType = optimisticCode
        )
        messageDao.upsert(optimisticEntity)

        if (phoneRelay != null && phoneRelay.refreshPhoneConnected()) {
            val res = phoneRelay.sendReaction(chatGuid, messageGuid, reactionName)
            if (res != null && res.success) return Result.success(Unit)
            if (res != null && !res.success) {
                messageDao.deleteByGuid(optimisticEntity.guid)
                return Result.failure(IllegalStateException(res.error ?: "Reaction failed"))
            }
        }

        return runCatching {
            val serverUrl = settings.getServerUrl()
            val password = settings.getPassword()
            require(serverUrl.isNotBlank() && password.isNotBlank()) { "Not configured" }

            val api = ApiClient.getApi(serverUrl, settings.getCustomHeaders())
            api.reactToMessage(
                password,
                ReactRequest(
                    chatGuid = chatGuid,
                    selectedMessageGuid = messageGuid,
                    reaction = reactionName
                )
            )
            Unit
        }.onFailure {
            messageDao.deleteByGuid(optimisticEntity.guid)
        }
    }

    suspend fun handleIncomingSocketMessage(dto: MessageDto) {
        val chatGuid = dto.chats?.firstOrNull()?.guid ?: return
        val entity = dto.toEntity(chatGuid)
        messageDao.upsertAndReconcile(entity, tempGuid = dto.tempGuid)

        val existingChat = chatDao.getChat(chatGuid)
        val firstAttachment = dto.attachments?.firstOrNull()
        val displayText = if (TapbackUtils.isTapbackCode(dto.associatedMessageType)) {
            val reactionName = TapbackType.fromAddCode(dto.associatedMessageType)?.label ?: "Reacted"
            "$reactionName to a message"
        } else {
            dto.text?.takeIf { it.isNotBlank() } ?: firstAttachment?.let {
                when {
                    it.mimeType?.startsWith("image/") == true -> "Image"
                    it.mimeType?.startsWith("video/") == true -> "Video"
                    it.mimeType?.startsWith("audio/") == true -> "Audio Message"
                    else -> "Attachment"
                }
            }
        }

        if (existingChat != null) {
            chatDao.upsert(
                existingChat.copy(
                    lastMessageText = displayText ?: existingChat.lastMessageText,
                    lastMessageDate = dto.dateCreated,
                    lastMessageIsFromMe = dto.isFromMe,
                    hasUnreadMessage = !dto.isFromMe,
                    lastMessageAttachmentGuid = firstAttachment?.guid,
                    lastMessageAttachmentMimeType = firstAttachment?.mimeType
                )
            )
        } else {
            val identifier = chatGuid.substringAfterLast(";").ifBlank { chatGuid }
            chatDao.upsert(
                ChatEntity(
                    guid = chatGuid,
                    chatIdentifier = identifier,
                    displayName = null,
                    participantAddresses = dto.handle?.address ?: identifier,
                    lastMessageText = displayText,
                    lastMessageDate = dto.dateCreated,
                    lastMessageIsFromMe = dto.isFromMe,
                    hasUnreadMessage = !dto.isFromMe,
                    lastMessageAttachmentGuid = firstAttachment?.guid,
                    lastMessageAttachmentMimeType = firstAttachment?.mimeType
                )
            )
        }
    }

    private suspend fun updateChatLastMessage(chatGuid: String, text: String, date: Long) {
        val existingChat = chatDao.getChat(chatGuid) ?: return
        chatDao.upsert(
            existingChat.copy(
                lastMessageText = text,
                lastMessageDate = date,
                lastMessageIsFromMe = true,
                hasUnreadMessage = false
            )
        )
    }

    private fun MessageDto.toEntity(chatGuid: String): MessageEntity {
        val firstAttachment = attachments?.firstOrNull()
        return MessageEntity(
            guid = guid,
            chatGuid = chatGuid,
            text = text,
            isFromMe = isFromMe,
            dateCreated = dateCreated,
            handleAddress = handle?.address,
            attachmentGuid = firstAttachment?.guid,
            attachmentMimeType = firstAttachment?.mimeType,
            associatedMessageGuid = associatedMessageGuid,
            associatedMessageType = associatedMessageType,
            dateDelivered = dateDelivered,
            dateRead = dateRead
        )
    }
}
