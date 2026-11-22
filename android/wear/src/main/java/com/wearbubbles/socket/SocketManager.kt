package com.wearbubbles.socket

import android.util.Log
import com.google.gson.Gson
import com.google.gson.JsonParser
import com.wearbubbles.api.dto.MessageDto
import io.socket.client.IO
import io.socket.client.Socket
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import okhttp3.Dns
import okhttp3.OkHttpClient
import org.json.JSONObject
import java.net.Inet4Address
import java.net.InetAddress
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

sealed class SocketEvent {
    data class NewMessage(val message: MessageDto) : SocketEvent()
    data class UpdatedMessage(val message: MessageDto) : SocketEvent()
    data class MessageSendError(val message: MessageDto) : SocketEvent()
    data class TypingIndicator(val chatGuid: String, val display: Boolean) : SocketEvent()
    data class PinnedChatsUpdated(val pinnedChatGuids: List<String>) : SocketEvent()
    data class IncomingFaceTime(
        val callUuid: String,
        val callerName: String,
        val callerAddress: String,
        val isVideo: Boolean,
        val isTelephony: Boolean = false
    ) : SocketEvent()
    data class FaceTimeCallEnded(
        val callUuid: String,
        val onlyIfRinging: Boolean = false
    ) : SocketEvent()
    data object Connected : SocketEvent()
    data object Disconnected : SocketEvent()
}

class SocketManager {

