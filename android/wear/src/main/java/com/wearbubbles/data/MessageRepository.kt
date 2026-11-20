package com.wearbubbles.data

import com.wearbubbles.api.ApiClient
import com.wearbubbles.api.dto.CreateChatRequest
import com.wearbubbles.api.dto.MessageDto
import com.wearbubbles.api.dto.MessageQueryRequest
import com.wearbubbles.api.dto.MessageRelayDto
import com.wearbubbles.api.dto.ReactRequest
import com.wearbubbles.api.dto.SendMessageRequest
import com.wearbubbles.api.dto.TapbackType
import com.wearbubbles.api.dto.TapbackUtils
import com.wearbubbles.api.dto.WhereClause
import com.wearbubbles.db.ChatDao
import com.wearbubbles.db.MessageDao
import com.wearbubbles.db.entities.ChatEntity
import com.wearbubbles.db.entities.MessageEntity
import com.wearbubbles.notifications.NotificationHelper
import com.wearbubbles.relay.PhoneRelayClient
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import retrofit2.HttpException
import java.io.File
import java.util.UUID

sealed class NotificationReplyResult {
    data class Sent(val message: MessageEntity) : NotificationReplyResult()
    data class AcceptedPending(val tempGuid: String) : NotificationReplyResult()
    data class Failed(val error: String?) : NotificationReplyResult()
    data class NeedsStandaloneWorker(val tempGuid: String? = null) : NotificationReplyResult()
}

internal fun shouldRefreshOnResume(
    isCurrentlyRefreshing: Boolean,
    wasPaused: Boolean,
    lastRefreshStartedAtMs: Long,
    nowMs: Long,
    minIntervalMs: Long = 3_000L
): Boolean {
    if (isCurrentlyRefreshing) return false
    if (wasPaused) return true
    if (lastRefreshStartedAtMs <= 0L) return false
    return (nowMs - lastRefreshStartedAtMs) >= minIntervalMs
}

internal suspend fun persistOptimisticOutgoing(
    messageDao: MessageDao,
    chatDao: ChatDao,
    chatGuid: String,
    text: String,
    dateCreated: Long = System.currentTimeMillis(),
    existingTempGuid: String? = null
): MessageEntity {
    val tempGuid = existingTempGuid?.takeIf { it.isNotBlank() } ?: "temp-${UUID.randomUUID()}"
    val tempEntity = MessageEntity(
        guid = tempGuid,
        chatGuid = chatGuid,
        text = text,
        isFromMe = true,
        dateCreated = dateCreated,
        handleAddress = null
    )
    messageDao.upsert(tempEntity)
    val identifier = chatGuid.substringAfterLast(";").ifBlank { chatGuid }
    chatDao.updateOutgoingLastMessage(
        chatGuid = chatGuid,
        defaultIdentifier = identifier,
        text = text,
        date = dateCreated
    )
    return tempEntity
}

