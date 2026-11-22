package com.bluebubbles.messaging.services.wear

import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Base64
import androidx.core.app.NotificationCompat
import java.io.ByteArrayOutputStream
import java.io.InputStream
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.MainActivity
import com.bluebubbles.messaging.R
import com.bluebubbles.messaging.services.backend_ui_interop.DartWorkManager
import com.bluebubbles.messaging.services.foreground.SocketIOForegroundService
import com.bluebubbles.messaging.services.notifications.NotificationChannelHandler
import com.bluebubbles.messaging.utils.PersistentLog
import com.bluebubbles.messaging.utils.SettingsHelper
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
import io.socket.emitter.Emitter
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.tasks.await
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.File
import java.net.URI
import java.net.URLEncoder
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

object WearSyncManager {
    private const val TAG = "WearSyncManager"
    const val WATCH_CAPABILITY = "bluebubbles_watch_app"
    internal const val PAYLOAD_MESSAGE_MAX_BYTES = 60_000
    private const val ASSET_KEY_PAYLOAD = "payload"
    private const val PREFS_NAME = "wear_sync_prefs"
    private const val KEY_WATCH_CONNECTED = "watch_connected"
    private const val KEY_WATCH_CHECKED_AT = "watch_checked_at"
    private const val KEY_WATCH_ACTIVE_UNTIL_MS = "watch_active_until_ms"
    private const val KEY_CALL_TELEPHONY_PREFIX = "call_telephony_"
    private const val KEY_CALL_META_PREFIX = "call_meta_"
    private const val CALL_META_TTL_MS = 5 * 60_000L
    internal const val SOCKET_IDLE_TIMEOUT_MS = 120_000L
    private const val FORWARD_DEDUP_WINDOW_MS = 30_000L

    const val PATH_CREDENTIALS = "/bb/credentials"
    const val PATH_PROFILE = "/bb/profile"
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
    const val PATH_ATTACHMENT_FAILED = "/bb/attachment-failed"
    const val PATH_AUDIO_FAILED = "/bb/audio-failed"
    const val PATH_AVATAR_PREFIX = "/bb/avatar/"
    const val PATH_MARK_READ = "/bb/mark-read"
    const val PATH_DISMISS_NOTIFICATION = "/bb/dismiss-notification"
    const val PATH_WATCH_ACTIVE = "/bb/watch-active"
    const val PATH_INCOMING_CALL = "/bb/incoming-call"
    const val PATH_CALL_ENDED = "/bb/call-ended"
    const val PATH_ANSWER_CALL_AUDIO = "/bb/answer-call-audio"
    const val PATH_DECLINE_CALL = "/bb/decline-call"
    const val PATH_OPEN_CHAT = "/bb/open-chat"
    const val PATH_TRANSLATE_MESSAGE = "/bb/translate-message"

    private data class IncomingCallMeta(
        val callerName: String,
        val callerAddress: String?,
        val isVideo: Boolean,
        val isTelephony: Boolean = false
    )

    internal const val WATCH_IMAGE_MAX_DIM = 512
    internal const val WATCH_IMAGE_MAX_BYTES = 256 * 1024
    internal const val WATCH_GIF_PASSTHROUGH_MAX_BYTES = 768 * 1024
    internal const val WATCH_IMAGE_MAX_READ_BYTES = 12 * 1024 * 1024
    internal const val WATCH_AUDIO_MAX_BYTES = 2 * 1024 * 1024

    internal enum class WatchAttachmentAction {
        COMPRESS_STATIC_IMAGE,
        GIF_PASSTHROUGH_OR_PREVIEW,
        STREAM_BOUNDED_AUDIO,
        REJECT
    }

    private val incomingCalls = ConcurrentHashMap<String, IncomingCallMeta>()
    private val watchAnsweredCalls = ConcurrentHashMap.newKeySet<String>()
    private val endedCalls = ConcurrentHashMap<String, Long>()
    private val inFlightAttachments = ConcurrentHashMap.newKeySet<String>()
    private val attachmentSemaphore = Semaphore(2)

    internal val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val gson = Gson()
    private val jsonMediaType = "application/json; charset=utf-8".toMediaType()

    @Volatile
    private var relaySocket: Socket? = null
    @Volatile
    private var ownsRelaySocket: Boolean = false
    @Volatile
    private var relaySocketOrigin: String = ""
    @Volatile
    private var watchActiveUntilMs: Long = 0L
    private val recentForwardedMessages = ConcurrentHashMap<String, Long>()
    private val relayListeners = mutableListOf<Pair<String, Emitter.Listener>>()
    private var socketTimeoutJob: Job? = null
    internal val sharedRelayOkHttpClient: OkHttpClient by lazy {
        SocketIOForegroundService.buildSocketOkHttpClient()
    }

