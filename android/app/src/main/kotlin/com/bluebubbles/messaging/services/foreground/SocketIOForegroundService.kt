package com.bluebubbles.messaging.services.foreground

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.MainActivity
import com.bluebubbles.messaging.R
import com.bluebubbles.messaging.services.backend_ui_interop.DartWorkManager
import com.bluebubbles.messaging.services.backend_ui_interop.MethodCallHandler
import com.bluebubbles.messaging.services.notifications.NotificationChannelHandler
import com.bluebubbles.messaging.services.telecom.FaceTimeConnectionService
import com.bluebubbles.messaging.utils.PersistentLog
import io.socket.client.IO
import io.socket.client.Socket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.URI
import java.net.URISyntaxException
import java.net.URLEncoder
import java.util.Collections
import java.util.Collections.singletonList
import java.util.IdentityHashMap
import java.util.concurrent.TimeUnit
import okhttp3.Dns
import okhttp3.OkHttpClient
import org.json.JSONObject


class SocketIOForegroundService : Service() {

    companion object {
        // Consts for notification messages
        const val DEFAULT_NOTIFICATION = "BlueBubbles is running in the background."
        const val MISSING_SERVER_URL = "BlueBubbles Service is missing your server URL!"
        const val MISSING_PASSWORD = "BlueBubbles Service is missing your password!"
        const val UNHANDLED_ERROR = "BlueBubbles Service encountered an unhandled error"
        const val CONNECTED = "BlueBubbles is connected to your server!"
        const val CONNECT_FAILED = "BlueBubbles failed to connect to your server! Error: "
        const val DISCONNECTED = "BlueBubbles is disconnected from your server! Error: "
        const val RECONNECTING = "BlueBubbles is reconnecting to your server..."
        const val RECONNECT_FAILED = "BlueBubbles failed to reconnect to your server..."
        const val DESTROYED = "BlueBubbles Service was destroyed!"
        const val DISABLED = "BlueBubbles Foreground Service is disabled"

        @Volatile
        var activeSocket: Socket? = null
            private set

        internal fun parseConnectErrorMessage(arg: Any?): String {
            if (arg !is Throwable) {
                return arg?.toString() ?: "Unknown error"
            }
            val topMessage = arg.message?.takeIf { it.isNotBlank() } ?: arg.javaClass.simpleName
            val visited = Collections.newSetFromMap(IdentityHashMap<Throwable, Boolean>())
            visited.add(arg)
            val causes = mutableListOf<String>()
            var current = arg.cause
            var depth = 0
            while (current != null && depth < 6 && visited.add(current)) {
                val msg = current.message?.takeIf { it.isNotBlank() }
                causes.add(if (msg != null) "${current.javaClass.simpleName}: $msg" else current.javaClass.simpleName)
                current = current.cause
                depth++
            }
            return if (causes.isEmpty()) topMessage else "$topMessage (caused by ${causes.joinToString(" -> ")})"
        }

        internal fun orderIpv4First(addresses: List<InetAddress>): List<InetAddress> {
            val (ipv4, other) = addresses.partition { it is Inet4Address }
            return ipv4 + other
        }

        internal val ipv4FirstDns: Dns = Dns { hostname ->
            orderIpv4First(Dns.SYSTEM.lookup(hostname))
        }

        internal fun buildSocketOkHttpClient(dns: Dns = ipv4FirstDns): OkHttpClient =
            OkHttpClient.Builder()
                .dns(dns)
                .connectTimeout(10, TimeUnit.SECONDS)
                .readTimeout(1, TimeUnit.MINUTES)
                .writeTimeout(1, TimeUnit.MINUTES)
                .build()

        internal fun parseDisconnectReason(arg: Any?): String =
            (arg as? String) ?: arg?.toString() ?: "unknown"

        internal fun shouldReconnectOnDisconnect(reason: String): Boolean =
            reason == "io server disconnect"

        @Volatile
        private var activeInstance: SocketIOForegroundService? = null

        fun reloadIfRunning(): Boolean {
            val instance = activeInstance ?: return false
            instance.reconnectHandler.post { instance.connectSocketFromPrefs() }
            return true
        }
    }

    private var mSocket: Socket? = null

    private var currentNotification: String? = null

    @Volatile
    private var isBeingDestroyed: Boolean = false

    @Volatile
    private var hasStarted: Boolean = false

