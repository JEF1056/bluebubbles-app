package com.wearbubbles.relay

import android.content.Context
import android.util.Log
import com.google.android.gms.wearable.Asset
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.Wearable
import com.google.gson.Gson
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.google.gson.reflect.TypeToken
import com.wearbubbles.api.ApiClient
import com.wearbubbles.api.dto.ChatRelayDto
import com.wearbubbles.api.dto.ContactRelayDto
import com.wearbubbles.api.dto.MessageRelayDto
import com.wearbubbles.data.SettingsDataStore
import com.wearbubbles.db.AppDatabase
import com.wearbubbles.db.MessageDao
import com.wearbubbles.db.entities.ChatEntity
import com.wearbubbles.db.entities.ContactEntity
import com.wearbubbles.db.entities.MessageEntity
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.net.URLEncoder
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

data class SendResultPayload(
    val requestId: String,
    val tempGuid: String? = null,
    val success: Boolean = false,
    val error: String? = null,
    val message: MessageRelayDto? = null
)

sealed class RelayEvent {
    data class NewMessage(val message: MessageEntity) : RelayEvent()
    data class UpdatedMessage(val message: MessageEntity) : RelayEvent()
    data class TypingIndicator(val chatGuid: String, val isTyping: Boolean) : RelayEvent()
    data class AttachmentDownloaded(val attachmentGuid: String, val file: File) : RelayEvent()
}

class PhoneRelayClient(private val context: Context) {

