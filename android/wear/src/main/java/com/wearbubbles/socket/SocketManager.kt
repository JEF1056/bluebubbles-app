package com.wearbubbles.socket

import android.util.Log
import com.google.gson.Gson
import com.wearbubbles.api.dto.MessageDto
import io.socket.client.IO
import io.socket.client.Socket
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject
import java.net.URLEncoder

sealed class SocketEvent {
    data class NewMessage(val message: MessageDto) : SocketEvent()
    data class UpdatedMessage(val message: MessageDto) : SocketEvent()
    data class TypingIndicator(val chatGuid: String, val display: Boolean) : SocketEvent()
    data class PinnedChatsUpdated(val pinnedChatGuids: List<String>) : SocketEvent()
    data object Connected : SocketEvent()
    data object Disconnected : SocketEvent()
}

class SocketManager {

    companion object {
        private const val TAG = "SocketManager"
    }

    private var socket: Socket? = null
    private val gson = Gson()

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

        if (socket?.connected() == true &&
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

            val options = IO.Options.builder()
                .setQuery("guid=$encodedPass")
                .setTransports(arrayOf("websocket", "polling"))
                .setReconnection(true)
                .setReconnectionAttempts(Int.MAX_VALUE)
                .setReconnectionDelay(2000)
                .setReconnectionDelayMax(30000)
                .setTimeout(15000)
                .setExtraHeaders(extraHeaders)
                .build()

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
                    val json = args.firstOrNull() as? JSONObject ?: return@on
                    try {
                        val msg = gson.fromJson(json.toString(), MessageDto::class.java)
                        if (msg != null) {
                            _events.tryEmit(SocketEvent.NewMessage(msg))
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to parse new-message", e)
                    }
                }

                on("updated-message") { args ->
                    val json = args.firstOrNull() as? JSONObject ?: return@on
                    try {
                        val msg = gson.fromJson(json.toString(), MessageDto::class.java)
                        if (msg != null) {
                            _events.tryEmit(SocketEvent.UpdatedMessage(msg))
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to parse updated-message", e)
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

                connect()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Socket connection setup failed", e)
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