class MessageRepository(
    private val messageDao: MessageDao,
    private val chatDao: ChatDao,
    private val settings: SettingsDataStore,
    private val phoneRelay: PhoneRelayClient? = null
) {

    companion object {
        internal const val NOTIFICATION_REPLY_WAIT_MS = 5_000L
        internal const val NOTIFICATION_REPLY_CEILING_MS = 8_000L

        internal fun hasMoreRelayedMessages(receivedCount: Int): Boolean =
            receivedCount < 0 || receivedCount >= 40

        internal fun extractDmRecipientIfNewChatError(
            chatGuid: String,
            httpCode: Int,
            responseBody: String?
        ): String? {
            val idx = chatGuid.indexOf(";-;")
            if (idx < 0) return null
            val recipient = chatGuid.substring(idx + 3).trim()
            if (recipient.isBlank()) return null
            val isNotFound = httpCode == 404
            val isDoesNotExist = (httpCode == 400 || httpCode == 500) &&
                responseBody?.contains("does not exist", ignoreCase = true) == true
            return if (isNotFound || isDoesNotExist) recipient else null
        }
    }

    fun getMessages(chatGuid: String): Flow<List<MessageEntity>> =
        messageDao.getMessagesForChat(chatGuid)

    suspend fun deleteMessage(guid: String) = messageDao.deleteByGuid(guid)

    suspend fun deleteFailedMessages(chatGuid: String) = messageDao.deleteFailedForChat(chatGuid)

    suspend fun deleteMessagesForChat(chatGuid: String) = messageDao.deleteMessagesForChat(chatGuid)

    suspend fun markStalePendingFailed(chatGuid: String, nowMs: Long = System.currentTimeMillis()) {
        messageDao.markStalePendingFailed(chatGuid, nowMs - MessageDao.STALE_PENDING_TIMEOUT_MS)
    }

    private suspend fun requireApi(): Pair<com.wearbubbles.api.BlueBubblesApi, String> {
        val serverUrl = settings.getServerUrl()
        val password = settings.getPassword()
        require(serverUrl.isNotBlank() && password.isNotBlank()) { "Not configured" }
        return ApiClient.getApi(serverUrl, settings.getCustomHeaders()) to password
    }

    suspend fun refreshMessages(chatGuid: String): Result<Unit> {
        if (phoneRelay != null && phoneRelay.refreshPhoneConnected()) {
            if (phoneRelay.requestMessagesSyncAwait(chatGuid) != null) {
                return Result.success(Unit)
            }
        }

        return runCatching {
            val (api, password) = requireApi()
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
            val count = phoneRelay.requestMessagesSyncAwait(chatGuid, before = oldestDate)
            if (count != null) {
                return Result.success(hasMoreRelayedMessages(count))
            }
        }

        return runCatching {
            val (api, password) = requireApi()
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

    suspend fun sendNotificationReply(
        chatGuid: String,
        text: String,
        senderName: String?
    ): NotificationReplyResult {
        // Persist optimistic message and chat preview before relay/worker handoff so opening the
        // watch app right after replying immediately renders the reply and clears unread state.
        val tempEntity = persistOptimisticOutgoing(messageDao, chatDao, chatGuid, text)
        val tempGuid = tempEntity.guid

        if (phoneRelay == null || !phoneRelay.refreshPhoneConnected()) {
            return NotificationReplyResult.NeedsStandaloneWorker(tempGuid)
        }

        phoneRelay.registerPendingReply(tempGuid, chatGuid, senderName, text)

        val relayRes = phoneRelay.sendMessage(
            chatGuid = chatGuid,
            text = text,
            tempGuid = tempGuid,
            timeoutMs = NOTIFICATION_REPLY_WAIT_MS,
            totalCeilingMs = NOTIFICATION_REPLY_CEILING_MS
        )
        if (relayRes == null) {
            phoneRelay.clearPendingReply(tempGuid)
            return NotificationReplyResult.NeedsStandaloneWorker(tempGuid)
        }
        if (relayRes.success) {
            phoneRelay.clearPendingReply(tempGuid)
            val realEntity = relayRes.message?.toEntity(chatGuid)
                ?: tempEntity.copy(guid = "sent-$tempGuid")
            messageDao.replaceTempMessage(tempGuid, realEntity)
            updateChatLastMessage(realEntity.chatGuid, text, realEntity.dateCreated)
            return NotificationReplyResult.Sent(realEntity)
        }
        if (relayRes.timedOut) {
            return NotificationReplyResult.AcceptedPending(tempGuid)
        }
        phoneRelay.clearPendingReply(tempGuid)
        messageDao.markSendFailed(tempGuid)
        return NotificationReplyResult.Failed(relayRes.error ?: "Relay send failed")
    }

    suspend fun sendMessage(
        chatGuid: String,
        text: String,
        existingTempGuid: String? = null
    ): Result<MessageEntity> {
        val tempEntity = persistOptimisticOutgoing(
            messageDao = messageDao,
            chatDao = chatDao,
            chatGuid = chatGuid,
            text = text,
            existingTempGuid = existingTempGuid
        )
        val tempGuid = tempEntity.guid
        val now = tempEntity.dateCreated

        // Primary: Phone Relay when tethered
        if (phoneRelay != null && phoneRelay.refreshPhoneConnected()) {
            val relayRes = phoneRelay.sendMessage(chatGuid, text, tempGuid)
            if (relayRes != null && relayRes.success) {
                val realEntity = relayRes.message?.toEntity(chatGuid)
                    ?: tempEntity.copy(guid = "sent-$tempGuid")
                messageDao.replaceTempMessage(tempGuid, realEntity)
                if (realEntity.chatGuid != chatGuid && messageDao.countForChat(chatGuid) == 0) {
                    chatDao.deleteChat(chatGuid)
                }
                updateChatLastMessage(realEntity.chatGuid, text, realEntity.dateCreated)
                return Result.success(realEntity)
            }
            if (relayRes != null && relayRes.timedOut) {
                return Result.success(tempEntity)
            }
            if (relayRes != null && !relayRes.success) {
                messageDao.markSendFailed(tempGuid)
                return Result.failure(IllegalStateException(relayRes.error ?: "Relay send failed"))
            }
        }

        // Fallback: Direct Server
        return runCatching {
            val (api, password) = requireApi()
            val method = if (settings.isPrivateApiSend()) "private-api" else null
            var targetChatGuid = chatGuid
            val sentDto = try {
                api.sendMessage(
                    password,
                    SendMessageRequest(
                        chatGuid = chatGuid,
                        tempGuid = tempGuid,
                        message = text,
                        method = method
                    )
                ).data
            } catch (httpErr: HttpException) {
                val errorBody = httpErr.response()?.errorBody()?.string()
                val recipient = extractDmRecipientIfNewChatError(chatGuid, httpErr.code(), errorBody)
                    ?: throw httpErr
                val newChatMethod = if (settings.isPrivateApiSend()) "private-api" else "apple-script"
                val createdChat = api.createChat(
                    password,
                    CreateChatRequest(
                        addresses = listOf(recipient),
                        message = text,
                        tempGuid = tempGuid,
                        method = newChatMethod
                    )
                ).data
                val resolvedGuid = createdChat?.guid?.takeIf { it.isNotBlank() } ?: chatGuid
                targetChatGuid = resolvedGuid
                val firstMsg = createdChat?.messages?.firstOrNull() ?: createdChat?.lastMessage
                val firstAttachment = firstMsg?.attachments?.firstOrNull()
                val addresses = createdChat?.participants?.mapNotNull { it.address }
                    ?.joinToString(",")?.takeIf { it.isNotBlank() } ?: recipient
                chatDao.upsert(
                    ChatEntity(
                        guid = resolvedGuid,
                        chatIdentifier = createdChat?.chatIdentifier ?: recipient,
                        displayName = createdChat?.displayName?.takeIf { it.isNotBlank() },
                        participantAddresses = addresses,
                        lastMessageText = text,
                        lastMessageDate = firstMsg?.dateCreated ?: now,
                        lastMessageIsFromMe = true,
                        hasUnreadMessage = false,
                        lastMessageAttachmentGuid = firstAttachment?.guid,
                        lastMessageAttachmentMimeType = firstAttachment?.mimeType,
                        isPinned = createdChat?.isPinned == true,
                        pinIndex = createdChat?.pinIndex
                    )
                )
                firstMsg
            }
            val realEntity = sentDto?.toEntity(targetChatGuid)
                ?: tempEntity.copy(guid = "sent-$tempGuid", chatGuid = targetChatGuid)
            messageDao.replaceTempMessage(tempGuid, realEntity)
            if (targetChatGuid != chatGuid && messageDao.countForChat(chatGuid) == 0) {
                chatDao.deleteChat(chatGuid)
            }
            updateChatLastMessage(targetChatGuid, text, realEntity.dateCreated)
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
            if (relayRes != null && relayRes.timedOut) {
                updateChatLastMessage(chatGuid, "Audio Message", now)
                return Result.success(tempEntity)
            }
            if (relayRes != null && !relayRes.success) {
                messageDao.markSendFailed(tempGuid)
                return Result.failure(IllegalStateException(relayRes.error ?: "Audio relay failed"))
            }
        }

        return runCatching {
            val (api, password) = requireApi()
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
            val res = phoneRelay.sendReaction(
                chatGuid = chatGuid,
                selectedMessageGuid = messageGuid,
                reaction = reactionName,
                tempGuid = optimisticEntity.guid
            )
            if (res != null && res.success) {
                val realEntity = res.message?.toEntity(chatGuid)
                if (realEntity != null) {
                    messageDao.replaceTempMessage(optimisticEntity.guid, realEntity)
                } else {
                    messageDao.deleteByGuid(optimisticEntity.guid)
                }
                return Result.success(Unit)
            }
            if (res != null && !res.success) {
                messageDao.deleteByGuid(optimisticEntity.guid)
                return Result.failure(IllegalStateException(res.error ?: "Reaction failed"))
            }
        }

        return runCatching {
            val (api, password) = requireApi()
            val response = api.reactToMessage(
                password,
                ReactRequest(
                    chatGuid = chatGuid,
                    selectedMessageGuid = messageGuid,
                    reaction = reactionName
                )
            )
            val realEntity = response.data?.toEntity(chatGuid)
            if (realEntity != null) {
                messageDao.replaceTempMessage(optimisticEntity.guid, realEntity)
            } else {
                messageDao.deleteByGuid(optimisticEntity.guid)
            }
        }.onFailure { err ->
            withContext(NonCancellable) {
                messageDao.deleteByGuid(optimisticEntity.guid)
            }
            if (err is CancellationException) throw err
        }
    }

    suspend fun handleMessageSendError(dto: MessageDto) {
        val candidates = listOfNotNull(
            dto.tempGuid?.takeIf { it.isNotBlank() },
            dto.tempGuid?.takeIf { it.isNotBlank() }?.let { "sent-$it" },
            dto.guid.takeIf { it.isNotBlank() }
        ).distinct()
        if (candidates.isEmpty()) return
        messageDao.markSendFailedFirstMatch(candidates)
    }

    suspend fun handleIncomingSocketMessage(dto: MessageDto, isUpdate: Boolean = false) {
        val chatGuid = dto.chats?.firstOrNull()?.guid ?: return
        val entity = dto.toEntity(chatGuid)
        messageDao.upsertAndReconcile(entity, tempGuid = dto.tempGuid)
        if (isUpdate) return

        val firstAttachment = dto.attachments?.firstOrNull()
        val displayText = if (TapbackUtils.isTapbackCode(dto.associatedMessageType)) {
            val tapback = TapbackType.fromAddCode(dto.associatedMessageType)
            val reactionName = if (tapback == TapbackType.EMOJI && !dto.associatedMessageEmoji.isNullOrBlank()) {
                "Reacted ${dto.associatedMessageEmoji}"
            } else {
                tapback?.label ?: "Reacted"
            }
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
        val unread = !dto.isFromMe && NotificationHelper.activeChatGuid.value != chatGuid
        val identifier = chatGuid.substringAfterLast(";").ifBlank { chatGuid }
        chatDao.upsertChatFromIncomingMessage(
            chatGuid = chatGuid,
            defaultIdentifier = identifier,
            defaultParticipantAddresses = dto.handle?.address ?: identifier,
            lastMessageText = displayText,
            lastMessageDate = dto.dateCreated,
            lastMessageIsFromMe = dto.isFromMe,
            hasUnreadMessage = unread,
            lastMessageAttachmentGuid = firstAttachment?.guid,
            lastMessageAttachmentMimeType = firstAttachment?.mimeType
        )
    }

    private suspend fun updateChatLastMessage(chatGuid: String, text: String, date: Long) {
        val identifier = chatGuid.substringAfterLast(";").ifBlank { chatGuid }
        chatDao.updateOutgoingLastMessage(
            chatGuid = chatGuid,
            defaultIdentifier = identifier,
            text = text,
            date = date
        )
    }

    private fun MessageRelayDto.toEntity(fallbackChatGuid: String) = MessageEntity(
        guid = guid,
        chatGuid = chatGuid.ifBlank { fallbackChatGuid },
        text = text,
        isFromMe = isFromMe,
        dateCreated = dateCreated,
        handleAddress = handleAddress,
        attachmentGuid = attachmentGuid,
        attachmentMimeType = attachmentMimeType,
        associatedMessageGuid = associatedMessageGuid,
        associatedMessageType = associatedMessageType,
        associatedMessageEmoji = associatedMessageEmoji,
        dateDelivered = dateDelivered,
        dateRead = dateRead
    )

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
            associatedMessageEmoji = associatedMessageEmoji,
            dateDelivered = dateDelivered,
            dateRead = dateRead
        )
    }
}