    // A single-shot Handler used for scheduled reconnect attempts. Using a Handler
    // + named Runnable allows us to (a) prevent multiple concurrent reconnect
    // threads from accumulating and (b) cancel any pending reconnect when the
    // service is destroyed.
    private val reconnectHandler = Handler(Looper.getMainLooper())
    private val reconnectRunnable = Runnable {
        reconnectScheduled = false
        if (!isBeingDestroyed && mSocket != null && !mSocket!!.connected()) {
            PersistentLog.e(applicationContext, Constants.logTag, "Attempting reconnection now...")
            mSocket!!.connect()
        }
    }

    @Volatile
    private var reconnectScheduled: Boolean = false

    private val eventBlacklist: Array<String> = arrayOf(
        "typing-indicator",
        "ft-bridge-answer",
        "ft-bridge-ice",
        "ft-bridge-hangup",
        Socket.EVENT_CONNECT,
        Socket.EVENT_DISCONNECT
    )

    // Live FindMy socket events belong only to the active UI isolate; never spawn a headless worker for them.
    private val foregroundOnlyEvents: Set<String> = setOf(
        "new-findmy-location",
        "new-findmy-device"
    )

    override fun onCreate() {
        super.onCreate()
        isBeingDestroyed = false
        activeInstance = this

        try {
            val prefs = applicationContext.getSharedPreferences("FlutterSharedPreferences", 0)
            val keepAppAlive: Boolean = prefs.getBoolean("keepAppAlive", false)

            // Create notification for foreground service before any early stopSelf() to satisfy FGS contract
            createNotificationChannel()
            ServiceCompat.startForeground(
                this,
                Constants.foregroundServiceNotificationId,
                createNotification(DEFAULT_NOTIFICATION),
                FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING
            )

            // Make sure the user has enabled the service
            if (!keepAppAlive) {
                PersistentLog.d(applicationContext, Constants.logTag, DISABLED)
                stopSelf()
                return
            }

            hasStarted = true
            connectSocketFromPrefs()
        } catch (e: Exception) {
            PersistentLog.e(applicationContext, Constants.logTag, "Failed to initialize foreground service", e)
            stopSelf()
        }
    }

