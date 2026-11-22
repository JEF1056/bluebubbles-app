package com.bluebubbles.messaging.services.telecom

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.view.Surface
import androidx.core.content.ContextCompat
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.MainActivity
import com.bluebubbles.messaging.services.backend_ui_interop.MethodCallHandler
import com.bluebubbles.messaging.services.foreground.SocketIOForegroundService
import com.bluebubbles.messaging.utils.PersistentLog
import com.bluebubbles.messaging.utils.SettingsHelper
import io.flutter.view.TextureRegistry
import io.socket.client.Ack
import io.socket.client.IO
import io.socket.client.Socket
import io.socket.emitter.Emitter
import org.json.JSONArray
import org.json.JSONObject
import org.webrtc.AudioSource
import org.webrtc.AudioTrack
import org.webrtc.Camera1Enumerator
import org.webrtc.Camera2Enumerator
import org.webrtc.CameraEnumerator
import org.webrtc.CameraVideoCapturer
import org.webrtc.DataChannel
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.EglBase
import org.webrtc.GlRectDrawer
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.MediaStreamTrack
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RendererCommon
import org.webrtc.RtpReceiver
import org.webrtc.RtpTransceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.SurfaceEglRenderer
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoSource
import org.webrtc.VideoTrack
import org.webrtc.audio.JavaAudioDeviceModule
import java.net.URI
import java.net.URLEncoder
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

internal data class IceServerSpec(
    val urls: List<String>,
    val username: String? = null,
    val credential: String? = null
)

internal class CallResourceLease(
    private val acquireAudioFocus: () -> Boolean,
    private val releaseAudioFocus: () -> Unit,
    private val acquireWakeLock: () -> Boolean,
    private val releaseWakeLock: () -> Unit,
    private val acquireWifiLock: () -> Boolean,
    private val releaseWifiLock: () -> Unit
) {
    var audioFocusHeld = false
        private set
    var wakeLockHeld = false
        private set
    var wifiLockHeld = false
        private set

    fun acquireAll() {
        audioFocusHeld = try { acquireAudioFocus() } catch (_: Exception) { false }
        wakeLockHeld = try { acquireWakeLock() } catch (_: Exception) { false }
        wifiLockHeld = try { acquireWifiLock() } catch (_: Exception) { false }
    }

    fun releaseAll() {
        if (audioFocusHeld) {
            audioFocusHeld = false
            try { releaseAudioFocus() } catch (_: Exception) {}
        }
        if (wakeLockHeld) {
            wakeLockHeld = false
            try { releaseWakeLock() } catch (_: Exception) {}
        }
        if (wifiLockHeld) {
            wifiLockHeld = false
            try { releaseWifiLock() } catch (_: Exception) {}
        }
    }
}

