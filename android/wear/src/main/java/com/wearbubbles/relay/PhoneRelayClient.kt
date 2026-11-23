package com.wearbubbles.relay

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import android.util.Log
import com.google.android.gms.wearable.Asset
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.ChannelClient
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.Node
import com.google.android.gms.wearable.Wearable
import com.google.gson.Gson
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.google.gson.reflect.TypeToken
import com.wearbubbles.api.ApiClient
import com.wearbubbles.api.dto.ChatRelayDto
import com.wearbubbles.api.dto.ContactRelayDto
import com.wearbubbles.api.dto.MessageRelayDto
import com.wearbubbles.api.dto.MessageTranslationDto
import com.wearbubbles.api.dto.TapbackType
import com.wearbubbles.api.dto.TapbackUtils
import com.wearbubbles.data.SettingsDataStore
import com.wearbubbles.db.AppDatabase
import com.wearbubbles.db.MessageDao
import com.wearbubbles.db.entities.ChatEntity
import com.wearbubbles.db.entities.ContactEntity
import com.wearbubbles.db.entities.MessageEntity
import com.wearbubbles.notifications.NotificationHelper
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
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
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.net.URLEncoder
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

data class SendResultPayload(
    val requestId: String,
    val tempGuid: String? = null,
    val success: Boolean = false,
    val error: String? = null,
    val message: MessageRelayDto? = null,
    val timedOut: Boolean = false,
    val translation: MessageTranslationDto? = null
)

sealed class RelayEvent {
    data class NewMessage(val message: MessageEntity) : RelayEvent()
    data class UpdatedMessage(val message: MessageEntity) : RelayEvent()
    data class TypingIndicator(val chatGuid: String, val isTyping: Boolean) : RelayEvent()
    data class AttachmentDownloaded(val attachmentGuid: String, val file: File) : RelayEvent()
    data class ChatMarkedRead(val chatGuid: String) : RelayEvent()
}

internal class NodeConnectionCache(
    private val ttlMs: Long = PhoneRelayClient.NODE_CACHE_TTL_MS,
    private val nowMs: () -> Long = System::currentTimeMillis
) {
    @Volatile
    private var hasCachedValue: Boolean = false
    @Volatile
    var nodeId: String? = null
        private set
    @Volatile
    private var cachedAtMs: Long = 0L

    fun isValid(now: Long = nowMs()): Boolean =
        hasCachedValue && (now - cachedAtMs) in 0 until ttlMs

    fun cachedConnected(now: Long = nowMs()): Boolean? =
        if (isValid(now)) nodeId != null else null

    fun record(nodeId: String?, now: Long = nowMs()) {
        this.nodeId = nodeId
        this.cachedAtMs = now
        this.hasCachedValue = true
    }

    fun invalidate() {
        hasCachedValue = false
        nodeId = null
        cachedAtMs = 0L
    }

    suspend fun getOrRefreshConnected(
        force: Boolean = false,
        fetchNodeId: suspend () -> String?
    ): Boolean {
        if (!force) {
            cachedConnected()?.let { return it }
        }
        val fetched = fetchNodeId()
        record(fetched)
        return fetched != null
    }
}

class PhoneRelayClient(private val context: Context) {

