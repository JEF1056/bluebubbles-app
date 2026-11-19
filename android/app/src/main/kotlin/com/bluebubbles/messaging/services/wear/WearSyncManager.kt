package com.bluebubbles.messaging.services.wear

import android.app.NotificationManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Base64
import java.io.ByteArrayOutputStream
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.services.backend_ui_interop.DartWorkManager
import com.bluebubbles.messaging.utils.PersistentLog
import com.bluebubbles.messaging.utils.SettingsHelper
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.Asset
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import com.google.gson.Gson
import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import io.socket.client.IO
import io.socket.client.Socket
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.File
import java.net.URLEncoder
import java.util.UUID
import java.util.concurrent.TimeUnit

object WearSyncManager {
    private const val TAG = "WearSyncManager"
    const val WATCH_CAPABILITY = "bluebubbles_watch_app"
    private const val PREFS_NAME = "wear_sync_prefs"
    private const val KEY_WATCH_CONNECTED = "watch_connected"
    private const val KEY_WATCH_CHECKED_AT = "watch_checked_at"
    private const val CACHE_TTL_MS = 30_000L
    private const val SOCKET_IDLE_TIMEOUT_MS = 120_000L

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
    const val PATH_TYPING = "/bb/typing"
    const val PATH_WATCH_ACTIVE = "/bb/watch-active"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val gson = Gson()
    private val jsonMediaType = "application/json; charset=utf-8".toMediaType()

    @Volatile
    private var cachedConnected: Boolean? = null

    @Volatile
    private var lastCheckedAt: Long = 0L

    @Volatile
    private var relaySocket: Socket? = null
    private var socketTimeoutJob: Job? = null

