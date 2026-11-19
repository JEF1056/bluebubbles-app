package com.bluebubbles.messaging.services.telecom

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.services.foreground.SocketIOForegroundService
import com.bluebubbles.messaging.utils.PersistentLog
import com.bluebubbles.messaging.utils.SettingsHelper
import io.socket.client.IO
import io.socket.client.Socket
import io.socket.emitter.Emitter
import org.json.JSONObject
import org.webrtc.AudioSource
import org.webrtc.AudioTrack
import org.webrtc.DataChannel
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpReceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.audio.JavaAudioDeviceModule
import java.net.URI
import java.net.URLEncoder
import java.util.Collections

class WebRtcAudioClient(
    private val context: Context,
    private val callUuid: String,
    private val answerCall: Boolean,
    private val onRemoteHangup: () -> Unit,
    private val onConnected: () -> Unit = {},
    private val onError: (String) -> Unit = {}
) {
    companion object {
        private const val TAG = "WebRtcAudioClient"

        @Volatile
        private var webrtcInitialized = false

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

    @Volatile
    private var remoteDescriptionSet = false

    @Volatile
    private var stopped = false

    @Volatile
    private var muted = false

    private val onAnswerListener = Emitter.Listener { args ->
        val payload = parsePayload(args.getOrNull(0)) ?: return@Listener
        if (payload.optString("callUuid") != callUuid) return@Listener
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
        synchronized(lock) {
            if (stopped || peerConnection != null) return
            try {
                setupSocket()
                setupPeerConnection()
                createAndSendOffer()
            } catch (e: Exception) {
                PersistentLog.e(context, TAG, "Failed to start WebRTC audio bridge for $callUuid", e)
                onError(e.message ?: "WebRTC init failed")
                stop(sendHangup = false)
            }
        }
    }

    fun setMuted(isMuted: Boolean) {
        muted = isMuted
        localAudioTrack?.setEnabled(!isMuted)
        emitEvent(
            "ft-bridge-mute",
            JSONObject().apply {
                put("callUuid", callUuid)
                put("muted", isMuted)
            }
        )
    }

    fun stop(sendHangup: Boolean = true) {
        val socketToClean: Socket?
        val shouldDisconnectSocket: Boolean
        synchronized(lock) {
            if (stopped) return
            stopped = true
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
        }

        socketToClean?.let { s ->
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

    private fun setupSocket() {
        val existing = SocketIOForegroundService.activeSocket
        if (existing != null && existing.connected()) {
            socket = existing
            ownsSocket = false
        } else {
            val settings = SettingsHelper(context)
            val serverUrl = settings.serverAddress
                ?: throw IllegalStateException("Server URL is not configured")
            val password = settings.guidAuthKey
            URI(serverUrl)

            val opts = IO.Options().apply {
                val headers = settings.getAllHeaders()
                if (headers.isNotEmpty()) {
                    extraHeaders = headers.mapValues { Collections.singletonList(it.value) }
                }
                query = "password=${URLEncoder.encode(password, "UTF-8")}"
                reconnection = true
            }
            val newSocket = IO.socket(serverUrl, opts)
            newSocket.on(Socket.EVENT_CONNECT) {
                flushPendingOutbound()
            }
            newSocket.on(Socket.EVENT_CONNECT_ERROR) { args ->
                PersistentLog.w(context, TAG, "Bridge Socket.IO connect error: ${args.firstOrNull()}")
            }
            socket = newSocket
            ownsSocket = true
            newSocket.connect()
        }

        socket?.on("ft-bridge-answer", onAnswerListener)
        socket?.on("ft-bridge-ice", onIceListener)
        socket?.on("ft-bridge-hangup", onHangupListener)
    }

    private fun setupPeerConnection() {
        ensureInitialized(context)
        val adm = JavaAudioDeviceModule.builder(context.applicationContext)
            .setUseHardwareAcousticEchoCanceler(true)
            .setUseHardwareNoiseSuppressor(true)
            .createAudioDeviceModule()
        audioDeviceModule = adm

        val pcFactory = PeerConnectionFactory.builder()
            .setAudioDeviceModule(adm)
            .createPeerConnectionFactory()
        factory = pcFactory

        val iceServers = listOf(
            PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer()
        )
        val rtcConfig = PeerConnection.RTCConfiguration(iceServers).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
        }

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
            override fun onAddTrack(receiver: RtpReceiver?, streams: Array<out MediaStream>?) {}
        }) ?: throw IllegalStateException("createPeerConnection returned null")

        peerConnection = pc

        val source = pcFactory.createAudioSource(MediaConstraints())
        audioSource = source
        val track = pcFactory.createAudioTrack("ARDAMSa0", source)
        track.setEnabled(!muted)
        localAudioTrack = track
        pc.addTrack(track, listOf("ARDAMS"))
    }

    private fun createAndSendOffer() {
        val pc = peerConnection ?: return
        val constraints = MediaConstraints().apply {
            mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveAudio", "true"))
            mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveVideo", "false"))
        }
        pc.createOffer(object : SdpObserver {
            override fun onCreateSuccess(desc: SessionDescription?) {
                if (desc == null || stopped) return
                pc.setLocalDescription(object : SdpObserver {
                    override fun onSetSuccess() {
                        if (stopped) return
                        emitEvent(
                            "ft-bridge-offer",
                            JSONObject().apply {
                                put("callUuid", callUuid)
                                put("sdp", desc.description)
                                put("type", "offer")
                                if (answerCall) {
                                    put("answerCall", true)
                                }
                            }
                        )
                    }

                    override fun onSetFailure(error: String?) {
                        PersistentLog.e(context, TAG, "setLocalDescription failed: $error")
                        onError(error ?: "setLocalDescription failed")
                    }

                    override fun onCreateSuccess(p0: SessionDescription?) {}
                    override fun onCreateFailure(p0: String?) {}
                }, desc)
            }

            override fun onCreateFailure(error: String?) {
                PersistentLog.e(context, TAG, "createOffer failed: $error")
                onError(error ?: "createOffer failed")
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