    companion object {
        private const val TAG = "PhoneRelayClient"
        const val PHONE_CAPABILITY = "bluebubbles_phone_app"
        internal const val SEND_TIMEOUT_MS = 130_000L
        internal const val SYNC_TIMEOUT_MS = 12_000L
        internal const val NODE_CACHE_TTL_MS = 15_000L
        internal const val PRUNE_INTERVAL_MS = 30_000L
        internal const val PRUNE_WRITE_THRESHOLD = 20
        internal const val MAX_ATTACHMENTS_BYTES = 40L * 1024 * 1024
        internal const val MAX_ATTACHMENTS_FILES = 200
        internal const val MAX_CHANNEL_ATTACHMENT_BYTES = 2_500_000L

        internal fun copyChannelStreamBounded(
            input: InputStream,
            output: OutputStream,
            maxBytes: Long = MAX_CHANNEL_ATTACHMENT_BYTES
        ): Long {
            val buf = ByteArray(16 * 1024)
            var total = 0L
            while (true) {
                val read = input.read(buf)
                if (read == -1) break
                total += read
                if (total > maxBytes) return -1L
                output.write(buf, 0, read)
            }
            return total
        }
        internal const val MAX_AVATARS_BYTES = 10L * 1024 * 1024
        internal const val MAX_AVATARS_FILES = 150

        internal fun selectRelayNode(
            nodes: Collection<Node>,
            hasStandaloneCredentials: Boolean
        ): Node? {
            nodes.firstOrNull { it.isNearby }?.let { return it }
            return if (!hasStandaloneCredentials) nodes.firstOrNull() else null
        }

        internal suspend fun requestAttachmentDeduped(
            attachmentGuid: String,
            pending: ConcurrentHashMap<String, CompletableDeferred<File?>>,
            cachedFile: () -> File?,
            sendRequest: suspend () -> Boolean,
            timeoutMs: Long = 20_000L
        ): File? {
            cachedFile()?.let { return it }
            val fresh = CompletableDeferred<File?>()
            val existing = pending.putIfAbsent(attachmentGuid, fresh)
            if (existing != null) {
                return withTimeoutOrNull(timeoutMs) { existing.await() }
            }
            if (!sendRequest()) {
                pending.remove(attachmentGuid, fresh)
                fresh.complete(null)
                return null
            }
            return try {
                withTimeoutOrNull(timeoutMs) { fresh.await() }
            } finally {
                pending.remove(attachmentGuid, fresh)
            }
        }

        internal fun pruneDirectory(dir: File, maxBytes: Long, maxFiles: Int) {
            val files = dir.listFiles()?.filter { it.isFile } ?: return
            var totalBytes = files.sumOf { it.length() }
            var count = files.size
            if (totalBytes <= maxBytes && count <= maxFiles) return
            for (file in files.sortedBy { it.lastModified() }) {
                if (totalBytes <= maxBytes && count <= maxFiles) break
                val len = file.length()
                if (file.delete()) {
                    totalBytes -= len
                    count--
                }
            }
        }

        internal fun orTimedOutResult(
            result: SendResultPayload?,
            requestId: String,
            tempGuid: String
        ): SendResultPayload = result ?: SendResultPayload(
            requestId = requestId,
            tempGuid = tempGuid,
            success = false,
            error = "Phone relay timed out",
            timedOut = true
        )

        internal fun computeAckWaitBudgetMs(
            timeoutMs: Long,
            totalCeilingMs: Long?,
            elapsedSinceStartMs: Long
        ): Long {
            val clampedTimeout = timeoutMs.coerceAtLeast(0L)
            if (totalCeilingMs == null) return clampedTimeout
            val remaining = (totalCeilingMs - elapsedSinceStartMs.coerceAtLeast(0L)).coerceAtLeast(0L)
            return minOf(clampedTimeout, remaining)
        }

        internal fun applySelfAvatarUpdate(
            outFile: File,
            avatarBytes: ByteArray?,
            compress: (ByteArray) -> ByteArray? = { compressSelfAvatar(it) }
        ): Pair<String?, Boolean> {
            val existed = outFile.exists()
            if (avatarBytes == null || avatarBytes.isEmpty()) {
                if (existed) {
                    outFile.delete()
                }
                return null to existed
            }
            val toWrite = if (avatarBytes.size <= SELF_AVATAR_MAX_BYTES) {
                avatarBytes
            } else {
                compress(avatarBytes) ?: avatarBytes
            }
            outFile.parentFile?.mkdirs()
            val tmpFile = File(outFile.parentFile, "${outFile.name}.tmp")
            tmpFile.writeBytes(toWrite)
            if (!tmpFile.renameTo(outFile)) {
                tmpFile.copyTo(outFile, overwrite = true)
                tmpFile.delete()
            }
            return "${outFile.absolutePath}?v=${outFile.lastModified()}" to true
        }

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
            } else if (tempGuid.startsWith("temp-react-")) {
                messageDao.deleteByGuid(tempGuid)
            } else {
                messageDao.markSendFailed(tempGuid)
            }
        }

        internal fun MessageRelayDto.toEntity() =
            com.wearbubbles.data.LinkPreviewHelper.relayDtoToEntity(this)

        const val PATH_CREDENTIALS = "/bb/credentials"
        const val PATH_PROFILE = "/bb/profile"
        const val PATH_REQUEST_CREDENTIALS = "/bb/request-credentials"
        private const val SELF_AVATAR_FILE = "self_avatar.img"
        internal const val SELF_AVATAR_MAX_DIM = 128
        internal const val SELF_AVATAR_MAX_BYTES = 32_000

        internal fun decodeAvatarBase64(raw: String?): ByteArray? {
            val cleaned = raw?.trim()?.substringAfter("base64,", raw.trim())?.takeIf { it.isNotEmpty() } ?: return null
            return try {
                Base64.decode(cleaned, Base64.DEFAULT).takeIf { it.isNotEmpty() }
            } catch (_: Exception) {
                null
            }
        }

        internal fun compressSelfAvatar(
            rawBytes: ByteArray,
            maxDim: Int = SELF_AVATAR_MAX_DIM,
            maxBytes: Int = SELF_AVATAR_MAX_BYTES
        ): ByteArray? {
            if (rawBytes.isEmpty()) return null
            return try {
                val decoded = BitmapFactory.decodeByteArray(rawBytes, 0, rawBytes.size)
                    ?: return rawBytes.takeIf { it.size <= maxBytes }
                var current = if (decoded.width > maxDim || decoded.height > maxDim) {
                    val scale = maxDim.toFloat() / maxOf(decoded.width, decoded.height).toFloat()
                    val w = (decoded.width * scale).toInt().coerceAtLeast(1)
                    val h = (decoded.height * scale).toInt().coerceAtLeast(1)
                    Bitmap.createScaledBitmap(decoded, w, h, true).also {
                        if (it !== decoded) decoded.recycle()
                    }
                } else {
                    decoded
                }
                val baos = ByteArrayOutputStream()
                var out: ByteArray? = null
                for (quality in intArrayOf(82, 68, 54, 40)) {
                    baos.reset()
                    current.compress(Bitmap.CompressFormat.JPEG, quality, baos)
                    val candidate = baos.toByteArray()
                    if (candidate.isNotEmpty() && candidate.size <= maxBytes) {
                        out = candidate
                        break
                    }
                }
                if (out == null && (current.width > 96 || current.height > 96)) {
                    val smaller = Bitmap.createScaledBitmap(current, 96, 96, true)
                    if (smaller !== current) current.recycle()
                    current = smaller
                    baos.reset()
                    current.compress(Bitmap.CompressFormat.JPEG, 40, baos)
                    val candidate = baos.toByteArray()
                    if (candidate.isNotEmpty() && candidate.size <= maxBytes) {
                        out = candidate
                    }
                }
                current.recycle()
                out
            } catch (_: Exception) {
                rawBytes.takeIf { it.size <= maxBytes }
            }
        }
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
        const val PATH_AUDIO_FAILED = "/bb/audio-failed"
        const val PATH_REQUEST_ATTACHMENT = "/bb/request-attachment"
        const val PATH_ATTACHMENT_PREFIX = "/bb/attachment/"
        const val PATH_ATTACHMENT_FAILED = "/bb/attachment-failed"
        const val PATH_AVATAR_PREFIX = "/bb/avatar/"
        const val PATH_MARK_READ = "/bb/mark-read"
        const val PATH_DISMISS_NOTIFICATION = "/bb/dismiss-notification"
        const val PATH_WATCH_ACTIVE = "/bb/watch-active"
        const val PATH_OPEN_CHAT = "/bb/open-chat"
        const val PATH_TRANSLATE_MESSAGE = "/bb/translate-message"
        const val PATH_INCOMING_CALL = "/bb/incoming-call"
        const val PATH_CALL_ENDED = "/bb/call-ended"
        const val PATH_CALL_ACTIVE = "/bb/call-active"
        const val PATH_ANSWER_CALL_AUDIO = "/bb/answer-call-audio"
        const val PATH_DECLINE_CALL = "/bb/decline-call"
        const val PATH_SET_CALL_MUTED = "/bb/set-call-muted"
        const val PATH_TRANSFER_CALL_AUDIO = "/bb/transfer-call-audio"

        private val gsonStatic = Gson()

        internal fun buildTransferCallAudioPayload(
            callUuid: String,
            target: String = "phone"
        ): ByteArray = JsonObject().apply {
            addProperty("callUuid", callUuid)
            addProperty("target", target)
        }.toString().toByteArray()

        internal fun buildAnswerCallAudioPayload(
            callUuid: String,
            callerName: String? = null,
            callerAddress: String? = null,
            isTelephony: Boolean = false
        ): ByteArray = JsonObject().apply {
            addProperty("callUuid", callUuid)
            if (!callerName.isNullOrBlank()) addProperty("callerName", callerName)
            if (!callerAddress.isNullOrBlank()) addProperty("callerAddress", callerAddress)
            addProperty("isTelephony", isTelephony)
        }.toString().toByteArray()

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
                    pinIndex = dto.pinIndex,
                    lastReadMessageTimestamp = dto.lastReadMessageTimestamp?.takeIf { it > 0L }
                )
            }
            return entities to pinsAuthoritative
        }

        internal fun parseRelayChatsToEntities(json: String): List<ChatEntity>? =
            parseRelayChatsPayload(json)?.first
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    @OptIn(ExperimentalCoroutinesApi::class)
    private val ingestionDispatcher = Dispatchers.IO.limitedParallelism(2)
    private val gson = Gson()
    private val db by lazy { AppDatabase.getInstance(context) }
    private val settings by lazy { SettingsDataStore(context) }

    @Volatile
    private var cachedIsConfigured: Boolean? = null
    private val nodeCache = NodeConnectionCache()
    @Volatile
    private var lastAvatarPruneMs: Long = 0L
    private val avatarWriteCount = AtomicInteger(0)
    @Volatile
    private var lastAttachPruneMs: Long = 0L
    private val attachWriteCount = AtomicInteger(0)

    init {
        scope.launch {
            settings.isConfigured.collect { cachedIsConfigured = it }
        }
    }

    private val _isPhoneConnected = MutableStateFlow(false)
    val isPhoneConnected: StateFlow<Boolean> = _isPhoneConnected.asStateFlow()

    private val _events = MutableSharedFlow<RelayEvent>(extraBufferCapacity = 64)
    val events: SharedFlow<RelayEvent> = _events.asSharedFlow()

    private data class PendingReplyMeta(
        val chatGuid: String,
        val senderName: String?,
        val text: String
    )

    private val pendingResults = ConcurrentHashMap<String, CompletableDeferred<SendResultPayload>>()
    private val pendingAttachments = ConcurrentHashMap<String, CompletableDeferred<File?>>()
    private val pendingSyncs = ConcurrentHashMap<String, CompletableDeferred<Int>>()
    private val pendingReplies = ConcurrentHashMap<String, PendingReplyMeta>()

    private val attachmentsDir: File
        get() = File(context.cacheDir, "attachments").apply { mkdirs() }

    private val avatarsDir: File
        get() = File(context.filesDir, "avatars").apply { mkdirs() }

    fun invalidateNodeCache() {
        nodeCache.invalidate()
    }

    suspend fun refreshPhoneConnected(force: Boolean = false): Boolean =
        getPhoneNodeId(force = force) != null

    fun updatePhoneConnected(connected: Boolean) {
        if (!connected || nodeCache.nodeId == null) {
            invalidateNodeCache()
        }
        _isPhoneConnected.value = connected
    }

    suspend fun getPhoneNodeId(force: Boolean = false): String? {
        if (!force && nodeCache.isValid()) return nodeCache.nodeId
        return try {
            nodeCache.getOrRefreshConnected(force = force) {
                val info = Wearable.getCapabilityClient(context)
                    .getCapability(PHONE_CAPABILITY, CapabilityClient.FILTER_REACHABLE)
                    .await()
                val hasCreds = cachedIsConfigured ?: settings.isConfigured.first()
                selectRelayNode(info.nodes, hasCreds)?.id
            }
            val id = nodeCache.nodeId
            _isPhoneConnected.value = id != null
            id
        } catch (e: Exception) {
            Log.w(TAG, "getPhoneNodeId failed: ${e.message}")
            invalidateNodeCache()
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
                    when (item.uri.path) {
                        PATH_CREDENTIALS -> {
                            val map = DataMapItem.fromDataItem(item).dataMap
                            val url = map.getString("serverUrl") ?: ""
                            val pass = map.getString("password") ?: ""
                            val headers = map.getString("customHeadersJson") ?: "{}"
                            val privateApi = map.getBoolean("privateApiSend", false)
                            val privateMarkChatAsRead = map.getBoolean("privateMarkChatAsRead", false)
                            if (url.isNotBlank() && pass.isNotBlank()) {
                                settings.saveCredentials(url, pass, headers, privateApi, privateMarkChatAsRead)
                                ApiClient.configureHeaders(url, settings.parseHeaders(headers))
                                found = true
                            }
                        }
                        PATH_PROFILE -> {
                            val map = DataMapItem.fromDataItem(item).dataMap
                            val userName = map.getString("userName") ?: ""
                            val userHandle = map.getString("userHandle") ?: ""
                            val asset = map.getAsset("avatar")
                            val avatarBytes = if (asset != null) {
                                try {
                                    val fd = Wearable.getDataClient(context).getFdForAsset(asset).await()
                                    try {
                                        fd.inputStream.use { it.readBytes() }
                                    } finally {
                                        fd.release()
                                    }
                                } catch (_: Exception) {
                                    null
                                }
                            } else null
                            handleProfileSync(userName, userHandle, avatarBytes)
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

    suspend fun requestProfileSync(): Boolean {
        val payload = JsonObject().apply { addProperty("type", "profile") }.toString().toByteArray()
        return sendToPhone(PATH_REQUEST_SYNC, payload)
    }

    fun getSelfAvatarFile(): File = File(context.filesDir, SELF_AVATAR_FILE)

    fun clearLocalCaches() {
        getSelfAvatarFile().delete()
        File(context.filesDir, "${SELF_AVATAR_FILE}.tmp").delete()
        File(context.filesDir, "avatars").deleteRecursively()
        File(context.cacheDir, "attachments").deleteRecursively()
        pendingReplies.clear()
        pendingResults.clear()
        pendingAttachments.values.forEach { it.complete(null) }
        pendingAttachments.clear()
        pendingSyncs.clear()
        invalidateNodeCache()
    }

    suspend fun deleteCredentialsDataItem() {
        try {
            val dataClient = Wearable.getDataClient(context)
            val items = dataClient.dataItems.await()
            try {
                for (item in items) {
                    if (item.uri.path == PATH_CREDENTIALS) {
                        dataClient.deleteDataItems(item.uri).await()
                    }
                }
            } finally {
                items.release()
            }
            dataClient.deleteDataItems(android.net.Uri.Builder().scheme("wear").path(PATH_CREDENTIALS).build()).await()
        } catch (_: Exception) {
        }
    }

    suspend fun handleProfileSync(userName: String, userHandle: String, avatarBytes: ByteArray?) =
        withContext(ingestionDispatcher) {
            try {
                val outFile = getSelfAvatarFile()
                val (avatarPath, avatarClearedOrUpdated) = applySelfAvatarUpdate(outFile, avatarBytes)
                if (userName.isNotBlank() || userHandle.isNotBlank() || avatarPath != null || avatarClearedOrUpdated) {
                    settings.saveUserProfile(userName, userHandle, avatarPath)
                }
            } catch (e: Exception) {
                Log.w(TAG, "handleProfileSync failed: ${e.message}")
            }
        }

    suspend fun handleProfileJson(json: String) {
        try {
            val obj = JsonParser.parseString(json).asJsonObject
            val userName = obj.str("userName") ?: ""
            val userHandle = obj.str("userHandle") ?: ""
            val avatarBytes = decodeAvatarBase64(obj.str("avatarBase64"))
            handleProfileSync(userName, userHandle, avatarBytes)
        } catch (e: Exception) {
            Log.e(TAG, "handleProfileJson error: ${e.message}")
        }
    }

    suspend fun requestChatsSyncAwait(): Boolean =
        awaitSync("chats") { requestChatsSync() } != null

    suspend fun requestMessagesSync(chatGuid: String, before: Long? = null): Boolean {
        val payload = JsonObject().apply {
            addProperty("type", "messages")
            addProperty("chatGuid", chatGuid)
            if (before != null) addProperty("before", before)
        }.toString().toByteArray()
        return sendToPhone(PATH_REQUEST_SYNC, payload)
    }

    suspend fun requestMessagesSyncAwait(chatGuid: String, before: Long? = null): Int? =
        awaitSync("messages:$chatGuid") { requestMessagesSync(chatGuid, before) }

    suspend fun requestContactsSync(): Boolean {
        val payload = JsonObject().apply { addProperty("type", "contacts") }.toString().toByteArray()
        return sendToPhone(PATH_REQUEST_SYNC, payload)
    }

    suspend fun requestContactsSyncAwait(): Boolean =
        awaitSync("contacts") { requestContactsSync() } != null

    /**
     * Awaits sync completion up to [SYNC_TIMEOUT_MS].
     * Returns `null` only if sending the request failed; returns `-1` if sent but timed out
     * (so callers do not fall back to direct HTTP while tethered); otherwise returns item count.
     */
    private suspend fun awaitSync(key: String, send: suspend () -> Boolean): Int? {
        val deferred = CompletableDeferred<Int>()
        pendingSyncs.put(key, deferred)?.complete(-1)
        if (!send()) {
            pendingSyncs.remove(key, deferred)
            return null
        }
        return try {
            withTimeoutOrNull(SYNC_TIMEOUT_MS) { deferred.await() } ?: -1
        } finally {
            pendingSyncs.remove(key, deferred)
        }
    }

    fun registerPendingReply(tempGuid: String, chatGuid: String, senderName: String?, text: String) {
        pendingReplies[tempGuid] = PendingReplyMeta(chatGuid, senderName, text)
    }

    fun clearPendingReply(tempGuid: String) {
        pendingReplies.remove(tempGuid)
    }

    suspend fun sendMessage(
        chatGuid: String,
        text: String,
        tempGuid: String,
        timeoutMs: Long = SEND_TIMEOUT_MS,
        totalCeilingMs: Long? = null
    ): SendResultPayload? {
        val startMs = System.currentTimeMillis()
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

        val waitMs = computeAckWaitBudgetMs(
            timeoutMs = timeoutMs,
            totalCeilingMs = totalCeilingMs,
            elapsedSinceStartMs = System.currentTimeMillis() - startMs
        )
        return try {
            // Once the phone accepted tempGuid, never return null on timeout: falling back to
            // direct server with the same tempGuid hits HTTP 400 (already queued).
            orTimedOutResult(
                if (waitMs <= 0L) null else withTimeoutOrNull(waitMs) { deferred.await() },
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
        tempGuid: String = "temp-react-${UUID.randomUUID()}",
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
            addProperty("tempGuid", tempGuid)
        }.toString().toByteArray()

        if (!sendToPhone(PATH_SEND_REACTION, payload)) {
            pendingResults.remove(requestId)
            return null
        }

        return try {
            orTimedOutResult(
                withTimeoutOrNull(60_000L) { deferred.await() },
                requestId = requestId,
                tempGuid = tempGuid
            )
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

    suspend fun getOrRequestAttachment(attachmentGuid: String): File? =
        requestAttachmentDeduped(
            attachmentGuid = attachmentGuid,
            pending = pendingAttachments,
            cachedFile = { getCachedAttachmentFile(attachmentGuid) },
            sendRequest = {
                val payload = JsonObject().apply {
                    addProperty("attachmentGuid", attachmentGuid)
                }.toString().toByteArray()
                sendToPhone(PATH_REQUEST_ATTACHMENT, payload)
            }
        )

    fun failAttachmentRequest(attachmentGuid: String) {
        pendingAttachments.remove(attachmentGuid)?.complete(null)
    }

    fun failAudioRequest(tempGuid: String, reason: String?) {
        val result = SendResultPayload(
            requestId = tempGuid,
            tempGuid = tempGuid,
            success = false,
            error = reason ?: "Audio upload failed"
        )
        if (pendingResults.remove(tempGuid)?.complete(result) != true && tempGuid.isNotBlank()) {
            scope.launch {
                try {
                    reconcileOrphanedSendResult(result, db.messageDao())
                } catch (e: Exception) {
                    Log.w(TAG, "failAudioRequest reconcile failed: ${e.message}")
                }
            }
        }
    }

    fun getAvatarFile(key: String): File? {
        val file = File(avatarsDir, "${safeFileName(key)}.img")
        return if (file.exists() && file.length() > 0) file else null
    }

    private suspend fun sendJsonField(path: String, key: String, value: String): Boolean =
        sendToPhone(path, JsonObject().apply { addProperty(key, value) }.toString().toByteArray())

    suspend fun sendMarkReadAwait(chatGuid: String): Boolean =
        sendJsonField(PATH_MARK_READ, "chatGuid", chatGuid)

    suspend fun sendDismissNotificationAwait(chatGuid: String): Boolean =
        sendJsonField(PATH_DISMISS_NOTIFICATION, "chatGuid", chatGuid)

    suspend fun sendOpenChatAwait(chatGuid: String): Boolean =
        sendJsonField(PATH_OPEN_CHAT, "chatGuid", chatGuid)

    suspend fun sendAnswerCallAudioAwait(
        callUuid: String,
        callerName: String? = null,
        callerAddress: String? = null,
        isTelephony: Boolean = false
    ): Boolean {
        val payload = buildAnswerCallAudioPayload(
            callUuid = callUuid,
            callerName = callerName,
            callerAddress = callerAddress,
            isTelephony = isTelephony
        )
        return sendToPhone(PATH_ANSWER_CALL_AUDIO, payload)
    }

    suspend fun sendDeclineCallAwait(callUuid: String): Boolean =
        sendJsonField(PATH_DECLINE_CALL, "callUuid", callUuid)

    suspend fun sendSetCallMutedAwait(callUuid: String, muted: Boolean): Boolean {
        val payload = JsonObject().apply {
            addProperty("callUuid", callUuid)
            addProperty("muted", muted)
        }.toString().toByteArray()
        return sendToPhone(PATH_SET_CALL_MUTED, payload)
    }

    suspend fun sendTransferCallAudioToPhoneAwait(callUuid: String): Boolean =
        sendToPhone(PATH_TRANSFER_CALL_AUDIO, buildTransferCallAudioPayload(callUuid, target = "phone"))

    suspend fun translateMessage(messageGuid: String): SendResultPayload? {
        val requestId = UUID.randomUUID().toString()
        val deferred = CompletableDeferred<SendResultPayload>()
        pendingResults[requestId] = deferred

        val payload = JsonObject().apply {
            addProperty("messageGuid", messageGuid)
            addProperty("requestId", requestId)
        }.toString().toByteArray()

        if (!sendToPhone(PATH_TRANSLATE_MESSAGE, payload)) {
            pendingResults.remove(requestId)
            return null
        }

        return try {
            orTimedOutResult(
                withTimeoutOrNull(30_000L) { deferred.await() },
                requestId = requestId,
                tempGuid = messageGuid
            )
        } finally {
            pendingResults.remove(requestId)
        }
    }

    private val watchActiveLock = Any()
    @Volatile
    private var desiredWatchActive: Boolean = false
    private var watchActiveJob: Job? = null

    fun notifyWatchActive(active: Boolean) {
        synchronized(watchActiveLock) {
            desiredWatchActive = active
            watchActiveJob?.cancel()
            watchActiveJob = scope.launch {
                if (desiredWatchActive != active) return@launch
                val payload = JsonObject().apply { addProperty("active", active) }.toString().toByteArray()
                sendToPhone(PATH_WATCH_ACTIVE, payload)
            }
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
            val privateMarkChatAsRead = obj.has("privateMarkChatAsRead") && obj.get("privateMarkChatAsRead").asBoolean
            if (url.isNotBlank() && pass.isNotBlank()) {
                settings.saveCredentials(url, pass, headers, privateApi, privateMarkChatAsRead)
                ApiClient.configureHeaders(url, settings.parseHeaders(headers))
            }
        } catch (e: Exception) {
            Log.e(TAG, "handleCredentialsJson error: ${e.message}")
        }
    }

    fun notifyChatMarkedRead(chatGuid: String) {
        _events.tryEmit(RelayEvent.ChatMarkedRead(chatGuid))
    }

    suspend fun handleChatsSyncJson(json: String) {
        try {
            val parsed = parseRelayChatsPayload(json)
            if (parsed == null) {
                pendingSyncs["chats"]?.complete(-1)
                return
            }
            val (entities, pinsAuthoritative) = parsed
            db.chatDao().replaceAndPrune(entities, preservePins = !pinsAuthoritative)
            pendingSyncs["chats"]?.complete(entities.size)
        } catch (e: Exception) {
            Log.e(TAG, "handleChatsSyncJson error: ${e.message}")
            pendingSyncs["chats"]?.complete(-1)
        }
    }

    suspend fun handleMessagesSyncJson(json: String) {
        var parsedChatGuid: String? = null
        try {
            val root = JsonParser.parseString(json).asJsonObject
            parsedChatGuid = root.str("chatGuid")
            val type = object : TypeToken<List<MessageRelayDto>>() {}.type
            val list: List<MessageRelayDto>? = gson.fromJson(root.get("messages"), type)
            if (list == null) {
                if (parsedChatGuid != null) {
                    pendingSyncs["messages:$parsedChatGuid"]?.complete(-1)
                }
                return
            }
            val entities = list.map { it.toEntity() }
            val chatGuid = parsedChatGuid ?: entities.firstOrNull()?.chatGuid
            parsedChatGuid = chatGuid
            if (chatGuid != null) {
                val staleCutoff = System.currentTimeMillis() - MessageDao.STALE_PENDING_TIMEOUT_MS
                db.messageDao().upsertAndReconcileBatch(chatGuid, entities, staleCutoff)
                pendingSyncs["messages:$chatGuid"]?.complete(entities.size)
            } else {
                db.messageDao().upsertAndPrune(entities)
            }
        } catch (e: Exception) {
            Log.e(TAG, "handleMessagesSyncJson error: ${e.message}")
            val guid = parsedChatGuid
            if (guid != null) {
                pendingSyncs["messages:$guid"]?.complete(-1)
            } else {
                pendingSyncs.entries.forEach { (key, deferred) ->
                    if (key.startsWith("messages:")) deferred.complete(-1)
                }
            }
        }
    }

    suspend fun handleContactsSyncJson(json: String) {
        try {
            val root = JsonParser.parseString(json).asJsonObject
            val type = object : TypeToken<List<ContactRelayDto>>() {}.type
            val list: List<ContactRelayDto>? = gson.fromJson(root.get("contacts"), type)
            if (list == null) {
                pendingSyncs["contacts"]?.complete(-1)
                return
            }
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
            pendingSyncs["contacts"]?.complete(entities.size)
        } catch (e: Exception) {
            Log.e(TAG, "handleContactsSyncJson error: ${e.message}")
            pendingSyncs["contacts"]?.complete(-1)
        }
    }

    suspend fun handleIncomingMessageJson(json: String, isUpdate: Boolean) {
        try {
            val dto = gson.fromJson(json, MessageRelayDto::class.java) ?: return
            val parsed = dto.toEntity()
            val entity = if (isUpdate) {
                MessageDao.mergeTranslationIfUnchanged(parsed, db.messageDao().getByGuid(parsed.guid))
            } else parsed
            db.messageDao().upsertAndReconcile(entity, tempGuid = dto.tempGuid)
            if (!isUpdate) {
                val displayText = if (TapbackUtils.isTapbackCode(entity.associatedMessageType)) {
                    val reactionName = TapbackType.fromAddCode(entity.associatedMessageType)?.label ?: "Reacted"
                    "$reactionName to a message"
                } else {
                    entity.text?.takeIf { it.isNotBlank() } ?: entity.attachmentMimeType?.let { mime ->
                        when {
                            mime.startsWith("image/") -> "Image"
                            mime.startsWith("video/") -> "Video"
                            mime.startsWith("audio/") -> "Audio Message"
                            else -> "Attachment"
                        }
                    } ?: if (!entity.attachmentGuid.isNullOrBlank()) "Attachment" else null
                }
                val unread = !entity.isFromMe && NotificationHelper.activeChatGuid.value != entity.chatGuid
                val identifier = entity.chatGuid.substringAfterLast(";").ifBlank { entity.chatGuid }
                db.chatDao().upsertChatFromIncomingMessage(
                    chatGuid = entity.chatGuid,
                    defaultIdentifier = identifier,
                    defaultParticipantAddresses = entity.handleAddress ?: identifier,
                    lastMessageText = displayText,
                    lastMessageDate = entity.dateCreated,
                    lastMessageIsFromMe = entity.isFromMe,
                    hasUnreadMessage = unread,
                    lastMessageAttachmentGuid = entity.attachmentGuid,
                    lastMessageAttachmentMimeType = entity.attachmentMimeType
                )
            }
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
            val tempGuid = result.tempGuid
            if (!tempGuid.isNullOrBlank()) {
                val replyMeta = pendingReplies.remove(tempGuid)
                if (!handledByRequest && !handledByTemp) {
                    if (replyMeta != null && !result.success) {
                        NotificationHelper.showReplyFailureNotification(
                            context = context,
                            chatGuid = replyMeta.chatGuid,
                            senderName = replyMeta.senderName,
                            replyText = replyMeta.text
                        )
                    }
                    // Late result after timeout, screen exit, or process death — reconcile Room directly.
                    scope.launch {
                        try {
                            reconcileOrphanedSendResult(result, db.messageDao())
                        } catch (e: Exception) {
                            Log.w(TAG, "reconcileOrphanedSendResult failed: ${e.message}")
                        }
                    }
                }
            }
        } catch (_: Exception) {
        }
    }

    suspend fun handleAvatarAsset(key: String, asset: Asset) = withContext(ingestionDispatcher) {
        try {
            val fd = Wearable.getDataClient(context).getFdForAsset(asset).await()
            val outFile = File(avatarsDir, "${safeFileName(key)}.img")
            try {
                fd.inputStream.use { input ->
                    outFile.outputStream().use { output -> input.copyTo(output) }
                }
            } finally {
                fd.release()
            }
            db.contactDao().updateAvatarPath(key, outFile.absolutePath)
            val now = System.currentTimeMillis()
            if (avatarWriteCount.incrementAndGet() >= PRUNE_WRITE_THRESHOLD || now - lastAvatarPruneMs >= PRUNE_INTERVAL_MS) {
                avatarWriteCount.set(0)
                lastAvatarPruneMs = now
                pruneDirectory(avatarsDir, MAX_AVATARS_BYTES, MAX_AVATARS_FILES)
            }
        } catch (e: Exception) {
            Log.w(TAG, "handleAvatarAsset failed for $key: ${e.message}")
        }
    }

    fun streamAttachmentFromChannel(channel: ChannelClient.Channel, attachmentGuid: String) {
        scope.launch {
            val channelClient = Wearable.getChannelClient(context)
            var tempFile: File? = null
            try {
                val tmp = File.createTempFile("tmp_att_", ".tmp", context.cacheDir)
                tempFile = tmp
                val input = channelClient.getInputStream(channel).await()
                val copiedBytes = input.use { inStream ->
                    tmp.outputStream().use { outStream ->
                        copyChannelStreamBounded(inStream, outStream)
                    }
                }
                if (copiedBytes <= 0L) {
                    Log.w(
                        TAG,
                        "streamAttachmentFromChannel rejected $attachmentGuid (bytes=$copiedBytes cap=$MAX_CHANNEL_ATTACHMENT_BYTES)"
                    )
                    tmp.delete()
                    failAttachmentRequest(attachmentGuid)
                    return@launch
                }
                saveStreamedAttachment(attachmentGuid, tmp)
            } catch (e: Exception) {
                Log.e(TAG, "streamAttachmentFromChannel failed: ${e.message}")
                tempFile?.delete()
                failAttachmentRequest(attachmentGuid)
            } finally {
                withContext(NonCancellable) {
                    try {
                        channelClient.close(channel).await()
                    } catch (_: Exception) {
                    }
                }
            }
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
        val now = System.currentTimeMillis()
        if (attachWriteCount.incrementAndGet() >= PRUNE_WRITE_THRESHOLD || now - lastAttachPruneMs >= PRUNE_INTERVAL_MS) {
            attachWriteCount.set(0)
            lastAttachPruneMs = now
            pruneDirectory(attachmentsDir, MAX_ATTACHMENTS_BYTES, MAX_ATTACHMENTS_FILES)
        }
    }

    private suspend fun sendToPhone(path: String, payload: ByteArray): Boolean {
        val nodeId = getPhoneNodeId() ?: return false
        return try {
            Wearable.getMessageClient(context).sendMessage(nodeId, path, payload).await()
            true
        } catch (e: Exception) {
            invalidateNodeCache()
            Log.w(TAG, "sendToPhone($path) failed: ${e.message}")
            false
        }
    }

    private fun safeFileName(key: String): String =
        key.replace(Regex("[^a-zA-Z0-9._-]"), "_")

    private fun JsonObject.str(key: String): String? =
        if (has(key) && !get(key).isJsonNull) get(key).asString else null
}