    companion object {
        private const val TAG = "SocketManager"
        private val gsonStatic = Gson()

        internal fun orderIpv4First(addresses: List<InetAddress>): List<InetAddress> {
            val ipv4 = addresses.filterIsInstance<Inet4Address>()
            if (ipv4.isEmpty() || ipv4.size == addresses.size) return addresses
            val other = addresses.filterNot { it is Inet4Address }
            return ipv4 + other
        }

        internal val ipv4FirstDns: Dns = object : Dns {
            override fun lookup(hostname: String): List<InetAddress> =
                orderIpv4First(Dns.SYSTEM.lookup(hostname))
        }

        internal fun buildSocketOkHttpClient(dns: Dns = ipv4FirstDns): OkHttpClient =
            OkHttpClient.Builder()
                .dns(dns)
                .connectTimeout(20, TimeUnit.SECONDS)
                .readTimeout(1, TimeUnit.MINUTES)
                .writeTimeout(20, TimeUnit.SECONDS)
                .build()

        internal val sharedSocketOkHttpClient: OkHttpClient by lazy { buildSocketOkHttpClient() }

        internal fun buildSocketOptions(
            normalizedUrl: String,
            password: String,
            customHeaders: Map<String, String> = emptyMap(),
            okHttpClient: OkHttpClient = sharedSocketOkHttpClient
        ): IO.Options {
            val encodedPass = URLEncoder.encode(password, "UTF-8")
            val extraHeaders = mutableMapOf<String, List<String>>()
            customHeaders.forEach { (k, v) ->
                if (k.isNotBlank()) extraHeaders[k] = listOf(v)
            }
            if (normalizedUrl.contains("ngrok")) {
                extraHeaders["ngrok-skip-browser-warning"] = listOf("true")
            } else if (normalizedUrl.contains("zrok")) {
                extraHeaders["skip_zrok_interstitial"] = listOf("true")
            }

            // Polling-first lets engine.io-client 2.1 connect over HTTP and upgrade to WS; websocket-first never falls back on error.
            val options = IO.Options.builder()
                .setQuery("guid=$encodedPass")
                .setTransports(arrayOf("polling", "websocket"))
                .setForceNew(true)
                .setReconnection(true)
                .setReconnectionAttempts(Int.MAX_VALUE)
                .setReconnectionDelay(2000)
                .setReconnectionDelayMax(120_000)
                .setTimeout(15000)
                .setExtraHeaders(extraHeaders)
                .build()
            options.callFactory = okHttpClient
            options.webSocketFactory = okHttpClient
            return options
        }

        internal fun parseMessageDto(arg: Any?): MessageDto? {
            val raw = when (arg) {
                is JSONObject -> arg.toString()
                is String -> arg
                else -> return null
            }
            return try {
                val elem = JsonParser.parseString(raw)
                if (!elem.isJsonObject) return null
                val obj = elem.asJsonObject
                val target = if (!obj.has("guid") && obj.get("data")?.isJsonObject == true) {
                    obj.getAsJsonObject("data")
                } else {
                    obj
                }
                gsonStatic.fromJson(target, MessageDto::class.java)
                    ?.takeIf { !it.guid.isNullOrBlank() || !it.tempGuid.isNullOrBlank() }
            } catch (e: Exception) {
                try {
                    Log.e(TAG, "Failed to parse message payload", e)
                } catch (_: Throwable) {
                }
                null
            }
        }

        private fun parseGsonObject(arg: Any?): com.google.gson.JsonObject? {
            val raw = when (arg) {
                is JSONObject -> arg.toString()
                is String -> arg
                else -> return null
            }
            return try {
                val elem = JsonParser.parseString(raw)
                if (elem.isJsonObject) elem.asJsonObject else null
            } catch (_: Exception) {
                null
            }
        }

        private fun com.google.gson.JsonObject.strOrBlank(key: String): String =
            get(key)?.takeIf { !it.isJsonNull }?.asString ?: ""

        private fun com.google.gson.JsonObject.boolOrDefault(key: String, default: Boolean): Boolean =
            try {
                get(key)?.takeIf { !it.isJsonNull }?.asBoolean ?: default
            } catch (_: Exception) {
                default
            }

        private fun com.google.gson.JsonObject.intOrDefault(key: String, default: Int): Int =
            try {
                get(key)?.takeIf { !it.isJsonNull }?.asInt ?: default
            } catch (_: Exception) {
                default
            }

        internal fun parseIncomingFaceTimeEvent(arg: Any?): SocketEvent.IncomingFaceTime? {
            val json = parseGsonObject(arg) ?: return null
            val caller = json.strOrBlank("caller").ifBlank {
                json.strOrBlank("address")
            }
            if (caller.isBlank()) return null
            val uuid = json.strOrBlank("uuid").ifBlank { "ft_${caller.hashCode()}" }
            val isTelephony = json.boolOrDefault("is_telephony", false)
            val isVideo = json.boolOrDefault("is_video", false) && !isTelephony
            return SocketEvent.IncomingFaceTime(
                callUuid = uuid,
                callerName = caller,
                callerAddress = caller,
                isVideo = isVideo,
                isTelephony = isTelephony
            )
        }

        internal fun parseFaceTimeStatusEvent(arg: Any?): SocketEvent? {
            val json = parseGsonObject(arg) ?: return null
            val statusId = json.intOrDefault("status_id", -1)
            val uuid = json.strOrBlank("uuid")
            if (uuid.isBlank()) return null
            return when (statusId) {
                4 -> {
                    val handleAddr = json.get("handle")?.takeIf { it.isJsonObject }?.asJsonObject?.strOrBlank("address") ?: ""
                    val address = handleAddr.ifBlank { json.strOrBlank("address") }
                    val isTelephony = json.boolOrDefault("is_telephony", false)
                    val rawVideo = if (json.has("is_video")) {
                        json.boolOrDefault("is_video", true)
                    } else {
                        !json.boolOrDefault("is_audio", false)
                    }
                    SocketEvent.IncomingFaceTime(
                        callUuid = uuid,
                        callerName = address.ifBlank { if (isTelephony) "iPhone Call" else "FaceTime Caller" },
                        callerAddress = address,
                        isVideo = rawVideo && !isTelephony,
                        isTelephony = isTelephony
                    )
                }
                // status_id == 1 means active/answered elsewhere (only end if still ringing locally);
                // status_id == 6 means disconnected.
                1 -> SocketEvent.FaceTimeCallEnded(uuid, onlyIfRinging = true)
                6 -> SocketEvent.FaceTimeCallEnded(uuid, onlyIfRinging = false)
                else -> null
            }
        }
    }