    @JvmStatic
    fun isWatchConnected(context: Context): Boolean {
        val now = System.currentTimeMillis()
        val cached = cachedConnected
        if (cached != null && now - lastCheckedAt < CACHE_TTL_MS) {
            return cached
        }
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val persisted = prefs.getBoolean(KEY_WATCH_CONNECTED, false)
        val persistedAt = prefs.getLong(KEY_WATCH_CHECKED_AT, 0L)
        if (now - persistedAt < CACHE_TTL_MS) {
            cachedConnected = persisted
            lastCheckedAt = persistedAt
            return persisted
        }
        // Avoid blocking main thread; trigger async refresh and return last known state.
        if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) {
            scope.launch { refreshWatchConnected(context) }
            return persisted
        }
        return try {
            val capInfo = Tasks.await(
                Wearable.getCapabilityClient(context)
                    .getCapability(WATCH_CAPABILITY, CapabilityClient.FILTER_REACHABLE),
                300,
                TimeUnit.MILLISECONDS
            )
            val connected = capInfo.nodes.any { it.isNearby } || capInfo.nodes.isNotEmpty()
            updateWatchConnectedCache(context, connected)
            connected
        } catch (_: Exception) {
            scope.launch { refreshWatchConnected(context) }
            persisted
        }
    }

    @JvmStatic
    fun updateWatchConnectedCache(context: Context, connected: Boolean) {
        val now = System.currentTimeMillis()
        cachedConnected = connected
        lastCheckedAt = now
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_WATCH_CONNECTED, connected)
            .putLong(KEY_WATCH_CHECKED_AT, now)
            .apply()
    }

    suspend fun refreshWatchConnected(context: Context): Boolean {
        return try {
            val capInfo = Wearable.getCapabilityClient(context)
                .getCapability(WATCH_CAPABILITY, CapabilityClient.FILTER_REACHABLE)
                .await()
            val connected = if (capInfo.nodes.isNotEmpty()) {
                true
            } else {
                Wearable.getNodeClient(context).connectedNodes.await().isNotEmpty()
            }
            updateWatchConnectedCache(context, connected)
            connected
        } catch (e: Exception) {
            PersistentLog.w(context, TAG, "refreshWatchConnected failed: ${e.message}")
            false
        }
    }

    @JvmStatic
    fun notifyDismissed(context: Context, chatGuid: String) {
        if (chatGuid.isBlank()) return
        scope.launch {
            val payload = JsonObject().apply { addProperty("chatGuid", chatGuid) }.toString()
            sendMessageToWatchNodes(context, PATH_DISMISS_NOTIFICATION, payload.toByteArray())
        }
    }

    fun syncCredentials(context: Context, targetNodeId: String? = null) {
        scope.launch {
            try {
                val settings = SettingsHelper(context)
                val origin = settings.origin
                val password = settings.guidAuthKey
                val headersJson = gson.toJson(settings.getAllHeaders())
                val privateApiSend = settings.enablePrivateAPI && settings.privateAPISend

                val putReq = PutDataMapRequest.create(PATH_CREDENTIALS).apply {
                    dataMap.putString("serverUrl", origin)
                    dataMap.putString("password", password)
                    dataMap.putString("customHeadersJson", headersJson)
                    dataMap.putBoolean("privateApiSend", privateApiSend)
                    dataMap.putLong("updatedAt", System.currentTimeMillis())
                }.asPutDataRequest().setUrgent()
                Wearable.getDataClient(context).putDataItem(putReq).await()

                val msgJson = JsonObject().apply {
                    addProperty("serverUrl", origin)
                    addProperty("password", password)
                    addProperty("customHeadersJson", headersJson)
                    addProperty("privateApiSend", privateApiSend)
                }.toString().toByteArray()
                if (targetNodeId != null) {
                    Wearable.getMessageClient(context).sendMessage(targetNodeId, PATH_CREDENTIALS, msgJson).await()
                } else {
                    sendMessageToWatchNodes(context, PATH_CREDENTIALS, msgJson)
                }
            } catch (e: Exception) {
                PersistentLog.e(context, TAG, "syncCredentials failed: ${e.message}")
            }
        }
    }

    fun syncChats(context: Context, targetNodeId: String? = null) {
        scope.launch {
            val settings = SettingsHelper(context)
            if (!settings.hasServerUrl() || !settings.hasAuthKey()) return@launch
            try {
                val client = buildOkHttpClient(settings)
                val pinnedGuids = fetchPinnedChatGuids(client, settings)
                val body = JsonObject().apply {
                    addProperty("limit", 30)
                    addProperty("offset", 0)
                    add("with", JsonArray().apply {
                        add("lastMessage")
                        add("participants")
                        add("sms")
                    })
                    addProperty("sort", "lastmessage")
                }.toString().toRequestBody(jsonMediaType)

                val url = "${settings.apiRoot}/chat/query?password=${encode(settings.guidAuthKey)}"
                val req = Request.Builder().url(url).post(body).build()
                val recentChats = client.newCall(req).execute().use { resp ->
                    if (!resp.isSuccessful) {
                        PersistentLog.w(context, TAG, "syncChats HTTP ${resp.code}")
                        return@launch
                    }
                    val root = JsonParser.parseString(resp.body?.string() ?: "{}").asObjOrNull()
                        ?: return@launch
                    val data = root.arr("data") ?: return@launch
                    data.mapNotNull { it.asObjOrNull() }
                }

                val recentGuids = recentChats.mapNotNull { it.str("guid") }.toHashSet()
                val extraPinnedChats = mutableListOf<JsonObject>()
                if (pinnedGuids != null) {
                    for (guid in pinnedGuids) {
                        if (guid !in recentGuids) {
                            fetchSingleChat(client, settings, guid)?.let { chatObj ->
                                extraPinnedChats.add(chatObj)
                                recentGuids.add(guid)
                            }
                        }
                    }
                }

                val relayChats = buildWatchChatSyncList(recentChats, extraPinnedChats, pinnedGuids)
                val out = JsonArray()
                val chatAvatarTargets = mutableListOf<Pair<String, String>>()
                for (chatObj in relayChats) {
                    out.add(chatObj)
                    val guid = chatObj.str("guid") ?: continue
                    val addresses = chatObj.arr("participantAddresses")
                    val avatarKey = if (addresses != null && addresses.size() == 1) {
                        normalizeAddress(addresses[0].asString)
                    } else {
                        guid
                    }
                    chatAvatarTargets.add(guid to avatarKey)
                }
                val pinsAuthoritative = pinnedGuids != null
                val payload = JsonObject().apply {
                    add("chats", out)
                    addProperty("pinsAuthoritative", pinsAuthoritative)
                }.toString().toByteArray()
                sendToWatch(context, targetNodeId, PATH_SYNC_CHATS, payload)
                syncChatIcons(context, settings, client, chatAvatarTargets.take(15))
            } catch (e: Exception) {
                PersistentLog.e(context, TAG, "syncChats error: ${e.message}")
            }
        }
    }

    private fun fetchPinnedChatGuids(client: OkHttpClient, settings: SettingsHelper): List<String>? {
        return try {
            val url = "${settings.apiRoot}/chat/pinned?password=${encode(settings.guidAuthKey)}"
            val req = Request.Builder().url(url).get().build()
            client.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return null
                val body = resp.body?.string() ?: return null
                parsePinnedGuidsResponse(body)
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun fetchSingleChat(
        client: OkHttpClient,
        settings: SettingsHelper,
        guid: String
    ): JsonObject? {
        return try {
            val url = "${settings.apiRoot}/chat/${encode(guid)}?with=participants,lastMessage&password=${encode(settings.guidAuthKey)}"
            val req = Request.Builder().url(url).get().build()
            client.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return null
                val root = JsonParser.parseString(resp.body?.string() ?: "{}").asObjOrNull()
                    ?: return null
                root.obj("data")
            }
        } catch (_: Exception) {
            null
        }
    }

    internal fun parsePinnedGuidsResponse(json: String): List<String>? {
        val root = runCatching { JsonParser.parseString(json).asObjOrNull() }.getOrNull() ?: return null
        val arr = root.obj("data")?.arr("pinnedChatGuids") ?: root.arr("pinnedChatGuids") ?: return null
        return buildList {
            for (elem in arr) {
                if (elem != null && elem.isJsonPrimitive) {
                    val guid = elem.asString
                    if (guid.isNotBlank()) add(guid)
                }
            }
        }
    }

    internal fun buildWatchChatSyncList(
        recentChats: List<JsonObject>,
        extraPinnedChats: List<JsonObject>,
        pinnedGuids: List<String>?
    ): List<JsonObject> {
        val pinIndexByGuid = pinnedGuids?.withIndex()?.associate { it.value to it.index }
        val seenGuids = HashSet<String>()
        data class Entry(
            val relayJson: JsonObject,
            val isPinned: Boolean,
            val pinIndex: Int?,
            val lastMessageDate: Long
        )

        val entries = mutableListOf<Entry>()
        for (chat in recentChats + extraPinnedChats) {
            val guid = chat.str("guid") ?: continue
            if (!seenGuids.add(guid)) continue
            val deletedEl = chat.get("dateDeleted")
            if (deletedEl != null && !deletedEl.isJsonNull) continue

            val resolvedPinIndex = if (pinIndexByGuid != null) pinIndexByGuid[guid] else chat.int("pinIndex")
            val resolvedPinned = if (pinIndexByGuid != null) resolvedPinIndex != null else (chat.bool("isPinned") == true)
            if (!resolvedPinned && (chat.bool("isArchived") == true || chat.bool("isFiltered") == true || chat.bool("isFilteredAsSpam") == true)) {
                continue
            }

            val displayName = chat.str("displayName")?.takeIf { it.isNotBlank() }
            val chatIdentifier = chat.str("chatIdentifier")
                ?: guid.substringAfterLast(";").ifBlank { guid }
            val participants = chat.arr("participants")
            val addresses = JsonArray()
            participants?.forEach { p ->
                p.asObjOrNull()?.str("address")?.let { addresses.add(it) }
            }
            val lastMsg = chat.obj("lastMessage")
            val lastMessageDate = lastMsg?.long("dateCreated") ?: 0L
            if (lastMessageDate <= 0L && !resolvedPinned) continue
            var lastText = lastMsg?.str("text")?.takeIf { it.isNotBlank() }
            var attGuid: String? = null
            var attMime: String? = null
            val atts = lastMsg?.arr("attachments")
            if (atts != null && atts.size() > 0) {
                val firstAtt = atts[0].asObjOrNull()
                attGuid = firstAtt?.str("guid")
                attMime = firstAtt?.str("mimeType")
                if (lastText == null) {
                    lastText = when {
                        attMime?.startsWith("image/") == true -> "Image"
                        attMime?.startsWith("video/") == true -> "Video"
                        attMime?.startsWith("audio/") == true -> "Audio Message"
                        else -> "Attachment"
                    }
                }
            }

            val relayJson = JsonObject().apply {
                addProperty("guid", guid)
                addProperty("chatIdentifier", chatIdentifier)
                addProperty("displayName", displayName)
                add("participantAddresses", addresses)
                addProperty("lastMessageText", lastText)
                addProperty("lastMessageDate", lastMessageDate)
                addProperty("lastMessageIsFromMe", lastMsg?.bool("isFromMe") ?: false)
                addProperty("hasUnreadMessage", chat.bool("hasUnreadMessage") ?: false)
                addProperty("lastMessageAttachmentGuid", attGuid)
                addProperty("lastMessageAttachmentMimeType", attMime)
                addProperty("isPinned", resolvedPinned)
                if (resolvedPinIndex != null) {
                    addProperty("pinIndex", resolvedPinIndex)
                }
            }
            entries.add(Entry(relayJson, resolvedPinned, resolvedPinIndex, lastMessageDate))
        }

        entries.sortWith { a, b ->
            when {
                a.isPinned && b.isPinned -> {
                    val ai = a.pinIndex
                    val bi = b.pinIndex
                    when {
                        ai != null && bi != null -> {
                            val cmp = ai.compareTo(bi)
                            if (cmp != 0) cmp else b.lastMessageDate.compareTo(a.lastMessageDate)
                        }
                        ai != null -> -1
                        bi != null -> 1
                        else -> b.lastMessageDate.compareTo(a.lastMessageDate)
                    }
                }
                a.isPinned -> -1
                b.isPinned -> 1
                else -> b.lastMessageDate.compareTo(a.lastMessageDate)
            }
        }
        return entries.map { it.relayJson }
    }

    private suspend fun syncChatIcons(
        context: Context,
        settings: SettingsHelper,
        client: OkHttpClient,
        targets: List<Pair<String, String>>
    ) {
        for ((chatGuid, avatarKey) in targets) {
            try {
                val url = "${settings.apiRoot}/chat/${encode(chatGuid)}/icon?password=${encode(settings.guidAuthKey)}"
                client.newCall(Request.Builder().url(url).get().build()).execute().use { resp ->
                    if (!resp.isSuccessful) return@use
                    val bytes = resp.body?.bytes() ?: return@use
                    if (bytes.isEmpty() || bytes.size > 250_000) return@use
                    putAvatarAsset(context, avatarKey, bytes)
                }
            } catch (_: Exception) {
            }
        }
    }

    fun syncMessages(context: Context, chatGuid: String, before: Long? = null, targetNodeId: String? = null) {
        scope.launch {
            val settings = SettingsHelper(context)
            if (!settings.hasServerUrl() || !settings.hasAuthKey()) return@launch
            try {
                val client = buildOkHttpClient(settings)
                val bodyObj = JsonObject().apply {
                    addProperty("chatGuid", chatGuid)
                    addProperty("limit", 40)
                    addProperty("offset", 0)
                    addProperty("sort", "DESC")
                    add("with", JsonArray().apply {
                        add("handle")
                        add("attachment")
                        add("attributedBody")
                    })
                    if (before != null) {
                        add("where", JsonArray().apply {
                            add(JsonObject().apply {
                                addProperty("statement", "message.date_created < :before")
                                add("args", JsonObject().apply { addProperty("before", before) })
                            })
                        })
                    }
                }
                val url = "${settings.apiRoot}/message/query?password=${encode(settings.guidAuthKey)}"
                val req = Request.Builder().url(url).post(bodyObj.toString().toRequestBody(jsonMediaType)).build()
                client.newCall(req).execute().use { resp ->
                    if (!resp.isSuccessful) {
                        PersistentLog.w(context, TAG, "syncMessages HTTP ${resp.code}")
                        return@launch
                    }
                    val root = JsonParser.parseString(resp.body?.string() ?: "{}").asObjOrNull() ?: return@launch
                    val data = root.arr("data") ?: return@launch
                    val out = JsonArray()
                    for (elem in data) {
                        elem.asObjOrNull()?.let { out.add(mapMessageToRelayJson(it, chatGuid)) }
                    }
                    val payload = JsonObject().apply {
                        addProperty("chatGuid", chatGuid)
                        add("messages", out)
                    }.toString().toByteArray()
                    sendToWatch(context, targetNodeId, PATH_SYNC_MESSAGES, payload)
                }
            } catch (e: Exception) {
                PersistentLog.e(context, TAG, "syncMessages error: ${e.message}")
            }
        }
    }

    private fun compressAvatarForWatch(rawBytes: ByteArray): ByteArray? {
        if (rawBytes.isEmpty()) return null
        return try {
            val decoded = BitmapFactory.decodeByteArray(rawBytes, 0, rawBytes.size)
            if (decoded == null) {
                rawBytes.takeIf { it.size <= 250_000 }
            } else {
                val maxDim = 160
                val scaled = if (decoded.width > maxDim || decoded.height > maxDim) {
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
                scaled.compress(Bitmap.CompressFormat.JPEG, 82, baos)
                scaled.recycle()
                baos.toByteArray().takeIf { it.isNotEmpty() && it.size <= 250_000 }
            }
        } catch (_: Exception) {
            rawBytes.takeIf { it.size <= 250_000 }
        }
    }

    fun syncContacts(context: Context, targetNodeId: String? = null) {
        scope.launch {
            val settings = SettingsHelper(context)
            if (!settings.hasServerUrl() || !settings.hasAuthKey()) return@launch
            try {
                val client = buildOkHttpClient(settings)
                val pinnedAddresses = fetchPinnedChatGuids(client, settings)
                    .orEmpty()
                    .mapNotNull { guid ->
                        val addr = guid.substringAfterLast(";")
                        normalizeAddress(addr).takeIf { it.isNotBlank() }
                    }
                    .toSet()

                val url = "${settings.apiRoot}/contact?password=${encode(settings.guidAuthKey)}&extraProperties=avatar"
                client.newCall(Request.Builder().url(url).get().build()).execute().use { resp ->
                    if (!resp.isSuccessful) {
                        PersistentLog.w(context, TAG, "syncContacts HTTP ${resp.code}")
                        return@launch
                    }
                    val root = JsonParser.parseString(resp.body?.string() ?: "{}").asObjOrNull() ?: return@launch
                    val data = root.arr("data") ?: return@launch

                    data class ContactRecord(
                        val displayName: String,
                        val avatarB64: String?,
                        val addresses: List<Pair<String, String>>, // (raw, norm)
                        val isPinned: Boolean
                    )

                    val records = mutableListOf<ContactRecord>()
                    for (elem in data) {
                        val c = elem.asObjOrNull() ?: continue
                        val displayName = c.str("displayName")?.takeIf { it.isNotBlank() }
                            ?: listOfNotNull(c.str("firstName"), c.str("lastName"))
                                .joinToString(" ").trim().takeIf { it.isNotBlank() }
                            ?: continue
                        val avatarB64 = c.str("avatar")
                        val addresses = mutableListOf<Pair<String, String>>()
                        c.arr("phoneNumbers")?.forEach { p ->
                            p.asObjOrNull()?.str("address")?.let { raw ->
                                val norm = normalizeAddress(raw)
                                if (norm.isNotBlank()) addresses.add(raw to norm)
                            }
                        }
                        c.arr("emails")?.forEach { em ->
                            em.asObjOrNull()?.str("address")?.let { raw ->
                                val norm = normalizeAddress(raw)
                                if (norm.isNotBlank()) addresses.add(raw to norm)
                            }
                        }
                        if (addresses.isEmpty()) continue
                        val isPinned = addresses.any { (_, norm) -> norm in pinnedAddresses }
                        records.add(ContactRecord(displayName, avatarB64, addresses, isPinned))
                    }

                    // Push pinned/favorite contacts first so their photos always reach the watch.
                    records.sortByDescending { it.isPinned }

                    val out = JsonArray()
                    var avatarPushCount = 0
                    for (rec in records) {
                        var compressedAvatar: ByteArray? = null
                        if (!rec.avatarB64.isNullOrBlank() && (rec.isPinned || avatarPushCount < 80)) {
                            try {
                                val rawBytes = Base64.decode(rec.avatarB64, Base64.DEFAULT)
                                compressedAvatar = compressAvatarForWatch(rawBytes)
                            } catch (_: Exception) {
                            }
                        }
                        for ((raw, norm) in rec.addresses) {
                            out.add(JsonObject().apply {
                                addProperty("normalizedAddress", norm)
                                addProperty("displayName", rec.displayName)
                                addProperty("rawAddress", raw)
                                addProperty("hasAvatar", compressedAvatar != null)
                            })
                            if (compressedAvatar != null && (rec.isPinned || avatarPushCount < 80)) {
                                try {
                                    putAvatarAsset(context, norm, compressedAvatar)
                                    avatarPushCount++
                                } catch (_: Exception) {
                                }
                            }
                        }
                    }
                    val payloadBytes = JsonObject().apply { add("contacts", out) }.toString().toByteArray()
                    if (payloadBytes.size <= 60_000) {
                        sendToWatch(context, targetNodeId, PATH_SYNC_CONTACTS, payloadBytes)
                    } else {
                        val putReq = PutDataMapRequest.create(PATH_SYNC_CONTACTS).apply {
                            dataMap.putAsset("contactsAsset", Asset.createFromBytes(payloadBytes))
                            dataMap.putLong("updatedAt", System.currentTimeMillis())
                        }.asPutDataRequest().setUrgent()
                        Wearable.getDataClient(context).putDataItem(putReq).await()
                    }
                }
            } catch (e: Exception) {
                PersistentLog.e(context, TAG, "syncContacts error: ${e.message}")
            }
        }
    }

    fun sendTextMessage(
        context: Context,
        nodeId: String,
        chatGuid: String,
        text: String,
        tempGuid: String,
        requestId: String
    ) {
        scope.launch {
            val settings = SettingsHelper(context)
            if (!settings.hasServerUrl() || !settings.hasAuthKey()) {
                sendResult(context, nodeId, requestId, tempGuid, false, "Phone server not configured")
                return@launch
            }
            try {
                val client = buildOkHttpClient(settings, minReadTimeoutMs = 130_000L)
                val body = JsonObject().apply {
                    addProperty("chatGuid", chatGuid)
                    addProperty("tempGuid", tempGuid)
                    addProperty("message", text)
                    if (settings.enablePrivateAPI && settings.privateAPISend) {
                        addProperty("method", "private-api")
                    }
                }.toString().toRequestBody(jsonMediaType)
                val url = "${settings.apiRoot}/message/text?password=${encode(settings.guidAuthKey)}"
                client.newCall(Request.Builder().url(url).post(body).build()).execute().use { resp ->
                    val ok = resp.isSuccessful
                    val bodyStr = resp.body?.string()
                    val msgObj = try {
                        JsonParser.parseString(bodyStr ?: "{}").asObjOrNull()?.obj("data")
                            ?.let { mapMessageToRelayJson(it, chatGuid) }
                    } catch (_: Exception) {
                        null
                    }
                    sendResult(
                        context,
                        nodeId,
                        requestId,
                        tempGuid,
                        ok,
                        if (ok) null else "HTTP ${resp.code}",
                        msgObj
                    )
                }
            } catch (e: Exception) {
                sendResult(context, nodeId, requestId, tempGuid, false, e.message ?: "Send failed")
            }
        }
    }

    fun sendReaction(
        context: Context,
        nodeId: String,
        chatGuid: String,
        selectedMessageGuid: String,
        reaction: String,
        partIndex: Int,
        requestId: String
    ) {
        scope.launch {
            val settings = SettingsHelper(context)
            if (!settings.hasServerUrl() || !settings.hasAuthKey()) {
                sendResult(context, nodeId, requestId, null, false, "Phone server not configured")
                return@launch
            }
            try {
                val client = buildOkHttpClient(settings, minReadTimeoutMs = 60_000L)
                val body = JsonObject().apply {
                    addProperty("chatGuid", chatGuid)
                    addProperty("selectedMessageGuid", selectedMessageGuid)
                    addProperty("reaction", reaction)
                    addProperty("partIndex", partIndex)
                }.toString().toRequestBody(jsonMediaType)
                val url = "${settings.apiRoot}/message/react?password=${encode(settings.guidAuthKey)}"
                client.newCall(Request.Builder().url(url).post(body).build()).execute().use { resp ->
                    sendResult(context, nodeId, requestId, null, resp.isSuccessful, if (resp.isSuccessful) null else "HTTP ${resp.code}")
                }
            } catch (e: Exception) {
                sendResult(context, nodeId, requestId, null, false, e.message ?: "Reaction failed")
            }
        }
    }

    fun sendAudioAttachment(
        context: Context,
        nodeId: String,
        chatGuid: String,
        tempGuid: String,
        audioFile: File
    ) {
        scope.launch {
            try {
                val settings = SettingsHelper(context)
                if (!settings.hasServerUrl() || !settings.hasAuthKey()) {
                    sendResult(context, nodeId, tempGuid, tempGuid, false, "Phone server not configured")
                    return@launch
                }
                val client = buildOkHttpClient(settings, minReadTimeoutMs = 130_000L)
                val method = if (settings.enablePrivateAPI && settings.privateAPIAttachmentSend) {
                    "private-api"
                } else {
                    "apple-script"
                }
                val multipart = MultipartBody.Builder()
                    .setType(MultipartBody.FORM)
                    .addFormDataPart("chatGuid", chatGuid)
                    .addFormDataPart("tempGuid", tempGuid)
                    .addFormDataPart("name", audioFile.name.ifBlank { "Audio Message.m4a" })
                    .addFormDataPart("method", method)
                    .addFormDataPart("isAudioMessage", "true")
                    .addFormDataPart(
                        "attachment",
                        audioFile.name.ifBlank { "Audio Message.m4a" },
                        audioFile.asRequestBody("audio/mp4".toMediaType())
                    )
                    .build()
                val url = "${settings.apiRoot}/message/attachment?password=${encode(settings.guidAuthKey)}"
                client.newCall(Request.Builder().url(url).post(multipart).build()).execute().use { resp ->
                    val ok = resp.isSuccessful
                    val msgObj = try {
                        JsonParser.parseString(resp.body?.string() ?: "{}").asObjOrNull()?.obj("data")
                            ?.let { mapMessageToRelayJson(it, chatGuid) }
                    } catch (_: Exception) {
                        null
                    }
                    sendResult(context, nodeId, tempGuid, tempGuid, ok, if (ok) null else "HTTP ${resp.code}", msgObj)
                }
            } catch (e: Exception) {
                sendResult(context, nodeId, tempGuid, tempGuid, false, e.message ?: "Audio upload failed")
            } finally {
                audioFile.delete()
            }
        }
    }

    fun streamAttachmentToWatch(context: Context, nodeId: String, attachmentGuid: String) {
        scope.launch {
            val settings = SettingsHelper(context)
            if (!settings.hasServerUrl() || !settings.hasAuthKey()) return@launch
            val channelClient = Wearable.getChannelClient(context)
            var channel: com.google.android.gms.wearable.ChannelClient.Channel? = null
            try {
                val client = buildOkHttpClient(settings)
                val url = "${settings.apiRoot}/attachment/${encode(attachmentGuid)}/download?password=${encode(settings.guidAuthKey)}"
                client.newCall(Request.Builder().url(url).get().build()).execute().use { resp ->
                    if (!resp.isSuccessful) {
                        PersistentLog.w(context, TAG, "Attachment download HTTP ${resp.code}")
                        return@launch
                    }
                    val input = resp.body?.byteStream() ?: return@launch
                    channel = channelClient.openChannel(nodeId, "$PATH_ATTACHMENT_PREFIX${encode(attachmentGuid)}").await()
                    val out = channelClient.getOutputStream(channel!!).await()
                    out.use { stream ->
                        input.copyTo(stream, bufferSize = 16 * 1024)
                        stream.flush()
                    }
                }
            } catch (e: Exception) {
                PersistentLog.e(context, TAG, "streamAttachmentToWatch error: ${e.message}")
            } finally {
                channel?.let { ch ->
                    try {
                        channelClient.close(ch).await()
                    } catch (_: Exception) {
                    }
                }
            }
        }
    }

    fun handleMarkReadFromWatch(context: Context, chatGuid: String) {
        if (chatGuid.isBlank()) return
        cancelNotificationsForChat(context, chatGuid)
        DartWorkManager.createWorker(context, "MarkChatRead", hashMapOf("chatGuid" to chatGuid)) {}
        scope.launch {
            try {
                val settings = SettingsHelper(context)
                if (!settings.hasServerUrl() || !settings.hasAuthKey()) return@launch
                val client = buildOkHttpClient(settings)
                val url = "${settings.apiRoot}/chat/${encode(chatGuid)}/read?password=${encode(settings.guidAuthKey)}"
                client.newCall(Request.Builder().url(url).post("{}".toRequestBody(jsonMediaType)).build()).execute().close()
            } catch (e: Exception) {
                PersistentLog.w(context, TAG, "markRead HTTP failed: ${e.message}")
            }
        }
    }

    fun handleDismissFromWatch(context: Context, chatGuid: String) {
        if (chatGuid.isBlank()) return
        cancelNotificationsForChat(context, chatGuid)
    }

    fun forwardTyping(context: Context, chatGuid: String, isTyping: Boolean) {
        if (chatGuid.isBlank()) return
        scope.launch {
            try {
                val settings = SettingsHelper(context)
                if (!settings.hasServerUrl() || !settings.hasAuthKey()) return@launch
                val client = buildOkHttpClient(settings)
                val url = "${settings.apiRoot}/chat/${encode(chatGuid)}/typing?password=${encode(settings.guidAuthKey)}"
                val req = if (isTyping) {
                    Request.Builder().url(url).post("{}".toRequestBody(jsonMediaType)).build()
                } else {
                    Request.Builder().url(url).delete().build()
                }
                client.newCall(req).execute().close()
            } catch (_: Exception) {
            }
        }
    }

    fun setWatchActive(context: Context, active: Boolean) {
        if (active) {
            startSocketRelay(context.applicationContext)
        } else {
            stopSocketRelay()
        }
    }

    @Synchronized
    private fun startSocketRelay(context: Context) {
        socketTimeoutJob?.cancel()
        socketTimeoutJob = scope.launch {
            delay(SOCKET_IDLE_TIMEOUT_MS)
            stopSocketRelay()
        }
        if (relaySocket?.connected() == true) return
        val settings = SettingsHelper(context)
        if (!settings.hasServerUrl() || !settings.hasAuthKey()) return
        try {
            relaySocket?.disconnect()
            relaySocket?.off()
            val extraHeaders = mutableMapOf<String, List<String>>()
            settings.getAllHeaders().forEach { (k, v) -> extraHeaders[k] = listOf(v) }
            val opts = IO.Options.builder()
                .setQuery("guid=${encode(settings.guidAuthKey)}")
                .setTransports(arrayOf("websocket", "polling"))
                .setReconnection(true)
                .setExtraHeaders(extraHeaders)
                .build()
            val sock = IO.socket(settings.origin, opts)
            sock.on("new-message") { args ->
                val raw = args.firstOrNull() as? JSONObject ?: return@on
                scope.launch {
                    val obj = JsonParser.parseString(raw.toString()).asObjOrNull() ?: return@launch
                    val chatGuid = obj.arr("chats")?.firstOrNull()?.asObjOrNull()?.str("guid") ?: return@launch
                    val dto = mapMessageToRelayJson(obj, chatGuid)
                    sendMessageToWatchNodes(context, PATH_NEW_MESSAGE, dto.toString().toByteArray())
                }
            }
            sock.on("updated-message") { args ->
                val raw = args.firstOrNull() as? JSONObject ?: return@on
                scope.launch {
                    val obj = JsonParser.parseString(raw.toString()).asObjOrNull() ?: return@launch
                    val chatGuid = obj.arr("chats")?.firstOrNull()?.asObjOrNull()?.str("guid") ?: return@launch
                    val dto = mapMessageToRelayJson(obj, chatGuid)
                    sendMessageToWatchNodes(context, PATH_UPDATED_MESSAGE, dto.toString().toByteArray())
                }
            }
            sock.on("typing-indicator") { args ->
                val raw = args.firstOrNull() as? JSONObject ?: return@on
                val guid = raw.optString("guid", "")
                if (guid.isNotBlank()) {
                    val payload = JsonObject().apply {
                        addProperty("chatGuid", guid)
                        addProperty("isTyping", raw.optBoolean("display", false))
                    }.toString().toByteArray()
                    scope.launch { sendMessageToWatchNodes(context, PATH_TYPING_INDICATOR, payload) }
                }
            }
            sock.on("pinned-chats-updated") {
                syncChats(context)
            }
            sock.connect()
            relaySocket = sock
        } catch (e: Exception) {
            PersistentLog.w(context, TAG, "startSocketRelay failed: ${e.message}")
        }
    }

    @Synchronized
    private fun stopSocketRelay() {
        socketTimeoutJob?.cancel()
        socketTimeoutJob = null
        try {
            relaySocket?.disconnect()
            relaySocket?.off()
        } catch (_: Exception) {
        }
        relaySocket = null
    }

    internal fun shouldCancelSummary(
        activeTagsAndIds: List<Pair<String?, Int>>,
        summaryTag: String = com.bluebubbles.messaging.Constants.newMessageNotificationTag
    ): Boolean {
        val hasSummary = activeTagsAndIds.any { it.first == summaryTag && it.second == 0 }
        val hasChildren = activeTagsAndIds.any { it.first == summaryTag && it.second != 0 }
        return hasSummary && !hasChildren
    }

    private fun cancelNotificationsForChat(context: Context, chatGuid: String) {
        try {
            val nm = context.getSystemService(NotificationManager::class.java) ?: return
            val cancelled = mutableListOf<Pair<String?, Int>>()
            for (sbn in nm.activeNotifications) {
                if (sbn.notification.extras?.getString("chatGuid") == chatGuid) {
                    nm.cancel(sbn.tag, sbn.id)
                    cancelled.add(sbn.tag to sbn.id)
                }
            }
            if (cancelled.isNotEmpty()) {
                val remaining = nm.activeNotifications
                    .map { it.tag to it.id }
                    .filterNot { it in cancelled }
                val summaryTag = com.bluebubbles.messaging.Constants.newMessageNotificationTag
                if (shouldCancelSummary(remaining, summaryTag)) {
                    nm.cancel(summaryTag, 0)
                }
            }
        } catch (e: Exception) {
            PersistentLog.w(context, TAG, "cancelNotificationsForChat failed: ${e.message}")
        }
    }

    private suspend fun putAvatarAsset(context: Context, normalizedKey: String, bytes: ByteArray) {
        val safeKey = Uri.encode(normalizedKey)
        val req = PutDataMapRequest.create("$PATH_AVATAR_PREFIX$safeKey").apply {
            dataMap.putString("key", normalizedKey)
            dataMap.putAsset("avatar", Asset.createFromBytes(bytes))
            dataMap.putLong("updatedAt", System.currentTimeMillis())
        }.asPutDataRequest()
        Wearable.getDataClient(context).putDataItem(req).await()
    }

    private suspend fun sendResult(
        context: Context,
        nodeId: String,
        requestId: String,
        tempGuid: String?,
        success: Boolean,
        error: String?,
        message: JsonObject? = null
    ) {
        val obj = JsonObject().apply {
            addProperty("requestId", requestId)
            addProperty("tempGuid", tempGuid)
            addProperty("success", success)
            if (error != null) addProperty("error", error)
            if (message != null) add("message", message)
        }
        try {
            Wearable.getMessageClient(context)
                .sendMessage(nodeId, PATH_SEND_RESULT, obj.toString().toByteArray())
                .await()
        } catch (_: Exception) {
        }
    }

    private suspend fun sendToWatch(context: Context, targetNodeId: String?, path: String, payload: ByteArray) {
        if (targetNodeId != null) {
            Wearable.getMessageClient(context).sendMessage(targetNodeId, path, payload).await()
        } else {
            sendMessageToWatchNodes(context, path, payload)
        }
    }

    private suspend fun sendMessageToWatchNodes(context: Context, path: String, payload: ByteArray) {
        try {
            val nodes = Wearable.getNodeClient(context).connectedNodes.await()
            val msgClient = Wearable.getMessageClient(context)
            for (node in nodes) {
                try {
                    msgClient.sendMessage(node.id, path, payload).await()
                } catch (_: Exception) {
                }
            }
        } catch (e: Exception) {
            PersistentLog.w(context, TAG, "sendMessageToWatchNodes($path) failed: ${e.message}")
        }
    }

    private fun buildOkHttpClient(settings: SettingsHelper, minReadTimeoutMs: Long = 15_000L): OkHttpClient {
        val timeout = settings.apiTimeout.toLong().coerceAtLeast(15_000L)
        val readTimeout = timeout.coerceAtLeast(minReadTimeoutMs)
        val headersInterceptor = Interceptor { chain ->
            val builder = chain.request().newBuilder()
            settings.getAllHeaders().forEach { (k, v) -> builder.addHeader(k, v) }
            chain.proceed(builder.build())
        }
        return OkHttpClient.Builder()
            .connectTimeout(timeout, TimeUnit.MILLISECONDS)
            .readTimeout(readTimeout, TimeUnit.MILLISECONDS)
            .writeTimeout(timeout, TimeUnit.MILLISECONDS)
            .addInterceptor(headersInterceptor)
            .build()
    }

    private fun mapMessageToRelayJson(msg: JsonObject, chatGuid: String): JsonObject {
        val atts = msg.arr("attachments")
        val firstAtt = if (atts != null && atts.size() > 0) atts[0].asObjOrNull() else null
        return JsonObject().apply {
            addProperty("guid", msg.str("guid") ?: UUID.randomUUID().toString())
            addProperty("chatGuid", chatGuid)
            addProperty("text", msg.str("text"))
            addProperty("isFromMe", msg.bool("isFromMe") ?: false)
            addProperty("dateCreated", msg.long("dateCreated") ?: System.currentTimeMillis())
            msg.long("dateDelivered")?.let { addProperty("dateDelivered", it) }
            msg.long("dateRead")?.let { addProperty("dateRead", it) }
            addProperty("handleAddress", msg.obj("handle")?.str("address"))
            addProperty("attachmentGuid", firstAtt?.str("guid"))
            addProperty("attachmentMimeType", firstAtt?.str("mimeType"))
            addProperty("associatedMessageGuid", msg.str("associatedMessageGuid"))
            addProperty("associatedMessageType", msg.str("associatedMessageType"))
        }
    }

    private fun normalizeAddress(address: String): String {
        val trimmed = address.trim()
        if (trimmed.contains("@")) return trimmed.lowercase()
        val digits = trimmed.filter { it.isDigit() }
        return if (digits.length == 11 && digits.startsWith("1")) digits.substring(1) else digits
    }

    private fun encode(v: String): String = URLEncoder.encode(v, "UTF-8")

    private fun JsonElement?.asObjOrNull(): JsonObject? =
        if (this != null && this.isJsonObject) this.asJsonObject else null

    private fun JsonObject.obj(key: String): JsonObject? {
        val el = get(key)
        return if (el != null && el.isJsonObject) el.asJsonObject else null
    }

    private fun JsonObject.arr(key: String): JsonArray? {
        val el = get(key)
        return if (el != null && el.isJsonArray) el.asJsonArray else null
    }

    private fun JsonObject.str(key: String): String? {
        val el = get(key)
        return if (el != null && el.isJsonPrimitive) el.asString else null
    }

    private fun JsonObject.long(key: String): Long? {
        val el = get(key)
        return if (el != null && el.isJsonPrimitive) el.asLong else null
    }

    private fun JsonObject.int(key: String): Int? {
        val el = get(key)
        return if (el != null && el.isJsonPrimitive) el.asInt else null
    }

    private fun JsonObject.bool(key: String): Boolean? {
        val el = get(key)
        return if (el != null && el.isJsonPrimitive) el.asBoolean else null
    }
}