    private fun connectSocketFromPrefs() {
        try {
            reconnectScheduled = false
            reconnectHandler.removeCallbacks(reconnectRunnable)
            activeSocket = null
            mSocket?.disconnect()
            mSocket?.close()
            mSocket = null

            val prefs = applicationContext.getSharedPreferences("FlutterSharedPreferences", 0)
            val serverUrl: String? = prefs.getString("serverAddress", null)
            val storedPassword: String? = prefs.getString("guidAuthKey", null)
            val customHeaders: String? = prefs.getString("customHeaders", null)

            // if the service is enabled, but the server URL is missing, update the notification
            if (serverUrl == null || serverUrl.isEmpty()) {
                updateNotification(MISSING_SERVER_URL)
                return
            }

            // if the service is enabled, but the password is missing, update the notification
            if (storedPassword == null || storedPassword.isEmpty()) {
                updateNotification(MISSING_PASSWORD)
                return
            }

            // Initialize socket.io connection
            // Do not log serverUrl — it may contain credentials in query parameters.
            PersistentLog.d(applicationContext, Constants.logTag, "Foreground Service is connecting to server")

            val opts = IO.Options()

            try {
                // Read the custom headers JSON string from preferences and parse it into a map
                val extraHeaders = mutableMapOf<String, List<String>>()
                val customHeaderMap = JSONObject(customHeaders)
                customHeaderMap.keys().forEach { key ->
                    // Add the key-value pair to extraHeaders
                    extraHeaders[key] = singletonList(customHeaderMap.getString(key))
                }
                opts.extraHeaders = extraHeaders
            } catch (e: Exception) {
                PersistentLog.e(applicationContext, Constants.logTag, "Failed to parse custom headers JSON string!", e)
            }

            // Only log the header keys (not values) to avoid leaking auth tokens or API keys.
            if (opts.extraHeaders != null && opts.extraHeaders.isNotEmpty()) {
                PersistentLog.d(applicationContext, Constants.logTag, "Socket.io Custom header keys: ${opts.extraHeaders!!.keys.joinToString(", ")}")
            }

            // Validate the URL before passing it to socket.io.
            // socket.io's Java URLDecoder throws IllegalArgumentException in a background
            // thread if the URL contains bare % characters (e.g. %s%), which crashes the
            // process and permanently prevents the app from launching (GitHub issue #2845).
            try {
                URI(serverUrl)
            } catch (e: URISyntaxException) {
                // Do not log serverUrl — it may contain credentials in query parameters.
                PersistentLog.e(applicationContext, Constants.logTag, "Server URL stored in preferences is malformed", e)
                updateNotification(MISSING_SERVER_URL)
                return
            }

            val encodedPw = URLEncoder.encode(storedPassword, "UTF-8")
            opts.query = "password=$encodedPw"
            val okHttpClient = buildSocketOkHttpClient()
            opts.callFactory = okHttpClient
            opts.webSocketFactory = okHttpClient
            mSocket = IO.socket(serverUrl, opts)
            activeSocket = mSocket

            mSocket!!.on(Socket.EVENT_CONNECT) {
                PersistentLog.d(applicationContext, Constants.logTag, "Socket.io connected to your server!")
                updateNotification(CONNECTED)
            }

            mSocket!!.on(Socket.EVENT_CONNECT_ERROR) { args ->
                val message = parseConnectErrorMessage(args.getOrNull(0))
                PersistentLog.d(applicationContext, Constants.logTag, "Socket.io failed to connect to server! Error: $message")
                updateNotification(CONNECT_FAILED + message)
            }

            // with reason, details args
            mSocket!!.on(Socket.EVENT_DISCONNECT) { args ->
                val reason = parseDisconnectReason(args.getOrNull(0))
                PersistentLog.d(applicationContext, Constants.logTag, "Socket.io disconnected from server! Reason: $reason")
                if (isBeingDestroyed) {
                    return@on
                }

                val details = args.getOrNull(1)
                PersistentLog.d(applicationContext, Constants.logTag, "Socket.io disconnected from server! Reason: $reason, Details: $details")
                updateNotification(DISCONNECTED + reason)
                if (shouldReconnectOnDisconnect(reason)) {
                    tryReconnect()
                }
            }

            mSocket!!.on("reconnecting") {
                PersistentLog.d(applicationContext, Constants.logTag, "Socket.io is reconnecting to your server...")
                updateNotification(RECONNECTING)
            }

            mSocket!!.on("reconnect_failed") {
                PersistentLog.d(applicationContext, Constants.logTag, "Socket.io failed to reconnect to your server...")
                updateNotification(RECONNECT_FAILED)
                if (!isBeingDestroyed) {
                    tryReconnect()
                }
            }

            // This runs on socket.io's own event thread, outside the try/catch wrapping
            // onCreate — anything that escapes it takes down the whole process rather than
            // just the connection, so the body is fully guarded.
            mSocket!!.onAnyIncoming { args ->
                try {
                    // Never cast the args blindly: payload shape varies by event (most send a
                    // JSONObject, but `incoming-facetime` sends an already-encoded JSON
                    // string), and some events carry no payload at all.
                    val event = args.getOrNull(0) as? String
                    if (event == null) {
                        PersistentLog.w(applicationContext, Constants.logTag, "Ignoring Socket.io event with a non-string name")
                        return@onAnyIncoming
                    }

                    if (eventBlacklist.contains(event)) {
                        PersistentLog.d(applicationContext, Constants.logTag, "Ignored event of type $event from Socket.io...")
                        return@onAnyIncoming
                    }
                    if (event in foregroundOnlyEvents && (MainActivity.getEngine() == null || !MainActivity.isDartReady())) {
                        PersistentLog.d(applicationContext, Constants.logTag, "Skipped foreground-only event $event (UI engine not ready)")
                        return@onAnyIncoming
                    }

                    // The Dart handler decodes this into a Map, so only object-shaped JSON is
                    // usable — forwarding anything else would just burn five headless engine
                    // boots on retries before being dropped anyway.
                    val payload = args.getOrNull(1)
                    val data = when {
                        payload is JSONObject -> payload.toString()
                        payload is String && payload.trimStart().startsWith("{") -> payload
                        else -> null
                    }

                    if (data == null) {
                        PersistentLog.w(
                            applicationContext,
                            Constants.logTag,
                            "Ignoring event $event from Socket.io — payload is not a JSON object (${payload?.javaClass?.simpleName ?: "absent"})"
                        )
                        return@onAnyIncoming
                    }

                    PersistentLog.d(applicationContext, Constants.logTag, "Received event of type $event from Socket.io...")
                    if (event == "ft-call-status-changed") {
                        handleNativeFaceTimeStatusChanged(data)
                    }
                    val argsMap = hashMapOf<String, Any>("event" to event, "data" to data)
                    val enqueueWorker = {
                        if (event !in foregroundOnlyEvents) {
                            DartWorkManager.createWorker(applicationContext, "socket-event", HashMap(argsMap)) {}
                        }
                    }
                    if (MainActivity.getEngine() != null && MainActivity.isDartReady()) {
                        reconnectHandler.post {
                            try {
                                if (MainActivity.getEngine() != null && MainActivity.isDartReady()) {
                                    MethodCallHandler.invokeMethod("socket-event", argsMap)
                                } else {
                                    enqueueWorker()
                                }
                            } catch (e: Exception) {
                                PersistentLog.w(applicationContext, Constants.logTag, "Direct socket-event dispatch failed, falling back to DartWorkManager: ${e.message}")
                                enqueueWorker()
                            }
                        }
                    } else {
                        enqueueWorker()
                    }
                } catch (e: Exception) {
                    PersistentLog.e(applicationContext, Constants.logTag, "Failed to handle incoming Socket.io event", e)
                }
            }

            mSocket!!.connect()
        } catch (e: Exception) {
            if (isBeingDestroyed) {
                return
            }

            PersistentLog.e(applicationContext, Constants.logTag, "Socket.io unhandled error occurred!", e)
            updateNotification(UNHANDLED_ERROR)

            if (hasStarted) {
                tryReconnect()
            }
        }
    }