    private var socket: Socket? = null

    private val _events = MutableSharedFlow<SocketEvent>(extraBufferCapacity = 64)
    val events: SharedFlow<SocketEvent> = _events.asSharedFlow()

    private val _isConnected = MutableStateFlow(false)
    val isConnected: StateFlow<Boolean> = _isConnected.asStateFlow()

    private var currentUrl: String = ""
    private var currentPassword: String = ""
    private var currentHeaders: Map<String, String> = emptyMap()

    @Synchronized
    fun connect(serverUrl: String, password: String, customHeaders: Map<String, String> = emptyMap()) {
        val normalizedUrl = serverUrl.trim().trimEnd('/')
        if (normalizedUrl.isBlank() || password.isBlank()) return

        if ((socket?.connected() == true || socket?.isActive == true) &&
            currentUrl == normalizedUrl &&
            currentPassword == password &&
            currentHeaders == customHeaders
        ) {
            return
        }

        disconnect()
        currentUrl = normalizedUrl
        currentPassword = password
        currentHeaders = customHeaders

        try {
            val options = buildSocketOptions(normalizedUrl, password, customHeaders)

            socket = IO.socket(normalizedUrl, options).apply {
                on(Socket.EVENT_CONNECT) {
                    Log.d(TAG, "Socket connected")
                    _isConnected.value = true
                    _events.tryEmit(SocketEvent.Connected)
                }

                on(Socket.EVENT_DISCONNECT) { args ->
                    Log.d(TAG, "Socket disconnected: ${args.firstOrNull()}")
                    _isConnected.value = false
                    _events.tryEmit(SocketEvent.Disconnected)
                }

                on(Socket.EVENT_CONNECT_ERROR) { args ->
                    Log.w(TAG, "Socket connect error: ${args.firstOrNull()}")
                    _isConnected.value = false
                }

                on("new-message") { args ->
                    parseMessageDto(args.firstOrNull())?.let { msg ->
                        _events.tryEmit(SocketEvent.NewMessage(msg))
                    }
                }

                on("updated-message") { args ->
                    parseMessageDto(args.firstOrNull())?.let { msg ->
                        _events.tryEmit(SocketEvent.UpdatedMessage(msg))
                    }
                }

                on("message-send-error") { args ->
                    parseMessageDto(args.firstOrNull())?.let { msg ->
                        _events.tryEmit(SocketEvent.MessageSendError(msg))
                    }
                }

                on("typing-indicator") { args ->
                    val json = args.firstOrNull() as? JSONObject ?: return@on
                    val guid = json.optString("guid", "")
                    val display = json.optBoolean("display", false)
                    if (guid.isNotBlank()) {
                        _events.tryEmit(SocketEvent.TypingIndicator(guid, display))
                    }
                }

                on("pinned-chats-updated") { args ->
                    val json = args.firstOrNull() as? JSONObject ?: return@on
                    val arr = json.optJSONArray("pinnedChatGuids") ?: return@on
                    val guids = buildList {
                        for (i in 0 until arr.length()) {
                            val guid = arr.optString(i, "")
                            if (guid.isNotBlank()) add(guid)
                        }
                    }
                    _events.tryEmit(SocketEvent.PinnedChatsUpdated(guids))
                }

                on("incoming-facetime") { args ->
                    parseIncomingFaceTimeEvent(args.firstOrNull())?.let { _events.tryEmit(it) }
                }

                on("ft-call-status-changed") { args ->
                    parseFaceTimeStatusEvent(args.firstOrNull())?.let { _events.tryEmit(it) }
                }

                connect()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Socket connection setup failed", e)
        }
    }

    @Synchronized
    fun reconnectIfConfigured() {
        if (currentUrl.isNotBlank() && currentPassword.isNotBlank() && socket?.connected() != true) {
            connect(currentUrl, currentPassword, currentHeaders)
        }
    }

    @Synchronized
    fun disconnect() {
        try {
            socket?.disconnect()
            socket?.off()
        } catch (_: Exception) {
        }
        socket = null
        _isConnected.value = false
    }
}