    @JvmStatic
    fun updateWatchConnectedCache(context: Context, connected: Boolean) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_WATCH_CONNECTED, connected)
            .putLong(KEY_WATCH_CHECKED_AT, System.currentTimeMillis())
            .apply()
    }

    @JvmStatic
    fun notifyDismissed(context: Context, chatGuid: String) {
        if (chatGuid.isBlank()) return
        scope.launch {
            val payload = JsonObject().apply { addProperty("chatGuid", chatGuid) }.toString()
            sendMessageToWatchNodes(context, PATH_DISMISS_NOTIFICATION, payload.toByteArray())
        }
    }

    private fun persistIncomingCallMeta(context: Context, callUuid: String, meta: IncomingCallMeta) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        val json = JsonObject().apply {
            addProperty("callerName", meta.callerName)
            if (!meta.callerAddress.isNullOrBlank()) {
                addProperty("callerAddress", meta.callerAddress)
            }
            addProperty("isVideo", meta.isVideo)
            addProperty("isTelephony", meta.isTelephony)
            addProperty("savedAtMs", now)
        }.toString()
        val editor = prefs.edit().putString(KEY_CALL_META_PREFIX + callUuid, json)
        // Prune stale call metadata entries so prefs don't accumulate across process deaths.
        for ((k, v) in prefs.all) {
            if (k.startsWith(KEY_CALL_META_PREFIX) && k != KEY_CALL_META_PREFIX + callUuid && v is String) {
                val savedAt = try {
                    JsonParser.parseString(v).asJsonObject.get("savedAtMs")?.asLong ?: 0L
                } catch (_: Exception) {
                    0L
                }
                if (now - savedAt > CALL_META_TTL_MS) {
                    editor.remove(k)
                }
            }
        }
        editor.apply()
    }

    private fun takePersistedIncomingCallMeta(context: Context, callUuid: String): IncomingCallMeta? {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val metaKey = KEY_CALL_META_PREFIX + callUuid
        val legacyKey = KEY_CALL_TELEPHONY_PREFIX + callUuid
        val raw = prefs.getString(metaKey, null)
        val hasLegacy = prefs.contains(legacyKey)
        val legacyTelephony = if (hasLegacy) prefs.getBoolean(legacyKey, false) else false
        if (raw != null || hasLegacy) {
            prefs.edit().remove(metaKey).remove(legacyKey).apply()
        }
        if (raw != null) {
            try {
                val obj = JsonParser.parseString(raw).asJsonObject
                val savedAt = obj.get("savedAtMs")?.asLong ?: 0L
                if (System.currentTimeMillis() - savedAt <= CALL_META_TTL_MS) {
                    return IncomingCallMeta(
                        callerName = obj.get("callerName")?.takeIf { !it.isJsonNull }?.asString ?: "Unknown Caller",
                        callerAddress = obj.get("callerAddress")?.takeIf { !it.isJsonNull }?.asString,
                        isVideo = obj.get("isVideo")?.takeIf { !it.isJsonNull }?.asBoolean ?: false,
                        isTelephony = obj.get("isTelephony")?.takeIf { !it.isJsonNull }?.asBoolean ?: false
                    )
                }
            } catch (_: Exception) {
            }
        }
        return if (hasLegacy) {
            IncomingCallMeta(
                callerName = "Unknown Caller",
                callerAddress = null,
                isVideo = false,
                isTelephony = legacyTelephony
            )
        } else {
            null
        }
    }

    @JvmStatic
    fun notifyIncomingCall(
        context: Context,
        callUuid: String,
        callerName: String,
        callerAddress: String?,
        isVideo: Boolean,
        isTelephony: Boolean = false
    ) {
        if (callUuid.isBlank()) return
        endedCalls.remove(callUuid)
        val meta = IncomingCallMeta(callerName, callerAddress, isVideo, isTelephony)
        incomingCalls[callUuid] = meta
        persistIncomingCallMeta(context, callUuid, meta)
        scope.launch {
            val payload = JsonObject().apply {
                addProperty("callUuid", callUuid)
                addProperty("callerName", callerName)
                if (!callerAddress.isNullOrBlank()) {
                    addProperty("callerAddress", callerAddress)
                }
                addProperty("isVideo", isVideo)
                addProperty("isTelephony", isTelephony)
            }.toString()
            sendMessageToWatchNodes(context, PATH_INCOMING_CALL, payload.toByteArray())
        }
    }

    @JvmStatic
    fun notifyCallEnded(context: Context, callUuid: String) {
        if (callUuid.isBlank()) return
        incomingCalls.remove(callUuid)
        watchAnsweredCalls.remove(callUuid)
        takePersistedIncomingCallMeta(context, callUuid)
        val now = System.currentTimeMillis()
        endedCalls.entries.removeIf { now - it.value > CALL_META_TTL_MS }
        if (endedCalls.putIfAbsent(callUuid, now) != null) return
        scope.launch {
            val payload = JsonObject().apply { addProperty("callUuid", callUuid) }.toString()
            sendMessageToWatchNodes(context, PATH_CALL_ENDED, payload.toByteArray())
        }
    }

    @JvmStatic
    fun notifyCallEndedIfNotWatchAnswered(context: Context, callUuid: String) {
        if (callUuid.isBlank() || watchAnsweredCalls.contains(callUuid)) return
        notifyCallEnded(context, callUuid)
    }

    fun handleAnswerCallAudioFromWatch(
        context: Context,
        callUuid: String,
        callerNameArg: String? = null,
        callerAddressArg: String? = null,
        isTelephonyArg: Boolean? = null
    ) {
        if (callUuid.isBlank()) return
        val cached = incomingCalls.remove(callUuid) ?: takePersistedIncomingCallMeta(context, callUuid)
        watchAnsweredCalls.add(callUuid)
        val callerName = callerNameArg?.takeIf { it.isNotBlank() }
            ?: cached?.callerName
            ?: "Unknown Caller"
        val callerAddress = callerAddressArg?.takeIf { it.isNotBlank() } ?: cached?.callerAddress
        val isTelephony = isTelephonyArg ?: cached?.isTelephony ?: false
        cancelCallNotifications(context, callUuid)
        val routed = com.bluebubbles.messaging.services.telecom.FaceTimeConnectionService.addIncomingCall(
            context = context,
            callUuid = callUuid,
            callerName = callerName,
            address = callerAddress,
            autoAnswer = true,
            isTelephony = isTelephony
        )
        if (!routed) {
            val launch = Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                putExtra("callUuid", callUuid)
                putExtra("answer", true)
                putExtra("audioOnly", true)
                putExtra("isTelephony", isTelephony)
                putExtra("caller", callerName)
                type = "AnswerFaceTime"
            }
            launchActivityOrNotify(
                context = context,
                intent = launch,
                notificationId = callUuid.hashCode(),
                title = callerName.ifBlank { "Incoming FaceTime Audio" },
                body = "Tap to answer call",
                channelId = NotificationChannelHandler.FACETIME_CHANNEL_ID,
                tag = Constants.newFaceTimeNotificationTag,
                highPriority = true
            )
        }
    }

    fun handleDeclineCallFromWatch(context: Context, callUuid: String) {
        if (callUuid.isBlank()) return
        incomingCalls.remove(callUuid)
        cancelCallNotifications(context, callUuid)
        com.bluebubbles.messaging.services.telecom.FaceTimeConnectionService.endCall(callUuid)
        notifyCallEnded(context, callUuid)
        if (com.bluebubbles.messaging.services.telecom.FaceTimeRoutingPolicy.shouldTriggerServerDecline(callUuid)) {
            com.bluebubbles.messaging.services.network.HttpService(context).declineFaceTimeCall(
                callUuid = callUuid,
                onSuccess = {},
                onError = {}
            )
        }
    }

    fun handleOpenChatFromWatch(context: Context, chatGuid: String) {
        if (chatGuid.isBlank()) return
        val launch = Intent(context, MainActivity::class.java).apply {
            addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
            putExtra("chatGuid", chatGuid)
            putExtra("bubble", false)
            type = "OpenChat"
        }
        launchActivityOrNotify(
            context = context,
            intent = launch,
            notificationId = chatGuid.hashCode(),
            title = "Open Chat",
            body = "Tap to open conversation",
            channelId = NotificationChannelHandler.NEW_MESSAGES_CHANNEL_ID,
            tag = Constants.newMessageNotificationTag,
            highPriority = false
        )
    }

    private fun launchActivityOrNotify(
        context: Context,
        intent: Intent,
        notificationId: Int,
        title: String,
        body: String,
        channelId: String,
        tag: String,
        highPriority: Boolean
    ) {
        try {
            context.startActivity(intent)
        } catch (e: Exception) {
            PersistentLog.w(context, TAG, "BAL blocked or activity launch failed (${e.message}); posting fallback notification")
            try {
                val pi = PendingIntent.getActivity(
                    context,
                    notificationId,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                val builder = NotificationCompat.Builder(context, channelId)
                    .setSmallIcon(R.mipmap.ic_launcher)
                    .setContentTitle(title)
                    .setContentText(body)
                    .setContentIntent(pi)
                    .setAutoCancel(true)
                    .setPriority(if (highPriority) NotificationCompat.PRIORITY_HIGH else NotificationCompat.PRIORITY_DEFAULT)
                if (highPriority) {
                    builder.setFullScreenIntent(pi, true)
                }
                context.getSystemService(NotificationManager::class.java)?.notify(tag, notificationId, builder.build())
            } catch (ne: Exception) {
                PersistentLog.e(context, TAG, "Fallback notification failed: ${ne.message}")
            }
        }
    }

    private fun cancelCallNotifications(context: Context, callUuid: String) {
        try {
            val nm = context.getSystemService(NotificationManager::class.java) ?: return
            for (sbn in nm.activeNotifications) {
                if (sbn.tag == Constants.newFaceTimeNotificationTag &&
                    sbn.notification.extras?.getString("callUuid") == callUuid
                ) {
                    nm.cancel(sbn.tag, sbn.id)
                }
            }
        } catch (e: Exception) {
            PersistentLog.w(context, TAG, "cancelCallNotifications failed: ${e.message}")
        }
    }

    fun syncCredentials(context: Context, targetNodeId: String? = null) {
        scope.launch {
            try {
                val settings = SettingsHelper(context)
                val origin = settings.origin
                val password = settings.guidAuthKey
                if (origin.isBlank() || password.isBlank()) {
                    Wearable.getDataClient(context)
                        .deleteDataItems(Uri.Builder().scheme("wear").path(PATH_CREDENTIALS).build())
                        .await()
                    return@launch
                }
                val headersJson = gson.toJson(settings.getAllHeaders())
                val privateApiSend = settings.enablePrivateAPI && settings.privateAPISend
                val privateMarkChatAsRead = settings.enablePrivateAPI && settings.privateMarkChatAsRead

                val putReq = PutDataMapRequest.create(PATH_CREDENTIALS).apply {
                    dataMap.putString("serverUrl", origin)
                    dataMap.putString("password", password)
                    dataMap.putString("customHeadersJson", headersJson)
                    dataMap.putBoolean("privateApiSend", privateApiSend)
                    dataMap.putBoolean("privateMarkChatAsRead", privateMarkChatAsRead)
                }.asPutDataRequest().setUrgent()
                Wearable.getDataClient(context).putDataItem(putReq).await()

                val msgJson = JsonObject().apply {
                    addProperty("serverUrl", origin)
                    addProperty("password", password)
                    addProperty("customHeadersJson", headersJson)
                    addProperty("privateApiSend", privateApiSend)
                    addProperty("privateMarkChatAsRead", privateMarkChatAsRead)
                }.toString().toByteArray()
                sendToWatch(context, targetNodeId, PATH_CREDENTIALS, msgJson)
                syncProfile(context, targetNodeId)
            } catch (e: Exception) {
                PersistentLog.e(context, TAG, "syncCredentials failed: ${e.message}")
            }
        }
    }

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

    internal fun compressSelfAvatarForWatch(rawBytes: ByteArray): ByteArray? =
        compressAvatarForWatch(rawBytes, maxDim = SELF_AVATAR_MAX_DIM, maxBytes = SELF_AVATAR_MAX_BYTES)

    fun syncProfile(context: Context, targetNodeId: String? = null) {
        scope.launch {
            val settings = SettingsHelper(context)
            try {
                var userName = settings.userName.trim().takeUnless { it.equals("You", ignoreCase = true) } ?: ""
                var userHandle = ""
                var rawAvatar: ByteArray? = settings.userAvatarPath
                    .takeIf { it.isNotBlank() }
                    ?.let { File(it).takeIf(File::exists)?.readBytes() }

                if (settings.hasServerUrl() && settings.hasAuthKey()) {
                    try {
                        val client = buildOkHttpClient(settings)
                        val url = "${settings.apiRoot}/icloud/contact?password=${encode(settings.guidAuthKey)}"
                        client.newCall(Request.Builder().url(url).get().build()).execute().use { resp ->
                            if (resp.isSuccessful) {
                                val root = JsonParser.parseString(resp.body?.string() ?: "{}").asObjOrNull()
                                val data = root?.obj("data")
                                if (data != null) {
                                    val serverName = data.str("display_name")?.takeIf { it.isNotBlank() }
                                        ?: data.str("account_name")?.takeIf { it.isNotBlank() }
                                        ?: data.str("name")?.takeIf { it.isNotBlank() }
                                        ?: listOfNotNull(
                                            data.str("first_name")?.takeIf { it.isNotBlank() },
                                            data.str("last_name")?.takeIf { it.isNotBlank() }
                                        ).joinToString(" ").trim()
                                    if (serverName.isNotBlank()) userName = serverName
                                    userHandle = data.str("active_alias")?.takeIf { it.isNotBlank() }
                                        ?: data.str("apple_id")?.takeIf { it.isNotBlank() }
                                        ?: ""
                                    decodeAvatarBase64(data.str("avatar"))?.let { rawAvatar = it }
                                }
                            }
                        }
                    } catch (e: Exception) {
                        PersistentLog.w(context, TAG, "syncProfile server fetch failed: ${e.message}")
                    }
                }

                val compressedAvatar = rawAvatar?.let { compressSelfAvatarForWatch(it) }
                if (userName.isBlank() && userHandle.isBlank() && compressedAvatar == null) return@launch

                val avatarHash = compressedAvatar?.let(::sha256Hex) ?: ""
                val putReq = PutDataMapRequest.create(PATH_PROFILE).apply {
                    dataMap.putString("userName", userName)
                    dataMap.putString("userHandle", userHandle)
                    dataMap.putString("avatarHash", avatarHash)
                    if (compressedAvatar != null) {
                        dataMap.putAsset("avatar", Asset.createFromBytes(compressedAvatar))
                    }
                }.asPutDataRequest().setUrgent()
                Wearable.getDataClient(context).putDataItem(putReq).await()

                val msgJson = JsonObject().apply {
                    addProperty("userName", userName)
                    addProperty("userHandle", userHandle)
                    if (compressedAvatar != null) {
                        addProperty("avatarBase64", Base64.encodeToString(compressedAvatar, Base64.NO_WRAP))
                    }
                }.toString().toByteArray()
                if (msgJson.size <= PAYLOAD_MESSAGE_MAX_BYTES) {
                    sendToWatch(context, targetNodeId, PATH_PROFILE, msgJson)
                }
            } catch (e: Exception) {
                PersistentLog.e(context, TAG, "syncProfile failed: ${e.message}")
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
                sendJsonOrAsset(context, targetNodeId, PATH_SYNC_CHATS, PATH_SYNC_CHATS, payload)
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

            lastText = lastText?.take(300)

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

        entries.sortWith(
            compareByDescending<Entry> { it.isPinned }
                .thenBy { it.pinIndex == null }
                .thenBy { it.pinIndex }
                .thenByDescending { it.lastMessageDate }
        )
        return entries.map { it.relayJson }
    }

    private suspend fun syncChatIcons(
        context: Context,
        settings: SettingsHelper,
        client: OkHttpClient,
        targets: List<Pair<String, String>>
    ) = coroutineScope {
        val semaphore = Semaphore(4)
        targets.map { (chatGuid, avatarKey) ->
            async {
                semaphore.withPermit {
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
        }.awaitAll()
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
                    sendJsonOrAsset(
                        context,
                        targetNodeId,
                        PATH_SYNC_MESSAGES,
                        "$PATH_SYNC_MESSAGES/${Uri.encode(chatGuid)}",
                        payload
                    )
                }
            } catch (e: Exception) {
                PersistentLog.e(context, TAG, "syncMessages error: ${e.message}")
            }
        }
    }

    private fun compressAvatarForWatch(
        rawBytes: ByteArray,
        maxDim: Int = 160,
        maxBytes: Int = 250_000
    ): ByteArray? {
        if (rawBytes.isEmpty()) return null
        return try {
            val decoded = BitmapFactory.decodeByteArray(rawBytes, 0, rawBytes.size)
            if (decoded == null) {
                rawBytes.takeIf { it.size <= maxBytes }
            } else {
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
            }
        } catch (_: Exception) {
            rawBytes.takeIf { it.size <= maxBytes }
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
                        for (field in listOf("phoneNumbers", "emails")) {
                            c.arr(field)?.forEach { item ->
                                item.asObjOrNull()?.str("address")?.let { raw ->
                                    val norm = normalizeAddress(raw)
                                    if (norm.isNotBlank()) addresses.add(raw to norm)
                                }
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
                        if (!rec.avatarB64.isNullOrBlank() && shouldPushContactAvatar(avatarPushCount)) {
                            try {
                                val rawBytes = Base64.decode(rec.avatarB64, Base64.DEFAULT)
                                compressedAvatar = compressAvatarForWatch(rawBytes)
                            } catch (_: Exception) {
                            }
                        }
                        for ((raw, norm) in rec.addresses) {
                            val canPushAvatar = compressedAvatar != null && shouldPushContactAvatar(avatarPushCount)
                            out.add(JsonObject().apply {
                                addProperty("normalizedAddress", norm)
                                addProperty("displayName", rec.displayName)
                                addProperty("rawAddress", raw)
                                addProperty("hasAvatar", canPushAvatar)
                            })
                            if (canPushAvatar) {
                                try {
                                    putAvatarAsset(context, norm, compressedAvatar!!)
                                    avatarPushCount++
                                } catch (_: Exception) {
                                }
                            }
                        }
                    }
                    val payloadBytes = JsonObject().apply { add("contacts", out) }.toString().toByteArray()
                    sendJsonOrAsset(context, targetNodeId, PATH_SYNC_CONTACTS, PATH_SYNC_CONTACTS, payloadBytes)
                }
            } catch (e: Exception) {
                PersistentLog.e(context, TAG, "syncContacts error: ${e.message}")
            }
        }
    }

    internal fun extractDmRecipientIfNewChatError(
        chatGuid: String,
        httpCode: Int,
        responseBody: String?
    ): String? {
        val idx = chatGuid.indexOf(";-;")
        if (idx < 0) return null
        val recipient = chatGuid.substring(idx + 3).trim()
        if (recipient.isBlank()) return null
        val isMissingChat = httpCode == 404 ||
            ((httpCode == 400 || httpCode == 500) && responseBody?.contains("does not exist", ignoreCase = true) == true)
        return if (isMissingChat) recipient else null
    }

    internal fun parseNewChatMessageResult(responseBody: String?, fallbackChatGuid: String): JsonObject? {
        return try {
            val dataObj = JsonParser.parseString(responseBody ?: "{}").asObjOrNull()?.obj("data")
                ?: return null
            val createdChatGuid = dataObj.str("guid")?.takeIf { it.isNotBlank() } ?: fallbackChatGuid
            val firstMsg = dataObj.arr("messages")?.firstOrNull()?.asObjOrNull() ?: return null
            mapMessageToRelayJson(firstMsg, createdChatGuid)
        } catch (_: Exception) {
            null
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
                val usePrivateApi = settings.enablePrivateAPI && settings.privateAPISend
                val body = JsonObject().apply {
                    addProperty("chatGuid", chatGuid)
                    addProperty("tempGuid", tempGuid)
                    addProperty("message", text)
                    if (usePrivateApi) {
                        addProperty("method", "private-api")
                    }
                }.toString().toRequestBody(jsonMediaType)
                val url = "${settings.apiRoot}/message/text?password=${encode(settings.guidAuthKey)}"
                client.newCall(Request.Builder().url(url).post(body).build()).execute().use { resp ->
                    val ok = resp.isSuccessful
                    val bodyStr = resp.body?.string()
                    if (!ok) {
                        val recipient = extractDmRecipientIfNewChatError(chatGuid, resp.code, bodyStr)
                        if (recipient != null) {
                            val newChatBody = JsonObject().apply {
                                add("addresses", JsonArray().apply { add(recipient) })
                                addProperty("message", text)
                                addProperty("tempGuid", tempGuid)
                                addProperty("method", if (usePrivateApi) "private-api" else "apple-script")
                            }.toString().toRequestBody(jsonMediaType)
                            val newChatUrl = "${settings.apiRoot}/chat/new?password=${encode(settings.guidAuthKey)}"
                            client.newCall(Request.Builder().url(newChatUrl).post(newChatBody).build()).execute().use { newResp ->
                                val newOk = newResp.isSuccessful
                                val newBodyStr = newResp.body?.string()
                                val newMsgObj = parseNewChatMessageResult(newBodyStr, chatGuid)
                                sendResult(
                                    context,
                                    nodeId,
                                    requestId,
                                    tempGuid,
                                    newOk,
                                    if (newOk) null else "HTTP ${newResp.code}",
                                    newMsgObj
                                )
                            }
                            return@launch
                        }
                    }
                    val msgObj = parseDataMessage(bodyStr, chatGuid)
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
        requestId: String,
        tempGuid: String? = null
    ) {
        scope.launch {
            val settings = SettingsHelper(context)
            if (!settings.hasServerUrl() || !settings.hasAuthKey()) {
                sendResult(context, nodeId, requestId, tempGuid, false, "Phone server not configured")
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
                    val ok = resp.isSuccessful
                    val msgObj = parseDataMessage(resp.body?.string(), chatGuid)
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
                sendResult(context, nodeId, requestId, tempGuid, false, e.message ?: "Reaction failed")
            }
        }
    }

    internal fun buildTranslateUrl(apiRoot: String, messageGuid: String, authKey: String): String =
        "$apiRoot/message/${encode(messageGuid).replace("+", "%20")}/translate?password=${encode(authKey)}"

    internal fun parseTranslationData(bodyStr: String?): JsonObject? = try {
        JsonParser.parseString(bodyStr ?: "{}").asObjOrNull()?.obj("data")?.obj("translation")
    } catch (_: Exception) {
        null
    }

    fun translateMessage(
        context: Context,
        nodeId: String,
        messageGuid: String,
        requestId: String? = null
    ) {
        scope.launch {
            val settings = SettingsHelper(context)
            if (!settings.hasServerUrl() || !settings.hasAuthKey()) {
                if (!requestId.isNullOrBlank()) {
                    sendResult(context, nodeId, requestId, null, false, "Phone server not configured")
                }
                return@launch
            }
            try {
                val client = buildOkHttpClient(settings)
                val url = buildTranslateUrl(settings.apiRoot, messageGuid, settings.guidAuthKey)
                val req = Request.Builder().url(url).post("{}".toRequestBody(jsonMediaType)).build()
                client.newCall(req).execute().use { resp ->
                    val ok = resp.isSuccessful
                    val bodyStr = resp.body?.string()
                    val rawTranslation = if (ok) parseTranslationData(bodyStr) else null
                    if (!requestId.isNullOrBlank()) {
                        sendResult(
                            context = context,
                            nodeId = nodeId,
                            requestId = requestId,
                            tempGuid = null,
                            success = ok,
                            error = if (ok) null else "HTTP ${resp.code}",
                            translation = rawTranslation
                        )
                    }
                }
            } catch (e: Exception) {
                PersistentLog.w(context, TAG, "translateMessage error: ${e.message}")
                if (!requestId.isNullOrBlank()) {
                    sendResult(context, nodeId, requestId, null, false, e.message ?: "Translation failed")
                }
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
                    val msgObj = parseDataMessage(resp.body?.string(), chatGuid)
                    sendResult(context, nodeId, tempGuid, tempGuid, ok, if (ok) null else "HTTP ${resp.code}", msgObj)
                }
            } catch (e: Exception) {
                sendResult(context, nodeId, tempGuid, tempGuid, false, e.message ?: "Audio upload failed")
            } finally {
                audioFile.delete()
            }
        }
    }

    suspend fun notifyAttachmentFailed(context: Context, nodeId: String, attachmentGuid: String) {
        sendNodeJson(context, nodeId, PATH_ATTACHMENT_FAILED, JsonObject().apply { addProperty("guid", attachmentGuid) })
    }

    suspend fun notifyAudioReceiveFailed(context: Context, nodeId: String, tempGuid: String, reason: String) {
        sendNodeJson(context, nodeId, PATH_AUDIO_FAILED, JsonObject().apply {
            addProperty("tempGuid", tempGuid)
            addProperty("reason", reason)
        })
    }

    internal fun buildWatchAttachmentDownloadUrl(apiRoot: String, attachmentGuid: String, authKey: String): String =
        "$apiRoot/attachment/${encode(attachmentGuid)}/download?password=${encode(authKey)}&width=$WATCH_IMAGE_MAX_DIM&quality=good"

    internal fun classifyWatchAttachment(mimeType: String?, contentLength: Long): WatchAttachmentAction {
        val mime = mimeType?.substringBefore(';')?.trim()?.lowercase().orEmpty()
        return when {
            mime == "image/gif" ->
                if (contentLength > WATCH_IMAGE_MAX_READ_BYTES) WatchAttachmentAction.REJECT
                else WatchAttachmentAction.GIF_PASSTHROUGH_OR_PREVIEW
            mime.startsWith("image/") ->
                if (contentLength > WATCH_IMAGE_MAX_READ_BYTES) WatchAttachmentAction.REJECT
                else WatchAttachmentAction.COMPRESS_STATIC_IMAGE
            mime.startsWith("audio/") ->
                if (contentLength > WATCH_AUDIO_MAX_BYTES) WatchAttachmentAction.REJECT
                else WatchAttachmentAction.STREAM_BOUNDED_AUDIO
            else -> WatchAttachmentAction.REJECT
        }
    }

    internal fun computeInSampleSize(width: Int, height: Int, maxDim: Int): Int {
        if (width <= 0 || height <= 0 || maxDim <= 0) return 1
        var sampleSize = 1
        val maxSide = maxOf(width, height)
        while ((maxSide / (sampleSize * 2)) >= maxDim) {
            sampleSize *= 2
        }
        return sampleSize
    }

    internal fun readBoundedBytes(input: InputStream, maxBytes: Int): ByteArray? {
        if (maxBytes <= 0) return null
        val out = ByteArrayOutputStream()
        val buf = ByteArray(16 * 1024)
        var total = 0
        while (true) {
            val read = input.read(buf)
            if (read == -1) break
            total += read
            if (total > maxBytes) return null
            out.write(buf, 0, read)
        }
        return out.toByteArray()
    }

    private fun compressWatchImage(
        rawBytes: ByteArray,
        maxDim: Int = WATCH_IMAGE_MAX_DIM,
        maxBytes: Int = WATCH_IMAGE_MAX_BYTES
    ): ByteArray? {
        if (rawBytes.isEmpty()) return null
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(rawBytes, 0, rawBytes.size, bounds)
            val decodeOpts = BitmapFactory.Options().apply {
                inSampleSize = computeInSampleSize(bounds.outWidth, bounds.outHeight, maxDim)
            }
            val decoded = BitmapFactory.decodeByteArray(rawBytes, 0, rawBytes.size, decodeOpts)
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
            try {
                val baos = ByteArrayOutputStream()
                for (quality in intArrayOf(78, 66, 55)) {
                    baos.reset()
                    current.compress(Bitmap.CompressFormat.JPEG, quality, baos)
                    val candidate = baos.toByteArray()
                    if (candidate.isNotEmpty() && candidate.size <= maxBytes) return candidate
                }
                val fallbackDim = 360
                if (current.width > fallbackDim || current.height > fallbackDim) {
                    val scale = fallbackDim.toFloat() / maxOf(current.width, current.height).toFloat()
                    val w = (current.width * scale).toInt().coerceAtLeast(1)
                    val h = (current.height * scale).toInt().coerceAtLeast(1)
                    val smaller = Bitmap.createScaledBitmap(current, w, h, true)
                    if (smaller !== current) current.recycle()
                    current = smaller
                    baos.reset()
                    current.compress(Bitmap.CompressFormat.JPEG, 55, baos)
                    val candidate = baos.toByteArray()
                    if (candidate.isNotEmpty() && candidate.size <= maxBytes) return candidate
                }
                null
            } finally {
                current.recycle()
            }
        } catch (_: Exception) {
            rawBytes.takeIf { it.size <= maxBytes }
        }
    }

    fun streamAttachmentToWatch(context: Context, nodeId: String, attachmentGuid: String) {
        scope.launch {
            val flightKey = "$nodeId|$attachmentGuid"
            if (!inFlightAttachments.add(flightKey)) return@launch
            try {
                val settings = SettingsHelper(context)
                if (!settings.hasServerUrl() || !settings.hasAuthKey()) {
                    notifyAttachmentFailed(context, nodeId, attachmentGuid)
                    return@launch
                }
                attachmentSemaphore.withPermit {
                    val channelClient = Wearable.getChannelClient(context)
                    var channel: com.google.android.gms.wearable.ChannelClient.Channel? = null
                    try {
                        val client = buildOkHttpClient(settings)
                        val url = buildWatchAttachmentDownloadUrl(settings.apiRoot, attachmentGuid, settings.guidAuthKey)
                        val payloadBytes: ByteArray? = client.newCall(Request.Builder().url(url).get().build()).execute().use { resp ->
                            if (!resp.isSuccessful) {
                                PersistentLog.w(context, TAG, "Attachment download HTTP ${resp.code}")
                                return@use null
                            }
                            val body = resp.body ?: return@use null
                            val mime = resp.header("Content-Type") ?: body.contentType()?.toString()
                            val action = classifyWatchAttachment(mime, body.contentLength())
                            if (action == WatchAttachmentAction.REJECT) {
                                PersistentLog.w(
                                    context,
                                    TAG,
                                    "Rejected watch attachment $attachmentGuid (mime=$mime len=${body.contentLength()})"
                                )
                                return@use null
                            }
                            val input = body.byteStream()
                            when (action) {
                                WatchAttachmentAction.COMPRESS_STATIC_IMAGE -> {
                                    val raw = readBoundedBytes(input, WATCH_IMAGE_MAX_READ_BYTES) ?: return@use null
                                    compressWatchImage(raw)
                                }
                                WatchAttachmentAction.GIF_PASSTHROUGH_OR_PREVIEW -> {
                                    val raw = readBoundedBytes(input, WATCH_IMAGE_MAX_READ_BYTES) ?: return@use null
                                    if (raw.size <= WATCH_GIF_PASSTHROUGH_MAX_BYTES) {
                                        raw
                                    } else {
                                        // shortcut: large GIFs (>768 KB) render as static JPEG preview on watch, upgrade if watch adds WebP/video transcoding
                                        compressWatchImage(raw)
                                    }
                                }
                                WatchAttachmentAction.STREAM_BOUNDED_AUDIO -> {
                                    readBoundedBytes(input, WATCH_AUDIO_MAX_BYTES)
                                }
                                WatchAttachmentAction.REJECT -> null
                            }
                        }
                        if (payloadBytes == null || payloadBytes.isEmpty()) {
                            notifyAttachmentFailed(context, nodeId, attachmentGuid)
                            return@withPermit
                        }
                        channel = channelClient.openChannel(nodeId, "$PATH_ATTACHMENT_PREFIX${encode(attachmentGuid)}").await()
                        val out = channelClient.getOutputStream(channel!!).await()
                        out.use { stream ->
                            stream.write(payloadBytes)
                            stream.flush()
                        }
                    } catch (e: Exception) {
                        PersistentLog.e(context, TAG, "streamAttachmentToWatch error: ${e.message}")
                        notifyAttachmentFailed(context, nodeId, attachmentGuid)
                    } finally {
                        channel?.let { ch ->
                            try {
                                channelClient.close(ch).await()
                            } catch (_: Exception) {
                            }
                        }
                    }
                }
            } finally {
                inFlightAttachments.remove(flightKey)
            }
        }
    }

    internal fun shouldPushContactAvatar(avatarPushCount: Int, maxAvatars: Int = 80): Boolean =
        avatarPushCount < maxAvatars

    internal fun watchMarkReadWorkerArgs(chatGuid: String): HashMap<String, Any?> =
        hashMapOf("chatGuid" to chatGuid, "privateMark" to true)

    fun handleMarkReadFromWatch(context: Context, chatGuid: String) {
        if (chatGuid.isBlank()) return
        cancelNotificationsForChat(context, chatGuid)
        // Delegate server POST to Dart so global + per-chat autoSendReadReceipts overrides are respected without double-POSTing.
        DartWorkManager.createWorker(
            context,
            "MarkChatRead",
            watchMarkReadWorkerArgs(chatGuid)
        ) {}
    }

    fun handleDismissFromWatch(context: Context, chatGuid: String) {
        if (chatGuid.isBlank()) return
        cancelNotificationsForChat(context, chatGuid)
    }

    fun setWatchActive(context: Context, active: Boolean) {
        val appCtx = context.applicationContext
        val untilMs = if (active) System.currentTimeMillis() + SOCKET_IDLE_TIMEOUT_MS else 0L
        watchActiveUntilMs = untilMs
        appCtx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putLong(KEY_WATCH_ACTIVE_UNTIL_MS, untilMs)
            .apply()
        if (active) {
            startSocketRelay(appCtx)
        } else {
            stopSocketRelay()
        }
    }

    internal fun isWatchActive(context: Context, nowMs: Long = System.currentTimeMillis()): Boolean {
        if (watchActiveUntilMs > nowMs) return true
        val persisted = context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getLong(KEY_WATCH_ACTIVE_UNTIL_MS, 0L)
        if (persisted > nowMs) {
            watchActiveUntilMs = persisted
            return true
        }
        return false
    }

    internal fun isValidSocketOrigin(origin: String): Boolean {
        if (origin.isBlank()) return false
        return try {
            val uri = URI(origin)
            (uri.scheme == "http" || uri.scheme == "https") && !uri.host.isNullOrBlank()
        } catch (_: Exception) {
            false
        }
    }

    internal fun buildRelaySocketOptions(
        authKey: String,
        extraHeaders: Map<String, List<String>>,
        okHttpClient: OkHttpClient = sharedRelayOkHttpClient
    ): IO.Options {
        // Polling-first matches SocketIOForegroundService: engine.io-client 2.1 never falls back from transports[0] on handshake error.
        val opts = IO.Options.builder()
            .setQuery("guid=${encode(authKey)}")
            .setTransports(arrayOf("polling", "websocket"))
            .setForceNew(true)
            .setReconnection(true)
            .setReconnectionDelay(2_000L)
            .setReconnectionDelayMax(120_000L)
            .setExtraHeaders(extraHeaders)
            .build()
        opts.callFactory = okHttpClient
        opts.webSocketFactory = okHttpClient
        return opts
    }

    internal fun isRecentlyForwarded(dedupKey: String, nowMs: Long = System.currentTimeMillis()): Boolean {
        val prev = recentForwardedMessages[dedupKey] ?: return false
        return nowMs - prev <= FORWARD_DEDUP_WINDOW_MS
    }

    internal fun markForwarded(dedupKey: String, nowMs: Long = System.currentTimeMillis()) {
        if (recentForwardedMessages.size > 64) {
            recentForwardedMessages.entries.removeIf { nowMs - it.value > FORWARD_DEDUP_WINDOW_MS }
        }
        recentForwardedMessages[dedupKey] = nowMs
    }

    internal fun shouldForwardDedup(dedupKey: String, nowMs: Long = System.currentTimeMillis()): Boolean {
        if (isRecentlyForwarded(dedupKey, nowMs)) return false
        markForwarded(dedupKey, nowMs)
        return true
    }

    internal fun clearForwardDedupForTests() {
        recentForwardedMessages.clear()
    }

    internal fun parseForwardableMessage(rawJson: String): Pair<String, JsonObject>? {
        val obj = try {
            JsonParser.parseString(rawJson).asObjOrNull()
        } catch (_: Exception) {
            null
        } ?: return null
        val chatGuid = obj.arr("chats")?.firstOrNull()?.asObjOrNull()?.str("guid")
            ?: obj.str("chatGuid")
            ?: return null
        return chatGuid to mapMessageToRelayJson(obj, chatGuid)
    }

    private suspend fun forwardMessageJsonToWatch(context: Context, rawJson: String, isUpdate: Boolean) {
        val (chatGuid, dto) = parseForwardableMessage(rawJson) ?: return
        val guid = dto.str("guid") ?: return
        val payloadStr = dto.toString()
        val dedupKey = if (isUpdate) "upd:$guid:${payloadStr.hashCode()}" else "new:$guid"
        if (isRecentlyForwarded(dedupKey)) return
        val payloadBytes = payloadStr.toByteArray()
        if (shouldUseDataAsset(payloadBytes)) {
            syncMessages(context, chatGuid)
            markForwarded(dedupKey)
        } else {
            val path = if (isUpdate) PATH_UPDATED_MESSAGE else PATH_NEW_MESSAGE
            if (sendMessageToWatchNodes(context, path, payloadBytes)) {
                markForwarded(dedupKey)
            }
        }
    }

    /**
     * Fallback delivery path while the watch app is actively open: Android's Cached App Freezer
     * can suspend background TCP reads when keepAppAlive is off, whereas high-priority FCM/UP wakes
     * the process immediately with the exact same message JSON. Zero BT traffic when watch is closed.
     */
    @JvmStatic
    fun forwardPushEventIfWatchActive(context: Context, type: String, payload: Map<String, Any?>) {
        if (type != "new-message" && type != "updated-message") return
        val appCtx = context.applicationContext
        if (!isWatchActive(appCtx)) return
        val rawJson = when (val data = payload["data"]) {
            is String -> data
            is Map<*, *> -> gson.toJson(data)
            else -> return
        }
        if (rawJson.isBlank()) return
        val isUpdate = type == "updated-message"
        scope.launch {
            forwardMessageJsonToWatch(appCtx, rawJson, isUpdate)
            if (relaySocket?.connected() != true && relaySocket?.isActive != true) {
                startSocketRelay(appCtx)
            }
        }
    }

    @Synchronized
    private fun startSocketRelay(context: Context) {
        socketTimeoutJob?.cancel()
        socketTimeoutJob = scope.launch {
            delay(SOCKET_IDLE_TIMEOUT_MS)
            stopSocketRelay()
        }
        val fgSocket = SocketIOForegroundService.activeSocket
        val settings = SettingsHelper(context)
        if (relaySocket != null) {
            if (fgSocket != null && fgSocket.connected() && relaySocket === fgSocket) return
            if (ownsRelaySocket && relaySocketOrigin == settings.origin &&
                (relaySocket?.connected() == true || relaySocket?.isActive == true)
            ) {
                return
            }
            detachRelaySocketLocked()
        }
        if (fgSocket != null && fgSocket.connected()) {
            attachRelayListenersLocked(context, fgSocket, logLifecycle = false)
            relaySocket = fgSocket
            ownsRelaySocket = false
            relaySocketOrigin = settings.origin
            return
        }
        if (!settings.hasServerUrl() || !settings.hasAuthKey()) return
        if (!isValidSocketOrigin(settings.origin)) {
            PersistentLog.w(context, TAG, "startSocketRelay skipped: invalid origin '${settings.origin}'")
            return
        }
        try {
            val extraHeaders = mutableMapOf<String, List<String>>()
            settings.getAllHeaders().forEach { (k, v) -> extraHeaders[k] = listOf(v) }
            val opts = buildRelaySocketOptions(settings.guidAuthKey, extraHeaders)
            val sock = IO.socket(settings.origin, opts)
            attachRelayListenersLocked(context, sock, logLifecycle = true)
            sock.connect()
            relaySocket = sock
            ownsRelaySocket = true
            relaySocketOrigin = settings.origin
        } catch (e: Exception) {
            PersistentLog.w(context, TAG, "startSocketRelay failed: ${e.message}")
        }
    }

    private fun attachRelayListenersLocked(context: Context, sock: Socket, logLifecycle: Boolean) {
        if (logLifecycle) {
            val connectListener = Emitter.Listener {
                PersistentLog.d(context, TAG, "Wear relay socket connected")
            }
            sock.on(Socket.EVENT_CONNECT, connectListener)
            relayListeners.add(Socket.EVENT_CONNECT to connectListener)

            val connectErrorListener = Emitter.Listener { args ->
                val detail = SocketIOForegroundService.parseConnectErrorMessage(args.firstOrNull())
                PersistentLog.w(context, TAG, "Wear relay socket connect error: $detail")
            }
            sock.on(Socket.EVENT_CONNECT_ERROR, connectErrorListener)
            relayListeners.add(Socket.EVENT_CONNECT_ERROR to connectErrorListener)

            val disconnectListener = Emitter.Listener { args ->
                val reason = SocketIOForegroundService.parseDisconnectReason(args.firstOrNull())
                PersistentLog.d(context, TAG, "Wear relay socket disconnected: $reason")
            }
            sock.on(Socket.EVENT_DISCONNECT, disconnectListener)
            relayListeners.add(Socket.EVENT_DISCONNECT to disconnectListener)
        }
        listOf("new-message" to false, "updated-message" to true).forEach { (event, isUpdate) ->
            val listener = Emitter.Listener { args ->
                val raw = when (val first = args.firstOrNull()) {
                    is JSONObject -> first.toString()
                    is String -> first
                    else -> return@Listener
                }
                scope.launch {
                    forwardMessageJsonToWatch(context, raw, isUpdate)
                }
            }
            sock.on(event, listener)
            relayListeners.add(event to listener)
        }
        val typingListener = Emitter.Listener { args ->
            val raw = args.firstOrNull() as? JSONObject ?: return@Listener
            val guid = raw.optString("guid", "")
            if (guid.isNotBlank()) {
                val payload = JsonObject().apply {
                    addProperty("chatGuid", guid)
                    addProperty("isTyping", raw.optBoolean("display", false))
                }.toString().toByteArray()
                scope.launch { sendMessageToWatchNodes(context, PATH_TYPING_INDICATOR, payload) }
            }
        }
        sock.on("typing-indicator", typingListener)
        relayListeners.add("typing-indicator" to typingListener)

        val pinnedListener = Emitter.Listener {
            syncChats(context)
        }
        sock.on("pinned-chats-updated", pinnedListener)
        relayListeners.add("pinned-chats-updated" to pinnedListener)
    }

    private fun detachRelaySocketLocked() {
        val sock = relaySocket
        if (sock != null) {
            for ((event, listener) in relayListeners) {
                try {
                    sock.off(event, listener)
                } catch (_: Exception) {
                }
            }
            if (ownsRelaySocket) {
                try {
                    sock.disconnect()
                } catch (_: Exception) {
                }
            }
        }
        relayListeners.clear()
        relaySocket = null
        ownsRelaySocket = false
        relaySocketOrigin = ""
    }

    @Synchronized
    private fun stopSocketRelay() {
        socketTimeoutJob?.cancel()
        socketTimeoutJob = null
        detachRelaySocketLocked()
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

    internal fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private suspend fun putAvatarAsset(context: Context, normalizedKey: String, bytes: ByteArray) {
        val hash = sha256Hex(bytes)
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val prefKey = "avatar_hash_$normalizedKey"
        if (prefs.getString(prefKey, null) == hash) return

        val safeKey = Uri.encode(normalizedKey)
        val req = PutDataMapRequest.create("$PATH_AVATAR_PREFIX$safeKey").apply {
            dataMap.putString("key", normalizedKey)
            dataMap.putAsset("avatar", Asset.createFromBytes(bytes))
        }.asPutDataRequest()
        Wearable.getDataClient(context).putDataItem(req).await()
        prefs.edit().putString(prefKey, hash).apply()
    }

    private suspend fun sendNodeJson(context: Context, nodeId: String, path: String, payload: JsonObject) {
        try {
            Wearable.getMessageClient(context).sendMessage(nodeId, path, payload.toString().toByteArray()).await()
        } catch (_: Exception) {}
    }

    private suspend fun sendResult(
        context: Context,
        nodeId: String,
        requestId: String,
        tempGuid: String?,
        success: Boolean,
        error: String?,
        message: JsonObject? = null,
        translation: JsonObject? = null
    ) {
        sendNodeJson(context, nodeId, PATH_SEND_RESULT, JsonObject().apply {
            addProperty("requestId", requestId)
            addProperty("tempGuid", tempGuid)
            addProperty("success", success)
            if (error != null) addProperty("error", error)
            if (message != null) add("message", message)
            if (translation != null) add("translation", translation)
        })
    }

    internal fun shouldUseDataAsset(payloadBytes: ByteArray): Boolean =
        payloadBytes.size > PAYLOAD_MESSAGE_MAX_BYTES

    private suspend fun sendJsonOrAsset(
        context: Context,
        targetNodeId: String?,
        messagePath: String,
        dataPath: String,
        payloadBytes: ByteArray
    ) {
        if (!shouldUseDataAsset(payloadBytes)) {
            sendToWatch(context, targetNodeId, messagePath, payloadBytes)
        } else {
            val putReq = PutDataMapRequest.create(dataPath).apply {
                dataMap.putAsset(ASSET_KEY_PAYLOAD, Asset.createFromBytes(payloadBytes))
                dataMap.putLong("updatedAt", System.currentTimeMillis())
            }.asPutDataRequest().setUrgent()
            Wearable.getDataClient(context).putDataItem(putReq).await()
        }
    }

    private suspend fun sendToWatch(context: Context, targetNodeId: String?, path: String, payload: ByteArray) {
        if (targetNodeId != null) {
            Wearable.getMessageClient(context).sendMessage(targetNodeId, path, payload).await()
        } else {
            sendMessageToWatchNodes(context, path, payload)
        }
    }

    private suspend fun sendMessageToWatchNodes(context: Context, path: String, payload: ByteArray): Boolean {
        var sentAny = false
        try {
            val nodes = Wearable.getCapabilityClient(context)
                .getCapability(WATCH_CAPABILITY, CapabilityClient.FILTER_REACHABLE)
                .await()
                .nodes
            val msgClient = Wearable.getMessageClient(context)
            for (node in nodes) {
                try {
                    msgClient.sendMessage(node.id, path, payload).await()
                    sentAny = true
                } catch (_: Exception) {
                }
            }
        } catch (e: Exception) {
            PersistentLog.w(context, TAG, "sendMessageToWatchNodes($path) failed: ${e.message}")
        }
        return sentAny
    }

    private val baseOkHttpClient: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .dns(SocketIOForegroundService.ipv4FirstDns)
            .build()
    }

    internal fun shouldAttachCustomHeaders(requestUrl: HttpUrl, serverUrl: HttpUrl?): Boolean {
        if (serverUrl == null) return false
        if (!requestUrl.host.equals(serverUrl.host, ignoreCase = true)) return false
        if (requestUrl.port != serverUrl.port) return false
        if (serverUrl.isHttps && !requestUrl.isHttps) return false
        return true
    }

    internal fun buildOkHttpClient(settings: SettingsHelper, minReadTimeoutMs: Long = 15_000L): OkHttpClient =
        buildOkHttpClient(
            timeoutMs = settings.apiTimeout.toLong(),
            minReadTimeoutMs = minReadTimeoutMs,
            serverOrigin = settings.origin,
            headersProvider = { settings.getAllHeaders() },
        )

    internal fun buildOkHttpClient(
        timeoutMs: Long,
        minReadTimeoutMs: Long = 15_000L,
        serverOrigin: String,
        headersProvider: () -> Map<String, String>,
    ): OkHttpClient {
        val timeout = timeoutMs.coerceAtLeast(15_000L)
        val readTimeout = timeout.coerceAtLeast(minReadTimeoutMs)
        val expectedOrigin = serverOrigin.trim().toHttpUrlOrNull()
        val headersInterceptor = Interceptor { chain ->
            val request = chain.request()
            if (shouldAttachCustomHeaders(request.url, expectedOrigin)) {
                val builder = request.newBuilder()
                headersProvider().forEach { (k, v) -> builder.addHeader(k, v) }
                chain.proceed(builder.build())
            } else {
                chain.proceed(request)
            }
        }
        return baseOkHttpClient.newBuilder()
            .connectTimeout(timeout, TimeUnit.MILLISECONDS)
            .readTimeout(readTimeout, TimeUnit.MILLISECONDS)
            .writeTimeout(timeout, TimeUnit.MILLISECONDS)
            .addInterceptor(headersInterceptor)
            .build()
    }

    internal fun mapMessageToRelayJson(msg: JsonObject, chatGuid: String): JsonObject {
        val atts = msg.arr("attachments")
        val attachmentsJson = JsonArray()
        var firstNonPluginAtt: JsonObject? = null
        var firstAtt: JsonObject? = null
        if (atts != null) {
            for (el in atts) {
                val att = el.asObjOrNull() ?: continue
                val attGuid = att.str("guid")?.takeIf { it.isNotBlank() } ?: continue
                if (firstAtt == null) firstAtt = att
                val transferName = att.str("transferName")?.takeIf { it.isNotBlank() }
                if (firstNonPluginAtt == null && !WearLinkPreview.isPluginPayloadAttachment(transferName)) {
                    firstNonPluginAtt = att
                }
                attachmentsJson.add(JsonObject().apply {
                    addProperty("guid", attGuid)
                    att.str("mimeType")?.takeIf { it.isNotBlank() }?.let { addProperty("mimeType", it) }
                    transferName?.let { addProperty("transferName", it) }
                })
            }
        }
        val primaryAtt = firstNonPluginAtt ?: firstAtt
        val balloonBundleId = msg.str("balloonBundleId")?.takeIf { it.isNotBlank() }
        val linkPreview = WearLinkPreview.extractLinkPreviewJson(msg, atts)
        return JsonObject().apply {
            addProperty("guid", msg.str("guid") ?: UUID.randomUUID().toString())
            addProperty("chatGuid", chatGuid)
            msg.str("tempGuid")?.let { addProperty("tempGuid", it) }
            addProperty("text", msg.str("text"))
            addProperty("isFromMe", msg.bool("isFromMe") ?: false)
            addProperty("dateCreated", msg.long("dateCreated") ?: System.currentTimeMillis())
            msg.long("dateDelivered")?.let { addProperty("dateDelivered", it) }
            msg.long("dateRead")?.let { addProperty("dateRead", it) }
            msg.long("dateEdited")?.let { addProperty("dateEdited", it) }
            addProperty("handleAddress", msg.obj("handle")?.str("address"))
            addProperty("attachmentGuid", primaryAtt?.str("guid"))
            addProperty("attachmentMimeType", primaryAtt?.str("mimeType"))
            if (attachmentsJson.size() > 0) add("attachments", attachmentsJson)
            balloonBundleId?.let { addProperty("balloonBundleId", it) }
            linkPreview?.let { add("linkPreview", it) }
            addProperty("associatedMessageGuid", msg.str("associatedMessageGuid"))
            addProperty("associatedMessageType", msg.str("associatedMessageType"))
            addProperty("associatedMessageEmoji", msg.str("associatedMessageEmoji"))
            msg.obj("translation")?.let { tr ->
                val trText = tr.str("text")?.takeIf { it.isNotBlank() }
                if (trText != null) {
                    addProperty("translatedText", trText)
                    tr.str("sourceLanguage")?.let { addProperty("translationSourceLang", it) }
                    tr.str("targetLanguage")?.let { addProperty("translationTargetLang", it) }
                }
            }
        }
    }

    private fun parseDataMessage(bodyStr: String?, chatGuid: String): JsonObject? = try {
        JsonParser.parseString(bodyStr ?: "{}").asObjOrNull()?.obj("data")?.let { mapMessageToRelayJson(it, chatGuid) }
    } catch (_: Exception) {
        null
    }

    private fun normalizeAddress(address: String): String {
        val trimmed = address.trim()
        if (trimmed.contains("@")) return trimmed.lowercase()
        val digits = trimmed.filter { it.isDigit() }
        return if (digits.length == 11 && digits.startsWith("1")) digits.substring(1) else digits
    }

    private fun encode(v: String): String = URLEncoder.encode(v, "UTF-8")

    private fun JsonElement?.asObjOrNull(): JsonObject? = this?.takeIf { it.isJsonObject }?.asJsonObject
    private fun JsonObject.obj(key: String): JsonObject? = get(key)?.takeIf { it.isJsonObject }?.asJsonObject
    private fun JsonObject.arr(key: String): JsonArray? = get(key)?.takeIf { it.isJsonArray }?.asJsonArray
    private fun JsonObject.str(key: String): String? = get(key)?.takeIf { it.isJsonPrimitive }?.asString
    private fun JsonObject.long(key: String): Long? = get(key)?.takeIf { it.isJsonPrimitive }?.asLong
    private fun JsonObject.int(key: String): Int? = get(key)?.takeIf { it.isJsonPrimitive }?.asInt
    private fun JsonObject.bool(key: String): Boolean? = get(key)?.takeIf { it.isJsonPrimitive }?.asBoolean
}