    private fun tryReconnect() {
        // Guard: if a reconnect is already pending, don't schedule another one.
        if (reconnectScheduled) {
            PersistentLog.d(applicationContext, Constants.logTag, "Reconnect already scheduled, skipping.")
            return
        }
        val socket = mSocket
        if (socket != null && !socket.connected()) {
            reconnectScheduled = true
            PersistentLog.e(applicationContext, Constants.logTag, "Scheduling reconnection in 30 seconds...")
            reconnectHandler.postDelayed(reconnectRunnable, 30_000L)
        }
    }

    private fun createNotificationChannel() {
        NotificationChannelHandler.ensureForegroundServiceChannel(this)
    }

    private fun createNotification(contentText: String): Notification {
        currentNotification = contentText
        return NotificationCompat.Builder(this, NotificationChannelHandler.FOREGROUND_SERVICE_CHANNEL_ID)
            .setContentTitle("BlueBubbles Service")
            .setContentText(contentText)
            .setSmallIcon(R.mipmap.ic_stat_icon)
            // The notification should be categorized as silent
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_DEFERRED)
            .setLocalOnly(true)
            // The notification should be ongoing and not cancelable.
            // This does not prevent dismissing it on Android 14+.
            .setOngoing(true)
            // The notification should not alert the user
            .setOnlyAlertOnce(true)
            // The notification should not cancel when the user taps on it
            .setAutoCancel(false)
            // The notification should not show the time
            .setShowWhen(false)
            .setColor(4888294)
            .build()
    }

    private fun updateNotification(contentText: String) {
        // If the notification is the same, don't update it
        if (currentNotification == contentText) {
            return
        }

        val notification = createNotification(contentText)
        val notificationManager = getSystemService(NotificationManager::class.java) as NotificationManager
        notificationManager.notify(Constants.foregroundServiceNotificationId, notification)
    }

    private fun removeNotification() {
        val notificationManager = getSystemService(NotificationManager::class.java) as NotificationManager
        notificationManager.cancel(Constants.foregroundServiceNotificationId)
    }

    override fun onBind(intent: Intent?): IBinder? {
        return null
    }

    override fun onDestroy() {
        isBeingDestroyed = true
        hasStarted = false
        reconnectScheduled = false
        reconnectHandler.removeCallbacks(reconnectRunnable)
        PersistentLog.d(applicationContext, Constants.logTag, "BlueBubbles Service is being destroyed!")

        super.onDestroy()
        if (activeInstance === this) {
            activeInstance = null
        }
        activeSocket = null
        mSocket?.disconnect()
        mSocket?.close()

        // Remove the notification when the service is destroyed
        removeNotification()
    }

    private fun handleNativeFaceTimeStatusChanged(data: String) {
        try {
            val json = JSONObject(data)
            val statusId = json.optInt("status_id", -1)
            val callUuid = json.optString("uuid", "").takeIf { it.isNotBlank() } ?: return
            val isOutgoing = json.optBoolean("is_outgoing", false)
            reconnectHandler.post {
                when (statusId) {
                    1 -> {
                        if (!FaceTimeConnectionService.markCallActive(callUuid, recordIfPending = isOutgoing)) {
                            FaceTimeConnectionService.endCall(callUuid, onlyIfRinging = true)
                        }
                    }
                    6 -> FaceTimeConnectionService.endCall(callUuid, onlyIfRinging = false, recordIfPending = true)
                }
            }
        } catch (e: Exception) {
            PersistentLog.w(applicationContext, Constants.logTag, "Failed native ft-call-status-changed dispatch: ${e.message}")
        }
    }
}