class WebRtcAudioClient(
    private val context: Context,
    private val callUuid: String,
    private val answerCall: Boolean,
    private val wantVideo: Boolean = false,
    private val onRemoteHangup: () -> Unit,
    private val onConnected: () -> Unit = {},
    private val onError: (String) -> Unit = {},
    private val onRemoteVideoTexture: (Long?) -> Unit = {},
    private val onLocalVideoTexture: (Long?) -> Unit = {}
) {
    companion object {
        private const val TAG = "WebRtcAudioClient"
        private const val DEFAULT_STUN_URL = "stun:stun.l.google.com:19302"
        private const val CONFIG_TIMEOUT_MS = 1500L
        private const val SOCKET_CONNECT_TIMEOUT_MS = 5000L
        private const val WAKE_LOCK_TAG = "BlueBubbles:WebRtcCall"
        private const val WIFI_LOCK_TAG = "BlueBubbles:WebRtcWifi"
        private val WAKE_LOCK_TIMEOUT_MS = TimeUnit.HOURS.toMillis(4)

        @Volatile
        private var webrtcInitialized = false

        private val cameraExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()

        @Synchronized
        private fun ensureInitialized(context: Context) {
            if (webrtcInitialized) return
            PeerConnectionFactory.initialize(
                PeerConnectionFactory.InitializationOptions.builder(context.applicationContext)
                    .createInitializationOptions()
            )
            webrtcInitialized = true
        }

        internal fun parsePayload(arg: Any?): JSONObject? = when (arg) {
            is JSONObject -> arg
            is String -> try {
                JSONObject(arg)
            } catch (_: Exception) {
                null
            }
            else -> null
        }

        internal fun parseIceServerSpecs(raw: JSONArray?): List<IceServerSpec> {
            if (raw == null || raw.length() == 0) {
                return listOf(IceServerSpec(listOf(DEFAULT_STUN_URL)))
            }
            val maps = mutableListOf<Map<String, Any?>>()
            for (i in 0 until raw.length()) {
                val obj = raw.optJSONObject(i) ?: continue
                val urlsVal: Any? = when (val u = obj.opt("urls")) {
                    is JSONArray -> (0 until u.length()).mapNotNull { u.optString(it).takeIf(String::isNotBlank) }
                    is String -> u
                    else -> null
                }
                maps.add(
                    mapOf(
                        "urls" to urlsVal,
                        "url" to obj.optString("url"),
                        "username" to obj.optString("username"),
                        "credential" to obj.optString("credential")
                    )
                )
            }
            return parseIceServerSpecsFromMaps(maps)
        }

        internal fun parseIceServerSpecsFromMaps(raw: List<Map<String, Any?>>?): List<IceServerSpec> {
            if (raw.isNullOrEmpty()) {
                return listOf(IceServerSpec(listOf(DEFAULT_STUN_URL)))
            }
            val parsed = mutableListOf<IceServerSpec>()
            for (obj in raw) {
                val urls = mutableListOf<String>()
                when (val urlsField = obj["urls"]) {
                    is Iterable<*> -> urlsField.forEach { item ->
                        (item as? String)?.trim()?.takeIf { it.isNotEmpty() }?.let(urls::add)
                    }
                    is String -> urlsField.trim().takeIf { it.isNotEmpty() }?.let(urls::add)
                }
                if (urls.isEmpty()) {
                    (obj["url"] as? String)?.trim()?.takeIf { it.isNotEmpty() }?.let(urls::add)
                }
                if (urls.isEmpty()) continue
                val username = (obj["username"] as? String)?.trim()?.takeIf { it.isNotEmpty() }
                val credential = (obj["credential"] as? String)?.trim()?.takeIf { it.isNotEmpty() }
                parsed.add(IceServerSpec(urls = urls, username = username, credential = credential))
            }
            return parsed.ifEmpty { listOf(IceServerSpec(listOf(DEFAULT_STUN_URL))) }
        }

        internal fun buildRtcIceServers(specs: List<IceServerSpec>): List<PeerConnection.IceServer> =
            specs.map { spec ->
                PeerConnection.IceServer.builder(spec.urls).apply {
                    spec.username?.let(::setUsername)
                    spec.credential?.let(::setPassword)
                }.createIceServer()
            }

        internal fun buildOfferPayloadMap(
            callUuid: String,
            sdp: String,
            wantVideo: Boolean,
            hasLocalVideo: Boolean,
            answerCall: Boolean
        ): Map<String, Any> = buildMap {
            put("callUuid", callUuid)
            put("sdp", sdp)
            put("type", "offer")
            if (wantVideo) {
                put("video", true)
                put("uplinkVideo", hasLocalVideo)
            }
            if (answerCall) {
                put("answerCall", true)
            }
        }

        internal fun buildOfferPayload(
            callUuid: String,
            sdp: String,
            wantVideo: Boolean,
            hasLocalVideo: Boolean,
            answerCall: Boolean
        ): JSONObject = JSONObject(buildOfferPayloadMap(callUuid, sdp, wantVideo, hasLocalVideo, answerCall))

        internal fun buildCameraStatePayloadMap(callUuid: String, enabled: Boolean): Map<String, Any> = mapOf(
            "callUuid" to callUuid,
            "enabled" to enabled
        )

        internal fun buildCameraStatePayload(callUuid: String, enabled: Boolean): JSONObject =
            JSONObject(buildCameraStatePayloadMap(callUuid, enabled))

        internal fun buildFallbackSocketOptions(
            authKey: String,
            extraHeaders: Map<String, String> = emptyMap()
        ): IO.Options = IO.Options.builder()
            .setQuery("guid=${URLEncoder.encode(authKey, "UTF-8")}")
            .setTransports(arrayOf("polling", "websocket"))
            .setForceNew(true)
            .setReconnection(true)
            .apply {
                if (extraHeaders.isNotEmpty()) {
                    setExtraHeaders(extraHeaders.mapValues { Collections.singletonList(it.value) })
                }
            }
            .build().apply {
                val okHttpClient = SocketIOForegroundService.buildSocketOkHttpClient()
                callFactory = okHttpClient
                webSocketFactory = okHttpClient
            }

        internal fun resolveIceServersAfterConnect(
            isConnected: () -> Boolean,
            isStopped: () -> Boolean,
            awaitConnect: () -> Boolean,
            fetchFromConnectedSocket: () -> List<IceServerSpec>?
        ): List<IceServerSpec> {
            if (isStopped()) return listOf(IceServerSpec(listOf(DEFAULT_STUN_URL)))
            if (!isConnected()) {
                awaitConnect()
            }
            if (isStopped() || !isConnected()) {
                return listOf(IceServerSpec(listOf(DEFAULT_STUN_URL)))
            }
            return fetchFromConnectedSocket() ?: listOf(IceServerSpec(listOf(DEFAULT_STUN_URL)))
        }
    }

    private val lock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val disconnectTimeoutRunnable = Runnable {
        if (!stopped) {
            PersistentLog.w(context, TAG, "ICE disconnected >10s for $callUuid; hanging up")
            onRemoteHangup()
        }
    }
    private val pendingRemoteIce = mutableListOf<IceCandidate>()
    private val pendingOutboundEvents = mutableListOf<Pair<String, JSONObject>>()

    private var socket: Socket? = null
    private var ownsSocket = false
    private var factory: PeerConnectionFactory? = null
    private var audioDeviceModule: JavaAudioDeviceModule? = null
    private var audioSource: AudioSource? = null
    private var localAudioTrack: AudioTrack? = null
    private var peerConnection: PeerConnection? = null

    private var eglBase: EglBase? = null
    private var surfaceTextureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var videoSurface: Surface? = null
    private var surfaceEglRenderer: SurfaceEglRenderer? = null
    private var remoteVideoTrack: VideoTrack? = null

    private var videoCapturer: CameraVideoCapturer? = null
    private var surfaceTextureHelper: SurfaceTextureHelper? = null
    private var videoSource: VideoSource? = null
    private var localVideoTrack: VideoTrack? = null
    private var localSurfaceTextureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var localVideoSurface: Surface? = null
    private var localSurfaceEglRenderer: SurfaceEglRenderer? = null
    private var cameraCount = 0

    @Volatile
    private var frontCamera = true

    @Volatile
    private var cameraEnabled = false

    @Volatile
    private var hasLocalVideo = false

    private var configuredIceSpecs: List<IceServerSpec> = listOf(IceServerSpec(listOf(DEFAULT_STUN_URL)))

    @Volatile
    private var remoteDescriptionSet = false

    @Volatile
    private var stopped = false

    @Volatile
    private var starting = false

    @Volatile
    private var muted = false

    @Volatile
    private var connectLatch: CountDownLatch? = null

    @Volatile
    private var pendingIceLatch: CountDownLatch? = null

    @Volatile
    private var iceServersFetchedFromSocket = false

    @Volatile
    private var refreshingIceServers = false

    private var callResourceLease: CallResourceLease? = null

    private val onConnectErrorListener = Emitter.Listener { args ->
        PersistentLog.w(context, TAG, "Bridge Socket.IO connect error: ${args.firstOrNull()}")
    }

    private val onConnectListener = Emitter.Listener {
        connectLatch?.countDown()
        flushPendingOutbound()
        if (!stopped && peerConnection != null && !iceServersFetchedFromSocket) {
            refreshIceServersAsync()
        }
    }

    private val onAnswerListener = Emitter.Listener { args ->
        val payload = parsePayload(args.getOrNull(0)) ?: return@Listener
        if (payload.optString("callUuid") != callUuid) return@Listener
        val answerIce = payload.optJSONArray("iceServers")
        if (answerIce != null && answerIce.length() > 0) {
            val parsed = parseIceServerSpecs(answerIce)
            if (parsed != configuredIceSpecs) {
                configuredIceSpecs = parsed
                try {
                    peerConnection?.setConfiguration(buildRtcConfig(parsed))
                } catch (_: Exception) {}
            }
        }
        val sdp = payload.optString("sdp")
        if (sdp.isEmpty()) return@Listener
        handleRemoteAnswer(sdp)
    }

    private val onIceListener = Emitter.Listener { args ->
        val payload = parsePayload(args.getOrNull(0)) ?: return@Listener
        if (payload.optString("callUuid") != callUuid) return@Listener
        val candidateStr = payload.optString("candidate")
        if (candidateStr.isEmpty()) return@Listener
        val sdpMid = if (payload.isNull("sdpMid")) null else payload.optString("sdpMid")
        val sdpMLineIndex = if (payload.isNull("sdpMLineIndex")) 0 else payload.optInt("sdpMLineIndex", 0)
        handleRemoteIce(IceCandidate(sdpMid, sdpMLineIndex, candidateStr))
    }

    private val onHangupListener = Emitter.Listener { args ->
        val payload = parsePayload(args.getOrNull(0)) ?: return@Listener
        if (payload.optString("callUuid") != callUuid) return@Listener
        PersistentLog.d(context, TAG, "Received ft-bridge-hangup for $callUuid")
        onRemoteHangup()
    }

    fun start() {
        val latch: CountDownLatch
        val activeSock: Socket?
        synchronized(lock) {
            if (stopped || starting || peerConnection != null) return
            starting = true
            try {
                setupSocket()
                acquireCallResourcesLocked()
                activeSock = socket
                latch = connectLatch ?: CountDownLatch(0)
            } catch (e: Exception) {
                starting = false
                PersistentLog.e(context, TAG, "Failed to start WebRTC audio bridge for $callUuid", e)
                onError(e.message ?: "WebRTC init failed")
                stop(sendHangup = false)
                return
            }
        }

        try {
            // Await Socket.EVENT_CONNECT outside lock so EventThread listeners and stop() cannot deadlock.
            val iceSpecs = resolveIceServersAfterConnect(
                isConnected = { activeSock?.connected() == true },
                isStopped = { stopped },
                awaitConnect = {
                    try {
                        latch.await(SOCKET_CONNECT_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                    } catch (_: InterruptedException) {
                        false
                    }
                },
                fetchFromConnectedSocket = { fetchIceServersFromConnectedSocket() }
            )
            synchronized(lock) {
                if (stopped || peerConnection != null) {
                    starting = false
                    return
                }
                configuredIceSpecs = iceSpecs
                setupPeerConnection(iceSpecs)
                createAndSendOffer()
                starting = false
            }
        } catch (e: Exception) {
            synchronized(lock) { starting = false }
            PersistentLog.e(context, TAG, "Failed to start WebRTC audio bridge for $callUuid", e)
            onError(e.message ?: "WebRTC init failed")
            stop(sendHangup = false)
        }
    }

    private fun fetchIceServersFromConnectedSocket(): List<IceServerSpec>? {
        val activeSocket = socket
        if (stopped || activeSocket == null || !activeSocket.connected()) {
            return null
        }
        var result: List<IceServerSpec>? = null
        val latch = CountDownLatch(1)
        pendingIceLatch = latch
        try {
            activeSocket.emit("ft-bridge-config", Ack { args ->
                try {
                    val payload = parsePayload(args.firstOrNull())
                    result = parseIceServerSpecs(payload?.optJSONArray("iceServers"))
                    iceServersFetchedFromSocket = true
                } finally {
                    latch.countDown()
                }
            })
            latch.await(CONFIG_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } catch (_: Exception) {
        } finally {
            if (pendingIceLatch === latch) {
                pendingIceLatch = null
            }
        }
        return result
    }

    private fun refreshIceServersAsync() {
        if (refreshingIceServers || stopped) return
        refreshingIceServers = true
        Thread({
            try {
                val specs = fetchIceServersFromConnectedSocket() ?: return@Thread
                synchronized(lock) {
                    if (!stopped && specs != configuredIceSpecs) {
                        configuredIceSpecs = specs
                        try {
                            peerConnection?.setConfiguration(buildRtcConfig(specs))
                        } catch (_: Exception) {}
                    }
                }
            } finally {
                refreshingIceServers = false
            }
        }, "bb-webrtc-ice-refresh").apply { isDaemon = true }.start()
    }

    private fun buildRtcConfig(specs: List<IceServerSpec>): PeerConnection.RTCConfiguration =
        PeerConnection.RTCConfiguration(buildRtcIceServers(specs)).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
        }

    fun setMuted(isMuted: Boolean) {
        synchronized(lock) {
            if (stopped) return
            muted = isMuted
            localAudioTrack?.setEnabled(!isMuted)
        }
        emitEvent(
            "ft-bridge-mute",
            JSONObject().apply {
                put("callUuid", callUuid)
                put("muted", isMuted)
            }
        )
    }

    fun isCameraEnabled(): Boolean = cameraEnabled

    fun isFrontCamera(): Boolean = frontCamera

    fun canFlipCamera(): Boolean = hasLocalVideo && cameraCount >= 2

    fun setCameraEnabled(enabled: Boolean): Boolean {
        val capturer: CameraVideoCapturer?
        synchronized(lock) {
            if (stopped || !hasLocalVideo) return false
            if (cameraEnabled == enabled) return true
            cameraEnabled = enabled
            localVideoTrack?.setEnabled(enabled)
            capturer = videoCapturer
        }
        if (capturer != null) {
            cameraExecutor.execute {
                synchronized(lock) {
                    if (stopped || videoCapturer !== capturer || cameraEnabled != enabled) return@execute
                    try {
                        if (enabled) {
                            capturer.startCapture(1280, 720, 30)
                        } else {
                            capturer.stopCapture()
                        }
                    } catch (e: Exception) {
                        PersistentLog.w(context, TAG, "setCameraEnabled($enabled) failed for $callUuid: ${e.message}")
                    }
                }
            }
        }
        emitEvent("ft-bridge-camera", buildCameraStatePayload(callUuid, enabled))
        return true
    }

    fun flipCamera(): Boolean {
        val capturer: CameraVideoCapturer?
        synchronized(lock) {
            if (stopped || !hasLocalVideo || cameraCount < 2) return false
            capturer = videoCapturer
        }
        capturer ?: return false
        return try {
            capturer.switchCamera(object : CameraVideoCapturer.CameraSwitchHandler {
                override fun onCameraSwitchDone(isFrontCamera: Boolean) {
                    frontCamera = isFrontCamera
                    mainHandler.post {
                        val textureId: Long?
                        val enabled: Boolean
                        val canFlip: Boolean
                        synchronized(lock) {
                            if (stopped) return@post
                            textureId = localSurfaceTextureEntry?.id()
                            enabled = cameraEnabled
                            canFlip = cameraCount >= 2
                        }
                        if (textureId != null) {
                            MethodCallHandler.invokeMethod(
                                "facetime-call-state",
                                mapOf(
                                    "phase" to "local-video-texture",
                                    "call_uuid" to callUuid,
                                    "texture_id" to textureId,
                                    "camera_enabled" to enabled,
                                    "can_flip_camera" to canFlip,
                                    "front_camera" to isFrontCamera
                                )
                            )
                        }
                    }
                }

                override fun onCameraSwitchError(errorDescription: String?) {
                    PersistentLog.w(context, TAG, "switchCamera failed for $callUuid: $errorDescription")
                }
            })
            true
        } catch (e: Exception) {
            PersistentLog.w(context, TAG, "flipCamera failed for $callUuid: ${e.message}")
            false
        }
    }

    fun stop(sendHangup: Boolean = true) {
        val socketToClean: Socket?
        val shouldDisconnectSocket: Boolean
        synchronized(lock) {
            if (stopped) return
            stopped = true
            connectLatch?.countDown()
            pendingIceLatch?.countDown()
            mainHandler.removeCallbacks(disconnectTimeoutRunnable)

            if (sendHangup) {
                try {
                    val hangupPayload = JSONObject().apply { put("callUuid", callUuid) }
                    socket?.takeIf { it.connected() }?.emit("ft-bridge-hangup", hangupPayload)
                } catch (_: Exception) {}
            }

            pendingOutboundEvents.clear()
            pendingRemoteIce.clear()

            socketToClean = socket
            shouldDisconnectSocket = ownsSocket
            socket = null
            ownsSocket = false

            try {
                val eglToRelease = cleanupVideoLocked()

                try {
                    localAudioTrack?.setEnabled(false)
                    localAudioTrack?.dispose()
                } catch (_: Exception) {}
                localAudioTrack = null

                try {
                    audioSource?.dispose()
                } catch (_: Exception) {}
                audioSource = null

                try {
                    peerConnection?.close()
                    peerConnection?.dispose()
                } catch (_: Exception) {}
                peerConnection = null

                try {
                    audioDeviceModule?.release()
                } catch (_: Exception) {}
                audioDeviceModule = null

                try {
                    factory?.dispose()
                } catch (_: Exception) {}
                factory = null

                try {
                    eglToRelease?.release()
                } catch (_: Exception) {}
            } finally {
                releaseCallResourcesLocked()
            }
        }

        socketToClean?.let { s ->
            s.off(Socket.EVENT_CONNECT_ERROR, onConnectErrorListener)
            s.off(Socket.EVENT_CONNECT, onConnectListener)
            s.off("ft-bridge-answer", onAnswerListener)
            s.off("ft-bridge-ice", onIceListener)
            s.off("ft-bridge-hangup", onHangupListener)
            if (shouldDisconnectSocket) {
                try {
                    s.disconnect()
                    s.close()
                } catch (_: Exception) {}
            }
        }
    }

    private fun acquireCallResourcesLocked() {
        if (callResourceLease != null) return
        val appContext = context.applicationContext
        val audioManager = appContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        val powerManager = appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager
        val wifiManager = appContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager

        var focusRequest: AudioFocusRequest? = null
        var wakeLock: PowerManager.WakeLock? = null
        var wifiLock: WifiManager.WifiLock? = null

        val lease = CallResourceLease(
            acquireAudioFocus = {
                val am = audioManager ?: return@CallResourceLease false
                val attrs = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
                val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                    .setAudioAttributes(attrs)
                    .setAcceptsDelayedFocusGain(false)
                    .setOnAudioFocusChangeListener({ focusChange ->
                        PersistentLog.d(appContext, TAG, "Audio focus changed for $callUuid: $focusChange")
                    }, mainHandler)
                    .build()
                val result = am.requestAudioFocus(req)
                if (result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED ||
                    result == AudioManager.AUDIOFOCUS_REQUEST_DELAYED
                ) {
                    focusRequest = req
                    true
                } else {
                    PersistentLog.w(appContext, TAG, "Audio focus denied for $callUuid: $result")
                    false
                }
            },
            releaseAudioFocus = {
                focusRequest?.let { req ->
                    focusRequest = null
                    audioManager?.abandonAudioFocusRequest(req)
                }
            },
            acquireWakeLock = {
                val pm = powerManager ?: return@CallResourceLease false
                val wl = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG).apply {
                    setReferenceCounted(false)
                }
                wl.acquire(WAKE_LOCK_TIMEOUT_MS)
                wakeLock = wl
                true
            },
            releaseWakeLock = {
                wakeLock?.let { wl ->
                    wakeLock = null
                    if (wl.isHeld) wl.release()
                }
            },
            acquireWifiLock = {
                val wm = wifiManager ?: return@CallResourceLease false
                val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    @Suppress("DEPRECATION")
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                val lock = wm.createWifiLock(mode, WIFI_LOCK_TAG).apply {
                    setReferenceCounted(false)
                }
                lock.acquire()
                wifiLock = lock
                true
            },
            releaseWifiLock = {
                wifiLock?.let { lock ->
                    wifiLock = null
                    if (lock.isHeld) lock.release()
                }
            }
        )
        callResourceLease = lease
        lease.acquireAll()
    }

    private fun releaseCallResourcesLocked() {
        callResourceLease?.releaseAll()
        callResourceLease = null
    }

    private fun setupSocket() {
        val existing = SocketIOForegroundService.activeSocket
        if (existing != null && existing.connected()) {
            socket = existing
            ownsSocket = false
            connectLatch = CountDownLatch(0)
            existing.on(Socket.EVENT_CONNECT, onConnectListener)
            existing.on("ft-bridge-answer", onAnswerListener)
            existing.on("ft-bridge-ice", onIceListener)
            existing.on("ft-bridge-hangup", onHangupListener)
        } else {
            val settings = SettingsHelper(context)
            val serverUrl = settings.serverAddress.takeIf { it.isNotBlank() }
                ?: throw IllegalStateException("Server URL is not configured")
            val authKey = settings.guidAuthKey
            URI(serverUrl)

            val opts = buildFallbackSocketOptions(authKey, settings.getAllHeaders())
            val newSocket = IO.socket(serverUrl, opts)
            connectLatch = CountDownLatch(1)
            socket = newSocket
            ownsSocket = true
            // Attach connect/signaling listeners before connect() so an immediate connect cannot race past them.
            newSocket.on(Socket.EVENT_CONNECT_ERROR, onConnectErrorListener)
            newSocket.on(Socket.EVENT_CONNECT, onConnectListener)
            newSocket.on("ft-bridge-answer", onAnswerListener)
            newSocket.on("ft-bridge-ice", onIceListener)
            newSocket.on("ft-bridge-hangup", onHangupListener)
            newSocket.connect()
        }
    }

    private fun setupPeerConnection(iceSpecs: List<IceServerSpec>) {
        ensureInitialized(context)
        val adm = JavaAudioDeviceModule.builder(context.applicationContext)
            .setUseHardwareAcousticEchoCanceler(true)
            .setUseHardwareNoiseSuppressor(true)
            .createAudioDeviceModule()
        audioDeviceModule = adm

        val factoryBuilder = PeerConnectionFactory.builder()
            .setAudioDeviceModule(adm)

        if (wantVideo) {
            val egl = EglBase.create()
            eglBase = egl
            factoryBuilder
                .setVideoDecoderFactory(DefaultVideoDecoderFactory(egl.eglBaseContext))
                .setVideoEncoderFactory(DefaultVideoEncoderFactory(egl.eglBaseContext, true, true))
        }

        val pcFactory = factoryBuilder.createPeerConnectionFactory()
        factory = pcFactory

        val rtcConfig = buildRtcConfig(iceSpecs)

        val pc = pcFactory.createPeerConnection(rtcConfig, object : PeerConnection.Observer {
            override fun onSignalingChange(state: PeerConnection.SignalingState?) {}
            override fun onIceConnectionChange(state: PeerConnection.IceConnectionState?) {
                PersistentLog.d(context, Constants.logTag, "[$TAG] ICE state=$state ($callUuid)")
                when (state) {
                    PeerConnection.IceConnectionState.CONNECTED,
                    PeerConnection.IceConnectionState.COMPLETED -> {
                        mainHandler.removeCallbacks(disconnectTimeoutRunnable)
                        onConnected()
                    }
                    PeerConnection.IceConnectionState.DISCONNECTED -> {
                        mainHandler.removeCallbacks(disconnectTimeoutRunnable)
                        mainHandler.postDelayed(disconnectTimeoutRunnable, 10_000L)
                    }
                    PeerConnection.IceConnectionState.FAILED -> {
                        mainHandler.removeCallbacks(disconnectTimeoutRunnable)
                        mainHandler.post { if (!stopped) onRemoteHangup() }
                    }
                    else -> {}
                }
            }

            override fun onIceConnectionReceivingChange(receiving: Boolean) {}
            override fun onIceGatheringChange(state: PeerConnection.IceGatheringState?) {}

            override fun onIceCandidate(candidate: IceCandidate?) {
                if (candidate == null || stopped) return
                emitEvent(
                    "ft-bridge-ice",
                    JSONObject().apply {
                        put("callUuid", callUuid)
                        put("candidate", candidate.sdp)
                        put("sdpMid", candidate.sdpMid)
                        put("sdpMLineIndex", candidate.sdpMLineIndex)
                    }
                )
            }

            override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) {}
            override fun onAddStream(stream: MediaStream?) {}
            override fun onRemoveStream(stream: MediaStream?) {}
            override fun onDataChannel(channel: DataChannel?) {}
            override fun onRenegotiationNeeded() {}
            override fun onAddTrack(receiver: RtpReceiver?, streams: Array<out MediaStream>?) {
                if (!wantVideo || stopped) return
                val track = receiver?.track() as? VideoTrack ?: return
                attachRemoteVideoTrack(track)
            }
        }) ?: throw IllegalStateException("createPeerConnection returned null")

        peerConnection = pc

        val source = pcFactory.createAudioSource(MediaConstraints())
        audioSource = source
        val track = pcFactory.createAudioTrack("ARDAMSa0", source)
        track.setEnabled(!muted)
        localAudioTrack = track
        pc.addTrack(track, listOf("ARDAMS"))

        if (wantVideo) {
            val localTrack = setupLocalVideoTrack(pcFactory)
            if (localTrack != null) {
                pc.addTransceiver(
                    localTrack,
                    RtpTransceiver.RtpTransceiverInit(
                        RtpTransceiver.RtpTransceiverDirection.SEND_RECV,
                        listOf("ARDAMS")
                    )
                )
                attachLocalVideoTrack(localTrack)
            } else {
                pc.addTransceiver(
                    MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO,
                    RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.RECV_ONLY)
                )
            }
        }
    }

    private fun setupLocalVideoTrack(pcFactory: PeerConnectionFactory): VideoTrack? {
        val hasCameraPermission = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.CAMERA
        ) == PackageManager.PERMISSION_GRANTED
        if (!hasCameraPermission) {
            PersistentLog.w(context, TAG, "CAMERA permission not granted for $callUuid; falling back to downlink-only")
            return null
        }

        val egl = eglBase ?: return null
        return try {
            val enumerator: CameraEnumerator = if (Camera2Enumerator.isSupported(context)) {
                Camera2Enumerator(context)
            } else {
                Camera1Enumerator(true)
            }
            val devices = enumerator.deviceNames
            cameraCount = devices.size
            val frontDevice = devices.firstOrNull { enumerator.isFrontFacing(it) }
            val selectedDevice = frontDevice ?: devices.firstOrNull()
            if (selectedDevice == null) {
                PersistentLog.w(context, TAG, "No camera devices found for $callUuid; falling back to downlink-only")
                return null
            }
            frontCamera = enumerator.isFrontFacing(selectedDevice)

            val capturer = enumerator.createCapturer(selectedDevice, null)
            if (capturer == null) {
                PersistentLog.w(context, TAG, "createCapturer returned null for $selectedDevice; falling back to downlink-only")
                return null
            }
            videoCapturer = capturer

            val helper = SurfaceTextureHelper.create("bb-cam", egl.eglBaseContext)
            surfaceTextureHelper = helper

            val source = pcFactory.createVideoSource(capturer.isScreencast)
            videoSource = source

            capturer.initialize(helper, context.applicationContext, source.capturerObserver)
            capturer.startCapture(1280, 720, 30)

            val track = pcFactory.createVideoTrack("ARDAMSv0", source)
            localVideoTrack = track
            track.setEnabled(true)

            cameraEnabled = true
            hasLocalVideo = true
            track
        } catch (e: Exception) {
            PersistentLog.w(context, TAG, "Failed to initialize local camera for $callUuid; falling back to downlink-only: ${e.message}")
            cleanupLocalVideoLocked()
            null
        }
    }

    fun getRemoteVideoTextureId(): Long? {
        synchronized(lock) {
            if (stopped) return null
            surfaceTextureEntry?.let { return it.id() }
            val track = remoteVideoTrack ?: return null
            val egl = eglBase ?: return null
            val registry = MainActivity.getEngine()?.renderer ?: return null
            if (Looper.myLooper() == Looper.getMainLooper()) {
                attachRemoteVideoTrackLocked(track, egl, registry)
                return surfaceTextureEntry?.id()
            }
            mainHandler.post {
                synchronized(lock) {
                    if (!stopped && surfaceTextureEntry == null && remoteVideoTrack === track) {
                        val e = eglBase ?: return@synchronized
                        val r = MainActivity.getEngine()?.renderer ?: return@synchronized
                        attachRemoteVideoTrackLocked(track, e, r)
                    }
                }
            }
            return null
        }
    }

    fun getLocalVideoTextureId(): Long? {
        synchronized(lock) {
            if (stopped) return null
            localSurfaceTextureEntry?.let { return it.id() }
            val track = localVideoTrack ?: return null
            val egl = eglBase ?: return null
            val registry = MainActivity.getEngine()?.renderer ?: return null
            if (Looper.myLooper() == Looper.getMainLooper()) {
                attachLocalVideoTrackLocked(track, egl, registry)
                return localSurfaceTextureEntry?.id()
            }
            mainHandler.post {
                synchronized(lock) {
                    if (!stopped && localSurfaceTextureEntry == null && localVideoTrack === track) {
                        val e = eglBase ?: return@synchronized
                        val r = MainActivity.getEngine()?.renderer ?: return@synchronized
                        attachLocalVideoTrackLocked(track, e, r)
                    }
                }
            }
            return null
        }
    }

    private fun attachLocalVideoTrack(track: VideoTrack) {
        mainHandler.post {
            synchronized(lock) {
                if (stopped) return@post
                if (localVideoTrack === track && localSurfaceTextureEntry != null) return@post
                localVideoTrack = track
                val egl = eglBase ?: return@post
                val registry = MainActivity.getEngine()?.renderer ?: return@post
                attachLocalVideoTrackLocked(track, egl, registry)
            }
        }
    }

    private fun attachLocalVideoTrackLocked(
        track: VideoTrack,
        egl: EglBase,
        registry: TextureRegistry
    ) {
        localVideoTrack?.let { prev ->
            localSurfaceEglRenderer?.let { prev.removeSink(it) }
        }
        localSurfaceEglRenderer?.release()
        localVideoSurface?.release()
        localSurfaceTextureEntry?.release()

        val entry = registry.createSurfaceTexture()
        val surfaceTexture = entry.surfaceTexture()
        val surface = Surface(surfaceTexture)
        val renderer = SurfaceEglRenderer("WebRtcLocalVideo-$callUuid")
        renderer.init(egl.eglBaseContext, object : RendererCommon.RendererEvents {
            override fun onFirstFrameRendered() {}
            override fun onFrameResolutionChanged(videoWidth: Int, videoHeight: Int, rotation: Int) {
                if (videoWidth > 0 && videoHeight > 0) {
                    mainHandler.post {
                        if (!stopped) {
                            surfaceTexture.setDefaultBufferSize(videoWidth, videoHeight)
                        }
                    }
                }
            }
        }, EglBase.CONFIG_PLAIN, GlRectDrawer())
        renderer.createEglSurface(surface)
        track.addSink(renderer)

        localSurfaceTextureEntry = entry
        localVideoSurface = surface
        localSurfaceEglRenderer = renderer

        val textureId = entry.id()
        onLocalVideoTexture(textureId)
        MethodCallHandler.invokeMethod(
            "facetime-call-state",
            mapOf(
                "phase" to "local-video-texture",
                "call_uuid" to callUuid,
                "texture_id" to textureId,
                "camera_enabled" to cameraEnabled,
                "can_flip_camera" to (cameraCount >= 2),
                "front_camera" to frontCamera
            )
        )
    }

    private fun attachRemoteVideoTrack(track: VideoTrack) {
        mainHandler.post {
            synchronized(lock) {
                if (stopped) return@post
                if (remoteVideoTrack === track && surfaceTextureEntry != null) return@post
                // Keep track even if Flutter engine renderer is not attached yet so getters can create the texture lazily.
                if (remoteVideoTrack !== track) {
                    remoteVideoTrack?.let { prev ->
                        surfaceEglRenderer?.let { prev.removeSink(it) }
                    }
                    surfaceEglRenderer?.release()
                    surfaceEglRenderer = null
                    videoSurface?.release()
                    videoSurface = null
                    surfaceTextureEntry?.release()
                    surfaceTextureEntry = null
                }
                remoteVideoTrack = track
                track.setEnabled(true)
                val egl = eglBase ?: return@post
                val registry = MainActivity.getEngine()?.renderer ?: return@post
                attachRemoteVideoTrackLocked(track, egl, registry)
            }
        }
    }

    private fun attachRemoteVideoTrackLocked(
        track: VideoTrack,
        egl: EglBase,
        registry: TextureRegistry
    ) {
        remoteVideoTrack?.let { prev ->
            surfaceEglRenderer?.let { prev.removeSink(it) }
        }
        surfaceEglRenderer?.release()
        videoSurface?.release()
        surfaceTextureEntry?.release()

        val entry = registry.createSurfaceTexture()
        val surfaceTexture = entry.surfaceTexture()
        val surface = Surface(surfaceTexture)
        val renderer = SurfaceEglRenderer("WebRtcRemoteVideo-$callUuid")
        renderer.init(egl.eglBaseContext, object : RendererCommon.RendererEvents {
            override fun onFirstFrameRendered() {}
            override fun onFrameResolutionChanged(videoWidth: Int, videoHeight: Int, rotation: Int) {
                if (videoWidth > 0 && videoHeight > 0) {
                    mainHandler.post {
                        if (!stopped) {
                            surfaceTexture.setDefaultBufferSize(videoWidth, videoHeight)
                        }
                    }
                }
            }
        }, EglBase.CONFIG_PLAIN, GlRectDrawer())
        renderer.createEglSurface(surface)
        track.setEnabled(true)
        track.addSink(renderer)

        surfaceTextureEntry = entry
        videoSurface = surface
        surfaceEglRenderer = renderer
        remoteVideoTrack = track

        val textureId = entry.id()
        onRemoteVideoTexture(textureId)
        MethodCallHandler.invokeMethod(
            "facetime-call-state",
            mapOf(
                "phase" to "video-texture",
                "call_uuid" to callUuid,
                "texture_id" to textureId
            )
        )
    }

    private fun cleanupLocalVideoLocked() {
        val track = localVideoTrack
        val renderer = localSurfaceEglRenderer
        val surface = localVideoSurface
        val entry = localSurfaceTextureEntry
        val capturer = videoCapturer
        val helper = surfaceTextureHelper
        val source = videoSource

        localVideoTrack = null
        localSurfaceEglRenderer = null
        localVideoSurface = null
        localSurfaceTextureEntry = null
        videoCapturer = null
        surfaceTextureHelper = null
        videoSource = null
        hasLocalVideo = false
        cameraEnabled = false
        cameraCount = 0

        if (track != null || renderer != null || surface != null || entry != null || capturer != null || helper != null || source != null) {
            onLocalVideoTexture(null)
            try {
                if (track != null && renderer != null) {
                    track.removeSink(renderer)
                }
            } catch (_: Exception) {}
            try {
                track?.setEnabled(false)
                track?.dispose()
            } catch (_: Exception) {}
            try {
                capturer?.stopCapture()
            } catch (_: Exception) {}
            try {
                capturer?.dispose()
            } catch (_: Exception) {}
            try {
                helper?.dispose()
            } catch (_: Exception) {}
            try {
                source?.dispose()
            } catch (_: Exception) {}
            try {
                renderer?.release()
            } catch (_: Exception) {}
            try {
                surface?.release()
            } catch (_: Exception) {}
            try {
                entry?.release()
            } catch (_: Exception) {}
        }
    }

    private fun cleanupVideoLocked(): EglBase? {
        cleanupLocalVideoLocked()

        val track = remoteVideoTrack
        val renderer = surfaceEglRenderer
        val surface = videoSurface
        val entry = surfaceTextureEntry
        val egl = eglBase
        remoteVideoTrack = null
        surfaceEglRenderer = null
        videoSurface = null
        surfaceTextureEntry = null
        eglBase = null

        if (track != null || renderer != null || surface != null || entry != null) {
            onRemoteVideoTexture(null)
            try {
                if (track != null && renderer != null) {
                    track.removeSink(renderer)
                }
            } catch (_: Exception) {}
            try {
                renderer?.release()
            } catch (_: Exception) {}
            try {
                surface?.release()
            } catch (_: Exception) {}
            try {
                entry?.release()
            } catch (_: Exception) {}
        }
        return egl
    }

    private fun createAndSendOffer() {
        val pc = peerConnection ?: return
        val constraints = MediaConstraints().apply {
            mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveAudio", "true"))
            mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveVideo", if (wantVideo) "true" else "false"))
        }
        pc.createOffer(object : SdpObserver {
            override fun onCreateSuccess(desc: SessionDescription?) {
                if (desc == null || stopped) return
                pc.setLocalDescription(object : SdpObserver {
                    override fun onSetSuccess() {
                        if (stopped) return
                        emitEvent(
                            "ft-bridge-offer",
                            buildOfferPayload(
                                callUuid = callUuid,
                                sdp = desc.description,
                                wantVideo = wantVideo,
                                hasLocalVideo = hasLocalVideo,
                                answerCall = answerCall
                            )
                        )
                    }

                    override fun onSetFailure(error: String?) {
                        PersistentLog.e(context, TAG, "setLocalDescription failed: $error")
                        onError(error ?: "setLocalDescription failed")
                        stop(sendHangup = false)
                    }

                    override fun onCreateSuccess(p0: SessionDescription?) {}
                    override fun onCreateFailure(p0: String?) {}
                }, desc)
            }

            override fun onCreateFailure(error: String?) {
                PersistentLog.e(context, TAG, "createOffer failed: $error")
                onError(error ?: "createOffer failed")
                stop(sendHangup = false)
            }

            override fun onSetSuccess() {}
            override fun onSetFailure(error: String?) {}
        }, constraints)
    }

    private fun handleRemoteAnswer(sdp: String) {
        val pc: PeerConnection?
        synchronized(lock) {
            if (stopped) return
            pc = peerConnection
        }
        pc ?: return

        val answer = SessionDescription(SessionDescription.Type.ANSWER, sdp)
        pc.setRemoteDescription(object : SdpObserver {
            override fun onSetSuccess() {
                val queued: List<IceCandidate>
                synchronized(lock) {
                    remoteDescriptionSet = true
                    queued = pendingRemoteIce.toList()
                    pendingRemoteIce.clear()
                }
                queued.forEach { pc.addIceCandidate(it) }
            }

            override fun onSetFailure(error: String?) {
                PersistentLog.e(context, TAG, "setRemoteDescription failed: $error")
                onError(error ?: "setRemoteDescription failed")
                stop(sendHangup = false)
            }

            override fun onCreateSuccess(p0: SessionDescription?) {}
            override fun onCreateFailure(p0: String?) {}
        }, answer)
    }

    private fun handleRemoteIce(candidate: IceCandidate) {
        val pc: PeerConnection?
        synchronized(lock) {
            if (stopped) return
            if (!remoteDescriptionSet || peerConnection == null) {
                pendingRemoteIce.add(candidate)
                return
            }
            pc = peerConnection
        }
        pc?.addIceCandidate(candidate)
    }

    private fun emitEvent(event: String, payload: JSONObject) {
        synchronized(lock) {
            if (stopped) return
            val s = socket
            if (s != null && s.connected()) {
                s.emit(event, payload)
            } else {
                pendingOutboundEvents.add(event to payload)
            }
        }
    }

    private fun flushPendingOutbound() {
        val toFlush: List<Pair<String, JSONObject>>
        val activeSock: Socket
        synchronized(lock) {
            val s = socket
            if (stopped || s == null || !s.connected()) return
            activeSock = s
            toFlush = pendingOutboundEvents.toList()
            pendingOutboundEvents.clear()
        }
        toFlush.forEach { (event, payload) -> activeSock.emit(event, payload) }
    }
}