    companion object {
        private const val TAG = "PhoneRelayClient"
        const val PHONE_CAPABILITY = "bluebubbles_phone_app"
        internal const val SEND_TIMEOUT_MS = 130_000L

        internal fun orTimedOutResult(
            result: SendResultPayload?,
            requestId: String,
            tempGuid: String
        ): SendResultPayload = result ?: SendResultPayload(
            requestId = requestId,
            tempGuid = tempGuid,
            success = false,
            error = "Phone relay timed out"
        )

        internal suspend fun reconcileOrphanedSendResult(
            result: SendResultPayload,
            messageDao: MessageDao
        ) {
            val tempGuid = result.tempGuid?.takeIf { it.isNotBlank() } ?: return
            if (result.success) {
                val realEntity = result.message?.toEntity()
                if (realEntity != null) {
                    messageDao.replaceTempMessage(tempGuid, realEntity)
                } else {
                    messageDao.deleteByGuid(tempGuid)
                }
            } else {
                messageDao.markSendFailed(tempGuid)
            }
        }

        internal fun MessageRelayDto.toEntity() = MessageEntity(
            guid = guid,
            chatGuid = chatGuid,
            text = text,
            isFromMe = isFromMe,
            dateCreated = dateCreated,
            handleAddress = handleAddress,
            attachmentGuid = attachmentGuid,
            attachmentMimeType = attachmentMimeType,
            associatedMessageGuid = associatedMessageGuid,
            associatedMessageType = associatedMessageType,
            dateDelivered = dateDelivered,
            dateRead = dateRead
        )

        const val PATH_CREDENTIALS = "/bb/credentials"
        const val PATH_REQUEST_CREDENTIALS = "/bb/request-credentials"
        const val PATH_REQUEST_SYNC = "/bb/request-sync"
        const val PATH_SYNC_CHATS = "/bb/sync-chats"
        const val PATH_SYNC_MESSAGES = "/bb/sync-messages"
        const val PATH_SYNC_CONTACTS = "/bb/sync-contacts"
        const val PATH_NEW_MESSAGE = "/bb/new-message"
        const val PATH_UPDATED_MESSAGE = "/bb/updated-message"
        const val PATH_TYPING_INDICATOR = "/bb/typing-indicator"
        const val PATH_SEND_MESSAGE = "/bb/send-message"
        const val PATH_SEND_REACTION = "/bb/send-reaction"
        const val PATH_SEND_RESULT = "/bb/send-result"
        const val PATH_SEND_AUDIO_PREFIX = "/bb/send-audio/"
        const val PATH_REQUEST_ATTACHMENT = "/bb/request-attachment"
        const val PATH_ATTACHMENT_PREFIX = "/bb/attachment/"
        const val PATH_AVATAR_PREFIX = "/bb/avatar/"
        const val PATH_MARK_READ = "/bb/mark-read"
        const val PATH_DISMISS_NOTIFICATION = "/bb/dismiss-notification"
        const val PATH_WATCH_ACTIVE = "/bb/watch-active"
        const val PATH_OPEN_CHAT = "/bb/open-chat"
        const val PATH_INCOMING_CALL = "/bb/incoming-call"
        const val PATH_CALL_ENDED = "/bb/call-ended"
        const val PATH_ANSWER_CALL_AUDIO = "/bb/answer-call-audio"
        const val PATH_DECLINE_CALL = "/bb/decline-call"

        private val gsonStatic = Gson()

        internal fun parseRelayChatsPayload(json: String): Pair<List<ChatEntity>, Boolean>? {
            val root = JsonParser.parseString(json).asJsonObject
            val type = object : TypeToken<List<ChatRelayDto>>() {}.type
            val list: List<ChatRelayDto> = gsonStatic.fromJson(root.get("chats"), type) ?: return null
            val pinsAuthoritative = root.get("pinsAuthoritative")?.takeIf { it.isJsonPrimitive }?.asBoolean ?: true
            val entities = list.map { dto ->
                ChatEntity(
                    guid = dto.guid,
                    chatIdentifier = dto.chatIdentifier,
                    displayName = dto.displayName,
                    participantAddresses = dto.participantAddresses.joinToString(","),
                    lastMessageText = dto.lastMessageText,
                    lastMessageDate = dto.lastMessageDate,
                    lastMessageIsFromMe = dto.lastMessageIsFromMe,
                    hasUnreadMessage = dto.hasUnreadMessage,
                    lastMessageAttachmentGuid = dto.lastMessageAttachmentGuid,
                    lastMessageAttachmentMimeType = dto.lastMessageAttachmentMimeType,
                    isPinned = dto.isPinned,
                    pinIndex = dto.pinIndex
                )
            }
            return entities to pinsAuthoritative
        }

        internal fun parseRelayChatsToEntities(json: String): List<ChatEntity>? =
            parseRelayChatsPayload(json)?.first
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val gson = Gson()
    private val db by lazy { AppDatabase.getInstance(context) }
    private val settings by lazy { SettingsDataStore(context) }

    private val _isPhoneConnected = MutableStateFlow(false)
    val isPhoneConnected: StateFlow<Boolean> = _isPhoneConnected.asStateFlow()

    private val _events = MutableSharedFlow<RelayEvent>(extraBufferCapacity = 64)
    val events: SharedFlow<RelayEvent> = _events.asSharedFlow()

    private val pendingResults = ConcurrentHashMap<String, CompletableDeferred<SendResultPayload>>()
    private val pendingAttachments = ConcurrentHashMap<String, CompletableDeferred<File?>>()

    private val attachmentsDir: File
        get() = File(context.cacheDir, "attachments").apply { mkdirs() }

    private val avatarsDir: File
        get() = File(context.filesDir, "avatars").apply { mkdirs() }

    suspend fun refreshPhoneConnected(): Boolean {
        return try {
            val info = Wearable.getCapabilityClient(context)
                .getCapability(PHONE_CAPABILITY, CapabilityClient.FILTER_REACHABLE)
                .await()
            val connected = info.nodes.isNotEmpty()
            _isPhoneConnected.value = connected
            connected
        } catch (e: Exception) {
            Log.w(TAG, "refreshPhoneConnected failed: ${e.message}")
            _isPhoneConnected.value = false
            false
        }
    }

    fun updatePhoneConnected(connected: Boolean) {
        _isPhoneConnected.value = connected
    }

    suspend fun getPhoneNodeId(): String? {
        return try {
            val info = Wearable.getCapabilityClient(context)
                .getCapability(PHONE_CAPABILITY, CapabilityClient.FILTER_REACHABLE)
                .await()
            val nearby = info.nodes.firstOrNull { it.isNearby } ?: info.nodes.firstOrNull()
            if (nearby != null) {
                _isPhoneConnected.value = true
                return nearby.id
            }
            _isPhoneConnected.value = false
            null
        } catch (_: Exception) {
            _isPhoneConnected.value = false
            null
        }
    }

    suspend fun requestCredentials(): Boolean {
        return sendToPhone(PATH_REQUEST_CREDENTIALS, ByteArray(0))
    }

    suspend fun loadCachedCredentialsFromDataLayer(): Boolean {
        return try {
            val items = Wearable.getDataClient(context).dataItems.await()
            var found = false
            try {
                for (item in items) {
                    if (item.uri.path == PATH_CREDENTIALS) {
                        val map = DataMapItem.fromDataItem(item).dataMap
                        val url = map.getString("serverUrl") ?: ""
                        val pass = map.getString("password") ?: ""
                        val headers = map.getString("customHeadersJson") ?: "{}"
                        val privateApi = map.getBoolean("privateApiSend", false)
                        if (url.isNotBlank() && pass.isNotBlank()) {
                            settings.saveCredentials(url, pass, headers, privateApi)
                            ApiClient.configureHeaders(url, settings.parseHeaders(headers))
                            found = true
                        }
                    }
                }
            } finally {
                items.release()
            }
            found
        } catch (_: Exception) {
            false
        }
    }

    suspend fun requestChatsSync(): Boolean {
        val payload = JsonObject().apply { addProperty("type", "chats") }.toString().toByteArray()
        return sendToPhone(PATH_REQUEST_SYNC, payload)
    }

    suspend fun requestMessagesSync(chatGuid: String, before: Long? = null): Boolean {
        val payload = JsonObject().apply {
            addProperty("type", "messages")
            addProperty("chatGuid", chatGuid)
            if (before != null) addProperty("before", before)
        }.toString().toByteArray()
        return sendToPhone(PATH_REQUEST_SYNC, payload)
    }

    suspend fun requestContactsSync(): Boolean {
        val payload = JsonObject().apply { addProperty("type", "contacts") }.toString().toByteArray()
        return sendToPhone(PATH_REQUEST_SYNC, payload)
    }

    suspend fun sendMessage(chatGuid: String, text: String, tempGuid: String): SendResultPayload? {
        val requestId = UUID.randomUUID().toString()
        val deferred = CompletableDeferred<SendResultPayload>()
        pendingResults[requestId] = deferred

        val payload = JsonObject().apply {
            addProperty("chatGuid", chatGuid)
            addProperty("text", text)
            addProperty("tempGuid", tempGuid)
            addProperty("requestId", requestId)
        }.toString().toByteArray()

        if (!sendToPhone(PATH_SEND_MESSAGE, payload)) {
            pendingResults.remove(requestId)
            return null
        }

        return try {
            // Once the phone accepted tempGuid, never return null on timeout: falling back to
            // direct server with the same tempGuid hits HTTP 400 (already queued).
            orTimedOutResult(
                withTimeoutOrNull(SEND_TIMEOUT_MS) { deferred.await() },
                requestId = requestId,
                tempGuid = tempGuid
            )
        } finally {
            pendingResults.remove(requestId)
        }
    }

    suspend fun sendReaction(
        chatGuid: String,
        selectedMessageGuid: String,
        reaction: String,
        partIndex: Int = 0
    ): SendResultPayload? {
        val requestId = UUID.randomUUID().toString()
        val deferred = CompletableDeferred<SendResultPayload>()
        pendingResults[requestId] = deferred

        val payload = JsonObject().apply {
            addProperty("chatGuid", chatGuid)
            addProperty("selectedMessageGuid", selectedMessageGuid)
            addProperty("reaction", reaction)
            addProperty("partIndex", partIndex)
            addProperty("requestId", requestId)
        }.toString().toByteArray()

        if (!sendToPhone(PATH_SEND_REACTION, payload)) {
            pendingResults.remove(requestId)
            return null
        }

        return try {
            withTimeoutOrNull(60_000L) { deferred.await() }
        } finally {
            pendingResults.remove(requestId)
        }
    }

    suspend fun sendAudioFile(chatGuid: String, tempGuid: String, file: File): SendResultPayload? {
        val nodeId = getPhoneNodeId() ?: return null
        val deferred = CompletableDeferred<SendResultPayload>()
        pendingResults[tempGuid] = deferred

        val channelClient = Wearable.getChannelClient(context)
        val path = "$PATH_SEND_AUDIO_PREFIX${URLEncoder.encode(chatGuid, "UTF-8")}/${URLEncoder.encode(tempGuid, "UTF-8")}"
        return try {
            val channel = channelClient.openChannel(nodeId, path).await()
            try {
                val out = channelClient.getOutputStream(channel).await()
                out.use { stream ->
                    file.inputStream().use { input -> input.copyTo(stream) }
                    stream.flush()
                }
            } finally {
                try {
                    channelClient.close(channel).await()
                } catch (_: Exception) {
                }
            }
            // Stream flushed to phone with tempGuid; do not fall back to direct server on wait timeout.
            orTimedOutResult(
                withTimeoutOrNull(SEND_TIMEOUT_MS) { deferred.await() },
                requestId = tempGuid,
                tempGuid = tempGuid
            )
        } catch (e: Exception) {
            Log.e(TAG, "sendAudioFile failed: ${e.message}")
            null
        } finally {
            pendingResults.remove(tempGuid)
        }
    }

    fun getCachedAttachmentFile(attachmentGuid: String): File? {
        val file = File(attachmentsDir, safeFileName(attachmentGuid))
        return if (file.exists() && file.length() > 0) file else null
    }

    suspend fun getOrRequestAttachment(attachmentGuid: String): File? {
        getCachedAttachmentFile(attachmentGuid)?.let { return it }
        val deferred = pendingAttachments.getOrPut(attachmentGuid) { CompletableDeferred() }
        val payload = JsonObject().apply { addProperty("attachmentGuid", attachmentGuid) }.toString().toByteArray()
        if (!sendToPhone(PATH_REQUEST_ATTACHMENT, payload)) {
            pendingAttachments.remove(attachmentGuid)
            return null
        }
        return try {
            withTimeoutOrNull(20_000L) { deferred.await() }
        } finally {
            pendingAttachments.remove(attachmentGuid)
        }
    }

    fun getAvatarFile(key: String): File? {
        val file = File(avatarsDir, "${safeFileName(key)}.img")
        return if (file.exists() && file.length() > 0) file else null
    }

    suspend fun sendMarkReadAwait(chatGuid: String): Boolean {
        val payload = JsonObject().apply { addProperty("chatGuid", chatGuid) }.toString().toByteArray()
        return sendToPhone(PATH_MARK_READ, payload)
    }

    suspend fun sendDismissNotificationAwait(chatGuid: String): Boolean {
        val payload = JsonObject().apply { addProperty("chatGuid", chatGuid) }.toString().toByteArray()
        return sendToPhone(PATH_DISMISS_NOTIFICATION, payload)
    }

    suspend fun sendOpenChatAwait(chatGuid: String): Boolean {
        val payload = JsonObject().apply { addProperty("chatGuid", chatGuid) }.toString().toByteArray()
        return sendToPhone(PATH_OPEN_CHAT, payload)
    }

    suspend fun sendAnswerCallAudioAwait(
        callUuid: String,
        callerName: String? = null,
        callerAddress: String? = null
    ): Boolean {
        val payload = JsonObject().apply {
            addProperty("callUuid", callUuid)
            if (!callerName.isNullOrBlank()) addProperty("callerName", callerName)
            if (!callerAddress.isNullOrBlank()) addProperty("callerAddress", callerAddress)
        }.toString().toByteArray()
        return sendToPhone(PATH_ANSWER_CALL_AUDIO, payload)
    }

    suspend fun sendDeclineCallAwait(callUuid: String): Boolean {
        val payload = JsonObject().apply { addProperty("callUuid", callUuid) }.toString().toByteArray()
        return sendToPhone(PATH_DECLINE_CALL, payload)
    }

    fun notifyWatchActive(active: Boolean) {
        scope.launch {
            val payload = JsonObject().apply { addProperty("active", active) }.toString().toByteArray()
            sendToPhone(PATH_WATCH_ACTIVE, payload)
        }
    }

    // --- Handlers called by DataLayerListenerService ---

    suspend fun handleCredentialsJson(json: String) {
        try {
            val obj = JsonParser.parseString(json).asJsonObject
            val url = obj.str("serverUrl") ?: return
            val pass = obj.str("password") ?: return
            val headers = obj.str("customHeadersJson") ?: "{}"
            val privateApi = obj.has("privateApiSend") && obj.get("privateApiSend").asBoolean
            if (url.isNotBlank() && pass.isNotBlank()) {
                settings.saveCredentials(url, pass, headers, privateApi)
                ApiClient.configureHeaders(url, settings.parseHeaders(headers))
            }
        } catch (e: Exception) {
            Log.e(TAG, "handleCredentialsJson error: ${e.message}")
        }
    }

    suspend fun handleChatsSyncJson(json: String) {
        try {
            val (entities, pinsAuthoritative) = parseRelayChatsPayload(json) ?: return
            db.chatDao().replaceAndPrune(entities, preservePins = !pinsAuthoritative)
        } catch (e: Exception) {
            Log.e(TAG, "handleChatsSyncJson error: ${e.message}")
        }
    }

    suspend fun handleMessagesSyncJson(json: String) {
        try {
            val root = JsonParser.parseString(json).asJsonObject
            val type = object : TypeToken<List<MessageRelayDto>>() {}.type
            val list: List<MessageRelayDto> = gson.fromJson(root.get("messages"), type) ?: return
            val entities = list.map { it.toEntity() }
            val chatGuid = root.str("chatGuid") ?: entities.firstOrNull()?.chatGuid
            if (chatGuid != null) {
                val staleCutoff = System.currentTimeMillis() - MessageDao.STALE_PENDING_TIMEOUT_MS
                db.messageDao().upsertAndReconcileBatch(chatGuid, entities, staleCutoff)
            } else {
                db.messageDao().upsertAndPrune(entities)
            }
        } catch (e: Exception) {
            Log.e(TAG, "handleMessagesSyncJson error: ${e.message}")
        }
    }

    suspend fun handleContactsSyncJson(json: String) {
        try {
            val root = JsonParser.parseString(json).asJsonObject
            val type = object : TypeToken<List<ContactRelayDto>>() {}.type
            val list: List<ContactRelayDto> = gson.fromJson(root.get("contacts"), type) ?: return
            val entities = list.map { dto ->
                val cached = getAvatarFile(dto.normalizedAddress)?.absolutePath
                ContactEntity(
                    normalizedAddress = dto.normalizedAddress,
                    displayName = dto.displayName,
                    rawAddress = dto.rawAddress,
                    avatarPath = cached
                )
            }
            db.contactDao().upsertAll(entities)
        } catch (e: Exception) {
            Log.e(TAG, "handleContactsSyncJson error: ${e.message}")
        }
    }

    suspend fun handleIncomingMessageJson(json: String, isUpdate: Boolean) {
        try {
            val dto = gson.fromJson(json, MessageRelayDto::class.java) ?: return
            val entity = dto.toEntity()
            db.messageDao().upsertAndReconcile(entity, tempGuid = dto.tempGuid)
            if (isUpdate) {
                _events.tryEmit(RelayEvent.UpdatedMessage(entity))
            } else {
                _events.tryEmit(RelayEvent.NewMessage(entity))
            }
        } catch (e: Exception) {
            Log.e(TAG, "handleIncomingMessageJson error: ${e.message}")
        }
    }

    fun handleTypingJson(json: String) {
        try {
            val obj = JsonParser.parseString(json).asJsonObject
            val chatGuid = obj.str("chatGuid") ?: return
            val isTyping = obj.has("isTyping") && obj.get("isTyping").asBoolean
            _events.tryEmit(RelayEvent.TypingIndicator(chatGuid, isTyping))
        } catch (_: Exception) {
        }
    }

    fun handleSendResultJson(json: String) {
        try {
            val result = gson.fromJson(json, SendResultPayload::class.java) ?: return
            val handledByRequest = pendingResults[result.requestId]?.complete(result) == true
            val handledByTemp = result.tempGuid?.let { pendingResults[it]?.complete(result) } == true
            if (!handledByRequest && !handledByTemp && !result.tempGuid.isNullOrBlank()) {
                // Late result after timeout, screen exit, or process death — reconcile Room directly.
                scope.launch {
                    try {
                        reconcileOrphanedSendResult(result, db.messageDao())
                    } catch (e: Exception) {
                        Log.w(TAG, "reconcileOrphanedSendResult failed: ${e.message}")
                    }
                }
            }
        } catch (_: Exception) {
        }
    }

    suspend fun handleAvatarAsset(key: String, asset: Asset) {
        try {
            val fd = Wearable.getDataClient(context).getFdForAsset(asset).await()
            val outFile = File(avatarsDir, "${safeFileName(key)}.img")
            fd.inputStream.use { input ->
                outFile.outputStream().use { output -> input.copyTo(output) }
            }
            fd.release()
            db.contactDao().updateAvatarPath(key, outFile.absolutePath)
        } catch (e: Exception) {
            Log.w(TAG, "handleAvatarAsset failed for $key: ${e.message}")
        }
    }

    fun saveStreamedAttachment(attachmentGuid: String, tempFile: File) {
        val target = File(attachmentsDir, safeFileName(attachmentGuid))
        if (!tempFile.renameTo(target)) {
            tempFile.copyTo(target, overwrite = true)
            tempFile.delete()
        }
        pendingAttachments[attachmentGuid]?.complete(target)
        _events.tryEmit(RelayEvent.AttachmentDownloaded(attachmentGuid, target))
    }

    private suspend fun sendToPhone(path: String, payload: ByteArray): Boolean {
        val nodeId = getPhoneNodeId() ?: return false
        return try {
            Wearable.getMessageClient(context).sendMessage(nodeId, path, payload).await()
            true
        } catch (e: Exception) {
            Log.w(TAG, "sendToPhone($path) failed: ${e.message}")
            false
        }
    }

    private fun safeFileName(key: String): String =
        key.replace(Regex("[^a-zA-Z0-9._-]"), "_")

    private fun JsonObject.str(key: String): String? =
        if (has(key) && !get(key).isJsonNull) get(key).asString else null
}
