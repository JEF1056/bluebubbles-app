package com.bluebubbles.messaging.services.telecom

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.MediaRecorder
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
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
import org.webrtc.CameraEnumerationAndroid
import org.webrtc.CameraEnumerator
import org.webrtc.CameraVideoCapturer
import org.webrtc.DataChannel
import org.webrtc.EglBase
import org.webrtc.EncodedImage
import org.webrtc.GlRectDrawer
import org.webrtc.HardwareVideoDecoderFactory
import org.webrtc.HardwareVideoEncoderFactory
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.MediaStreamTrack
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.Predicate
import org.webrtc.RendererCommon
import org.webrtc.RtpParameters
import org.webrtc.RtpReceiver
import org.webrtc.RtpSender
import org.webrtc.RtpTransceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.SoftwareVideoDecoderFactory
import org.webrtc.SoftwareVideoEncoderFactory
import org.webrtc.SurfaceEglRenderer
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoCodecInfo
import org.webrtc.VideoCodecStatus
import org.webrtc.VideoDecoder
import org.webrtc.VideoDecoderFactory
import org.webrtc.VideoEncoder
import org.webrtc.VideoEncoderFactory
import org.webrtc.VideoFrame
import org.webrtc.VideoSource
import org.webrtc.VideoTrack
import org.webrtc.YuvHelper
import org.webrtc.audio.JavaAudioDeviceModule
import java.net.URI
import java.net.URLEncoder
import java.nio.ByteBuffer
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

internal data class IceServerSpec(
    val urls: List<String>,
    val username: String? = null,
    val credential: String? = null
)

internal data class AdaptiveUplinkRung(
    val width: Int,
    val height: Int,
    val fps: Int,
    val minBitrateBps: Int,
    val maxBitrateBps: Int
) {
    val landscapeWidth: Int get() = maxOf(width, height)
    val landscapeHeight: Int get() = minOf(width, height)
    val portraitWidth: Int get() = minOf(width, height)
    val portraitHeight: Int get() = maxOf(width, height)
}

internal class AdaptiveUplinkSupervisor(
    private val rungs: List<AdaptiveUplinkRung> = DEFAULT_RUNGS
) {
    companion object {
        val DEFAULT_RUNGS = listOf(
            AdaptiveUplinkRung(640, 360, 24, 400_000, 800_000),
            AdaptiveUplinkRung(960, 540, 30, 750_000, 1_400_000),
            AdaptiveUplinkRung(1280, 720, 30, 1_200_000, 2_500_000),
            AdaptiveUplinkRung(1920, 1080, 30, 2_000_000, 4_000_000)
        )
        private const val WARMUP_SAMPLES = 7
        private const val STEP_DOWN_SAMPLES = 2
        private const val STEP_UP_SAMPLES = 2
        private const val BASE_COOLDOWN_MS = 4_000L
        private const val MAX_COOLDOWN_MS = 12_000L
    }

    var currentIndex: Int = rungs.lastIndex
        private set
    private var samplesSeen = 0
    private var badSamples = 0
    private var goodSamples = 0
    private var lastDropMs = 0L
    private var cooldownMs = BASE_COOLDOWN_MS

    val currentRung: AdaptiveUplinkRung
        get() = rungs[currentIndex]

    fun recordSample(lossFraction: Double, limited: Boolean, nowMs: Long): AdaptiveUplinkRung? {
        samplesSeen++
        if (samplesSeen <= WARMUP_SAMPLES) {
            return null
        }
        val unhealthy = lossFraction > 0.08 || limited
        if (unhealthy) {
            goodSamples = 0
            badSamples++
            if (badSamples >= STEP_DOWN_SAMPLES && currentIndex > 0) {
                badSamples = 0
                if (lastDropMs > 0L && nowMs - lastDropMs < cooldownMs * 2) {
                    cooldownMs = (cooldownMs + 6_000L).coerceAtMost(MAX_COOLDOWN_MS)
                } else {
                    cooldownMs = BASE_COOLDOWN_MS
                }
                lastDropMs = nowMs
                currentIndex--
                return currentRung
            }
            return null
        }

        badSamples = 0
        if (lossFraction < 0.01 && currentIndex < rungs.lastIndex) {
            if (nowMs - lastDropMs < cooldownMs) return null
            goodSamples++
            if (goodSamples >= STEP_UP_SAMPLES) {
                goodSamples = 0
                currentIndex++
                return currentRung
            }
        } else {
            goodSamples = 0
        }
        return null
    }
}

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

        internal fun rotatedFrameSize(videoWidth: Int, videoHeight: Int, rotation: Int): Pair<Int, Int> =
            if (rotation % 180 != 0) videoHeight to videoWidth else videoWidth to videoHeight

        internal fun buildLocalVideoTexturePayload(
            callUuid: String,
            textureId: Long,
            width: Int,
            height: Int,
            cameraEnabled: Boolean,
            canFlipCamera: Boolean,
            frontCamera: Boolean
        ): Map<String, Any> {
            val payload = linkedMapOf<String, Any>(
                "phase" to "local-video-texture",
                "call_uuid" to callUuid,
                "texture_id" to textureId,
                "camera_enabled" to cameraEnabled,
                "can_flip_camera" to canFlipCamera,
                "front_camera" to frontCamera
            )
            if (width > 0 && height > 0) {
                payload["width"] = width
                payload["height"] = height
            }
            return payload
        }

        internal fun isAllowedMediaCodec(name: String, isHardwareAccelerated: Boolean): Boolean {
            if (isHardwareAccelerated) return true
            val lower = name.lowercase()
            return lower.startsWith("c2.android.avc") ||
                lower.startsWith("c2.google.") ||
                lower.startsWith("omx.google.h264")
        }

        internal fun selectH264EncoderColorFormat(colorFormats: IntArray): Int? = when {
            colorFormats.contains(MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar) ->
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar
            colorFormats.contains(MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar) ->
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar
            else -> null
        }

        internal fun hasH264SpsPrefix(bytes: ByteArray): Boolean {
            if (bytes.size >= 5 && bytes[0] == 0.toByte() && bytes[1] == 0.toByte() &&
                bytes[2] == 0.toByte() && bytes[3] == 1.toByte() && (bytes[4].toInt() and 0x1f) == 7
            ) {
                return true
            }
            return bytes.size >= 4 && bytes[0] == 0.toByte() && bytes[1] == 0.toByte() &&
                bytes[2] == 1.toByte() && (bytes[3].toInt() and 0x1f) == 7
        }

        internal fun prependH264ConfigIfMissing(
            frameBytes: ByteArray,
            configBytes: ByteArray?,
            isKeyFrame: Boolean
        ): ByteArray {
            if (!isKeyFrame || configBytes == null || configBytes.isEmpty() || hasH264SpsPrefix(frameBytes)) {
                return frameBytes
            }
            return ByteArray(configBytes.size + frameBytes.size).apply {
                System.arraycopy(configBytes, 0, this, 0, configBytes.size)
                System.arraycopy(frameBytes, 0, this, configBytes.size, frameBytes.size)
            }
        }

        private fun findFallbackH264EncoderInfo(): Pair<String, Int>? {
            return try {
                for (info in MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos) {
                    if (!info.isEncoder) continue
                    val avcType = info.supportedTypes.firstOrNull {
                        it.equals(MediaFormat.MIMETYPE_VIDEO_AVC, ignoreCase = true)
                    } ?: continue
                    val hw = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        info.isHardwareAccelerated
                    } else {
                        val lower = info.name.lowercase()
                        !lower.startsWith("omx.google.") && !lower.startsWith("c2.android.")
                    }
                    if (!isAllowedMediaCodec(info.name, hw)) continue
                    val fmt = selectH264EncoderColorFormat(info.getCapabilitiesForType(avcType).colorFormats) ?: continue
                    return info.name to fmt
                }
                null
            } catch (_: Exception) {
                null
            }
        }

        internal fun sdpContainsH264(sdp: String?): Boolean =
            sdp?.contains("H264/90000", ignoreCase = true) == true

        internal fun summarizeIceCandidate(candidateSdp: String?): String {
            if (candidateSdp.isNullOrBlank()) return "unknown"
            val tokens = candidateSdp.trim().split(Regex("\\s+"))
            val ip = tokens.getOrNull(4) ?: "?"
            val port = tokens.getOrNull(5) ?: "?"
            val typIdx = tokens.indexOf("typ")
            val type = if (typIdx >= 0) tokens.getOrNull(typIdx + 1) ?: "?" else "?"
            return "$type $ip:$port"
        }

        internal fun selectCaptureSize(
            formats: List<CameraEnumerationAndroid.CaptureFormat>?
        ): Triple<Int, Int, Int> {
            if (formats.isNullOrEmpty()) return Triple(1920, 1080, 30)
            // Prefer exact 1920x1080, else largest <= 1920x1080 (with >= 720p preference), fallback 1280x720
            val candidates = formats.filter { it.width <= 1920 && it.height <= 1080 }
            val best = candidates.maxWithOrNull(
                compareBy<CameraEnumerationAndroid.CaptureFormat> { it.width * it.height }
                    .thenBy { it.framerate.max }
            ) ?: formats.minByOrNull { kotlin.math.abs(it.width * it.height - 1920 * 1080) }
            val w = best?.width ?: 1920
            val h = best?.height ?: 1080
            val rawMax = best?.framerate?.max ?: 30_000
            val maxFps = (if (rawMax > 1000) rawMax / 1000 else rawMax).coerceIn(15, 30)
            return Triple(w, h, maxFps)
        }

        internal fun buildAudioConstraints(voiceIsolationEnabled: Boolean): MediaConstraints =
            MediaConstraints().apply {
                val iso = voiceIsolationEnabled.toString()
                mandatory.add(MediaConstraints.KeyValuePair("googEchoCancellation", "true"))
                mandatory.add(MediaConstraints.KeyValuePair("googNoiseSuppression", iso))
                mandatory.add(MediaConstraints.KeyValuePair("googHighpassFilter", iso))
                mandatory.add(MediaConstraints.KeyValuePair("googAutoGainControl", "true"))
                mandatory.add(MediaConstraints.KeyValuePair("googTypingNoiseDetection", iso))
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
    private val socketLock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val disconnectTimeoutRunnable = Runnable {
        if (!stopped) {
            PersistentLog.w(context, TAG, "ICE disconnected >10s for $callUuid; hanging up")
            onRemoteHangup()
        }
    }

    private var lastAudioStatsLogMs = 0L

    private val statsSupervisorRunnable = object : Runnable {
        override fun run() {
            try {
                val pc = synchronized(lock) {
                    if (stopped) null else peerConnection
                }
                pc?.getStats { report ->
                    if (stopped) return@getStats
                    var lossFraction = 0.0
                    var limited = false
                    var inAudioBytes = 0L
                    var inAudioPackets = 0L
                    var inAudioLost = 0L
                    var inAudioLevel = 0.0
                    var outAudioBytes = 0L
                    var outAudioPackets = 0L
                    var outVideoW = 0
                    var outVideoH = 0
                    var outVideoFps = 0.0
                    var outVideoReason = "none"

                    for (stat in report.statsMap.values) {
                        when (stat.type) {
                            "remote-inbound-rtp" -> {
                                val kind = stat.members["kind"] as? String
                                if (kind == "video") {
                                    val fl = (stat.members["fractionLost"] as? Number)?.toDouble()
                                    if (fl != null) lossFraction = fl
                                }
                            }
                            "inbound-rtp" -> {
                                val kind = stat.members["kind"] as? String
                                if (kind == "audio") {
                                    inAudioBytes = (stat.members["bytesReceived"] as? Number)?.toLong() ?: 0L
                                    inAudioPackets = (stat.members["packetsReceived"] as? Number)?.toLong() ?: 0L
                                    inAudioLost = (stat.members["packetsLost"] as? Number)?.toLong() ?: 0L
                                    val lvl = (stat.members["audioLevel"] as? Number)?.toDouble()
                                    if (lvl != null && lvl > 0) inAudioLevel = lvl
                                }
                            }
                            "outbound-rtp" -> {
                                val kind = stat.members["kind"] as? String
                                if (kind == "video") {
                                    val reason = stat.members["qualityLimitationReason"] as? String
                                    if (reason != null) outVideoReason = reason
                                    if (reason == "bandwidth" || reason == "cpu") {
                                        limited = true
                                    }
                                    outVideoW = (stat.members["frameWidth"] as? Number)?.toInt() ?: outVideoW
                                    outVideoH = (stat.members["frameHeight"] as? Number)?.toInt() ?: outVideoH
                                    outVideoFps = (stat.members["framesPerSecond"] as? Number)?.toDouble() ?: outVideoFps
                                } else if (kind == "audio") {
                                    outAudioBytes = (stat.members["bytesSent"] as? Number)?.toLong() ?: 0L
                                    outAudioPackets = (stat.members["packetsSent"] as? Number)?.toLong() ?: 0L
                                }
                            }
                        }
                    }

                    val now = System.currentTimeMillis()
                    if (now - lastAudioStatsLogMs >= 6_000L) {
                        lastAudioStatsLogMs = now
                        PersistentLog.d(
                            context,
                            Constants.logTag,
                            "[$TAG] Audio stats ($callUuid): inBytes=$inAudioBytes inPkts=$inAudioPackets inLost=$inAudioLost inLevel=${"%.3f".format(inAudioLevel)} outBytes=$outAudioBytes outPkts=$outAudioPackets muted=$muted"
                        )
                        if (wantVideo) {
                            PersistentLog.d(
                                context,
                                Constants.logTag,
                                "[$TAG] Video stats ($callUuid): out=${outVideoW}x${outVideoH}@${"%.1f".format(outVideoFps)} qlr=$outVideoReason loss=${"%.3f".format(lossFraction)} rung=${adaptiveSupervisor.currentIndex}"
                            )
                        }
                    }

                    if (wantVideo) {
                        val nextRung = adaptiveSupervisor.recordSample(
                            lossFraction = lossFraction,
                            limited = limited,
                            nowMs = now
                        )
                        if (nextRung != null) {
                            val (src, sender) = synchronized(lock) {
                                if (stopped) null to null else videoSource to videoSender
                            }
                            src?.adaptOutputFormat(
                                nextRung.landscapeWidth,
                                nextRung.landscapeHeight,
                                nextRung.portraitWidth,
                                nextRung.portraitHeight,
                                nextRung.fps
                            )
                            updateVideoSenderRung(sender, nextRung)
                        }
                    }
                }
            } catch (_: Exception) {}
            synchronized(lock) {
                if (!stopped) {
                    mainHandler.postDelayed(this, 2_000L)
                }
            }
        }
    }

    private fun configureVideoSenderParameters(sender: RtpSender?) {
        sender ?: return
        try {
            val params = sender.parameters
            params.degradationPreference = RtpParameters.DegradationPreference.BALANCED
            params.encodings.firstOrNull()?.apply {
                minBitrateBps = 150_000
                maxBitrateBps = 4_000_000
                maxFramerate = 30
            }
            sender.parameters = params
        } catch (e: Exception) {
            PersistentLog.w(context, TAG, "configureVideoSenderParameters failed for $callUuid: ${e.message}")
        }
    }

    private fun updateVideoSenderRung(sender: RtpSender?, rung: AdaptiveUplinkRung) {
        sender ?: return
        try {
            val params = sender.parameters
            params.encodings.firstOrNull()?.apply {
                minBitrateBps = rung.minBitrateBps
                maxBitrateBps = rung.maxBitrateBps
                maxFramerate = rung.fps
            }
            sender.parameters = params
        } catch (e: Exception) {
            PersistentLog.w(context, TAG, "updateVideoSenderRung failed for $callUuid: ${e.message}")
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
    private var remoteAudioTrack: AudioTrack? = null
    private var audioSender: RtpSender? = null
    private var videoSender: RtpSender? = null
    private var peerConnection: PeerConnection? = null

    private var eglBase: EglBase? = null
    private var surfaceTextureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var remoteAttachedRegistry: TextureRegistry? = null
    private var videoSurface: Surface? = null
    private var surfaceEglRenderer: SurfaceEglRenderer? = null
    private var remoteVideoTrack: VideoTrack? = null
    private var remoteVideoWidth = 0
    private var remoteVideoHeight = 0

    private var videoCapturer: CameraVideoCapturer? = null
    private var surfaceTextureHelper: SurfaceTextureHelper? = null
    private var videoSource: VideoSource? = null
    private var videoProcessor: FaceTimeVideoProcessor? = null
    private var localVideoTrack: VideoTrack? = null
    private var localSurfaceTextureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var localAttachedRegistry: TextureRegistry? = null
    private var localVideoSurface: Surface? = null
    private var localSurfaceEglRenderer: SurfaceEglRenderer? = null
    private var localVideoWidth = 0
    private var localVideoHeight = 0
    private var cameraCount = 0
    private var captureWidth = 1920
    private var captureHeight = 1080
    private var captureFps = 30
    private val adaptiveSupervisor = AdaptiveUplinkSupervisor()

    @Volatile
    private var voiceIsolationEnabled = true

    @Volatile
    private var pendingVideoEffect: String? = null

    @Volatile
    private var pendingVideoDenoise: Boolean = false

    @Volatile
    private var pendingVirtualBgPath: String? = null

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
            val pcToUpdate = synchronized(lock) {
                if (!stopped && parsed != configuredIceSpecs) {
                    configuredIceSpecs = parsed
                    peerConnection
                } else {
                    null
                }
            }
            if (pcToUpdate != null) {
                try {
                    pcToUpdate.setConfiguration(buildRtcConfig(parsed))
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
                activeSock = synchronized(socketLock) { socket }
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
            val createdPc: PeerConnection? = synchronized(lock) {
                if (stopped || peerConnection != null) {
                    starting = false
                    null
                } else {
                    configuredIceSpecs = iceSpecs
                    setupPeerConnection(iceSpecs)
                    starting = false
                    peerConnection
                }
            }
            if (createdPc != null && !stopped) {
                createAndSendOffer(createdPc)
            }
        } catch (e: Exception) {
            synchronized(lock) { starting = false }
            PersistentLog.e(context, TAG, "Failed to start WebRTC audio bridge for $callUuid", e)
            onError(e.message ?: "WebRTC init failed")
            stop(sendHangup = false)
        }
    }

    private fun fetchIceServersFromConnectedSocket(): List<IceServerSpec>? {
        val activeSocket = synchronized(socketLock) { socket }
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
                val pcToUpdate = synchronized(lock) {
                    if (!stopped && specs != configuredIceSpecs) {
                        configuredIceSpecs = specs
                        peerConnection
                    } else {
                        null
                    }
                }
                if (pcToUpdate != null) {
                    try {
                        pcToUpdate.setConfiguration(buildRtcConfig(specs))
                    } catch (_: Exception) {}
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

    private fun buildCodecAllowedPredicate(): Predicate<MediaCodecInfo> = Predicate { info ->
        val hw = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            info.isHardwareAccelerated
        } else {
            val lower = info.name.lowercase()
            !lower.startsWith("omx.google.") && !lower.startsWith("c2.android.")
        }
        isAllowedMediaCodec(info.name, hw)
    }

    private fun buildVideoEncoderFactory(egl: EglBase): VideoEncoderFactory {
        val hw = HardwareVideoEncoderFactory(egl.eglBaseContext, true, true, buildCodecAllowedPredicate())
        val sw = SoftwareVideoEncoderFactory()
        val baseCodecs = (hw.supportedCodecs.toList() + sw.supportedCodecs.toList())
            .distinctBy { it.name to it.params }
        val fallbackH264 = if (baseCodecs.none { it.name.equals("H264", ignoreCase = true) }) {
            findFallbackH264EncoderInfo()
        } else {
            null
        }
        val fallbackCodecInfo = fallbackH264?.let {
            VideoCodecInfo(
                "H264",
                mapOf(
                    VideoCodecInfo.H264_FMTP_PROFILE_LEVEL_ID to VideoCodecInfo.H264_CONSTRAINED_BASELINE_3_1,
                    VideoCodecInfo.H264_FMTP_LEVEL_ASYMMETRY_ALLOWED to "1",
                    VideoCodecInfo.H264_FMTP_PACKETIZATION_MODE to "1"
                ),
                emptyList()
            )
        }
        return object : VideoEncoderFactory {
            override fun createEncoder(info: VideoCodecInfo): VideoEncoder? =
                hw.createEncoder(info)
                    ?: sw.createEncoder(info)
                    ?: if (fallbackH264 != null && info.name.equals("H264", ignoreCase = true)) {
                        MediaCodecH264FallbackEncoder(fallbackH264.first, fallbackH264.second)
                    } else {
                        null
                    }

            override fun getSupportedCodecs(): Array<VideoCodecInfo> =
                if (fallbackCodecInfo != null) {
                    (baseCodecs + fallbackCodecInfo).toTypedArray()
                } else {
                    baseCodecs.toTypedArray()
                }
        }
    }

    private fun buildVideoDecoderFactory(egl: EglBase): VideoDecoderFactory {
        val hw = HardwareVideoDecoderFactory(egl.eglBaseContext, buildCodecAllowedPredicate())
        val sw = SoftwareVideoDecoderFactory()
        return object : VideoDecoderFactory {
            override fun createDecoder(info: VideoCodecInfo): VideoDecoder? =
                hw.createDecoder(info) ?: sw.createDecoder(info)

            override fun getSupportedCodecs(): Array<VideoCodecInfo> =
                (hw.supportedCodecs.toList() + sw.supportedCodecs.toList())
                    .distinctBy { it.name to it.params }
                    .toTypedArray()
        }
    }

    fun setMuted(isMuted: Boolean) {
        val track = synchronized(lock) {
            if (stopped) return
            muted = isMuted
            localAudioTrack
        }
        try {
            track?.setEnabled(!isMuted)
        } catch (_: IllegalStateException) {}
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

    fun setVoiceIsolation(enabled: Boolean): Boolean {
        val adm: JavaAudioDeviceModule?
        synchronized(lock) {
            voiceIsolationEnabled = enabled
            if (stopped) return true
            adm = audioDeviceModule
        }

        try {
            adm?.setNoiseSuppressorEnabled(enabled)
        } catch (_: Exception) {}

        val pcFactory: PeerConnectionFactory
        val sender: RtpSender
        val isMuted: Boolean
        synchronized(lock) {
            if (stopped) return false
            pcFactory = factory ?: return true
            sender = audioSender ?: return true
            isMuted = muted
        }

        return try {
            val newSource = pcFactory.createAudioSource(buildAudioConstraints(enabled))
            val newTrack = pcFactory.createAudioTrack("ARDAMSa0", newSource).apply {
                setEnabled(!isMuted)
            }
            sender.setTrack(newTrack, false)
            var oldSource: AudioSource? = null
            var oldTrack: AudioTrack? = null
            var keptNew = false
            synchronized(lock) {
                if (!stopped && audioSender === sender && factory === pcFactory) {
                    oldSource = audioSource
                    oldTrack = localAudioTrack
                    audioSource = newSource
                    localAudioTrack = newTrack
                    keptNew = true
                }
            }
            if (!keptNew) {
                try {
                    newTrack.setEnabled(false)
                    newTrack.dispose()
                } catch (_: Exception) {}
                try {
                    newSource.dispose()
                } catch (_: Exception) {}
                return false
            }
            try {
                oldTrack?.setEnabled(false)
                oldTrack?.dispose()
            } catch (_: Exception) {}
            try {
                oldSource?.dispose()
            } catch (_: Exception) {}
            true
        } catch (e: Exception) {
            PersistentLog.w(context, TAG, "setVoiceIsolation($enabled) failed for $callUuid: ${e.message}")
            false
        }
    }

    fun setPreferredInputDevice(deviceInfo: AudioDeviceInfo?) {
        val adm = synchronized(lock) {
            if (stopped) return
            audioDeviceModule
        }
        try {
            adm?.setPreferredInputDevice(deviceInfo)
        } catch (e: Exception) {
            PersistentLog.w(context, TAG, "setPreferredInputDevice failed for $callUuid: ${e.message}")
        }
    }

    fun setVideoProcessing(effect: String?, denoise: Boolean, backgroundPath: String?): Boolean {
        val proc = synchronized(lock) {
            pendingVideoEffect = effect
            pendingVideoDenoise = denoise
            pendingVirtualBgPath = backgroundPath
            videoProcessor
        }
        proc?.updateConfig(effect, denoise, backgroundPath)
        return true
    }

    fun setCameraEnabled(enabled: Boolean): Boolean {
        val track: VideoTrack?
        val capturer: CameraVideoCapturer?
        val capW: Int
        val capH: Int
        val capFps: Int
        synchronized(lock) {
            if (stopped || !hasLocalVideo) return false
            if (cameraEnabled == enabled) return true
            cameraEnabled = enabled
            track = localVideoTrack
            capturer = videoCapturer
            capW = captureWidth
            capH = captureHeight
            capFps = captureFps
        }
        try {
            track?.setEnabled(enabled)
        } catch (_: IllegalStateException) {}
        if (capturer != null) {
            cameraExecutor.execute {
                val shouldRun = synchronized(lock) {
                    !stopped && videoCapturer === capturer && cameraEnabled == enabled
                }
                if (!shouldRun) return@execute
                try {
                    if (enabled) {
                        capturer.startCapture(capW, capH, capFps)
                    } else {
                        capturer.stopCapture()
                    }
                } catch (e: Exception) {
                    PersistentLog.w(context, TAG, "setCameraEnabled($enabled) failed for $callUuid: ${e.message}")
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
                        val w: Int
                        val h: Int
                        synchronized(lock) {
                            if (stopped) return@post
                            textureId = localSurfaceTextureEntry?.id()
                            enabled = cameraEnabled
                            canFlip = cameraCount >= 2
                            w = localVideoWidth
                            h = localVideoHeight
                        }
                        if (textureId != null) {
                            MethodCallHandler.invokeMethod(
                                "facetime-call-state",
                                buildMap {
                                    put("phase", "local-video-texture")
                                    put("call_uuid", callUuid)
                                    put("texture_id", textureId)
                                    if (w > 0 && h > 0) {
                                        put("width", w)
                                        put("height", h)
                                    }
                                    put("camera_enabled", enabled)
                                    put("can_flip_camera", canFlip)
                                    put("front_camera", isFrontCamera)
                                }
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

    /** Restarts local camera capture and requests an IDR keyframe after screen unlock/resume. */
    fun resumeVideo(): Boolean {
        val capturer: CameraVideoCapturer?
        val shouldRestartLocal: Boolean
        val capW: Int
        val capH: Int
        val capFps: Int
        synchronized(lock) {
            if (stopped) return false
            capturer = videoCapturer
            shouldRestartLocal = hasLocalVideo && cameraEnabled && capturer != null
            capW = captureWidth
            capH = captureHeight
            capFps = captureFps
        }
        if (shouldRestartLocal && capturer != null) {
            cameraExecutor.execute {
                val okToStart = synchronized(lock) {
                    !stopped && videoCapturer === capturer && cameraEnabled
                }
                if (!okToStart) return@execute
                try {
                    capturer.stopCapture()
                } catch (_: Exception) {}
                try {
                    capturer.startCapture(capW, capH, capFps)
                } catch (e: Exception) {
                    PersistentLog.w(context, TAG, "resumeVideo startCapture failed for $callUuid: ${e.message}")
                }
            }
        }
        emitEvent("ft-bridge-keyframe", JSONObject().apply { put("callUuid", callUuid) })
        mainHandler.post {
            val r = MainActivity.getEngine()?.renderer ?: return@post
            val rTrack: VideoTrack?
            val lTrack: VideoTrack?
            val egl: EglBase?
            val needsRemoteAttach: Boolean
            val needsLocalAttach: Boolean
            synchronized(lock) {
                if (stopped) return@post
                rTrack = remoteVideoTrack
                lTrack = localVideoTrack
                egl = eglBase
                needsRemoteAttach = rTrack != null && egl != null &&
                    (surfaceTextureEntry == null || remoteAttachedRegistry !== r)
                needsLocalAttach = lTrack != null && egl != null &&
                    (localSurfaceTextureEntry == null || localAttachedRegistry !== r)
            }
            if (needsRemoteAttach && rTrack != null && egl != null) {
                attachRemoteVideoTrackOnMain(rTrack, egl, r)
            }
            if (needsLocalAttach && lTrack != null && egl != null) {
                attachLocalVideoTrackOnMain(lTrack, egl, r)
            }
        }
        return true
    }

    private fun stopAsync(sendHangup: Boolean = false) {
        Thread({ stop(sendHangup = sendHangup) }, "bb-webrtc-stop").apply { isDaemon = true }.start()
    }

    private fun releaseTextureEntry(entry: TextureRegistry.SurfaceTextureEntry?) {
        entry ?: return
        if (Looper.myLooper() == Looper.getMainLooper()) {
            try {
                entry.release()
            } catch (_: Exception) {}
        } else {
            mainHandler.post {
                try {
                    entry.release()
                } catch (_: Exception) {}
            }
        }
    }

    private data class LocalVideoHandles(
        val track: VideoTrack?,
        val renderer: SurfaceEglRenderer?,
        val surface: Surface?,
        val entry: TextureRegistry.SurfaceTextureEntry?,
        val capturer: CameraVideoCapturer?,
        val helper: SurfaceTextureHelper?,
        val source: VideoSource?,
        val proc: FaceTimeVideoProcessor?
    )

    private data class RemoteVideoHandles(
        val track: VideoTrack?,
        val renderer: SurfaceEglRenderer?,
        val surface: Surface?,
        val entry: TextureRegistry.SurfaceTextureEntry?,
        val egl: EglBase?
    )

    fun stop(sendHangup: Boolean = true) {
        val localHandles: LocalVideoHandles
        val remoteHandles: RemoteVideoHandles
        val audioTrackToClean: AudioTrack?
        val remoteAudioTrackToClean: AudioTrack?
        val audioSourceToClean: AudioSource?
        val pcToClean: PeerConnection?
        val admToClean: JavaAudioDeviceModule?
        val factoryToClean: PeerConnectionFactory?
        val leaseToRelease: CallResourceLease?
        synchronized(lock) {
            if (stopped) return
            stopped = true
            connectLatch?.countDown()
            pendingIceLatch?.countDown()
            mainHandler.removeCallbacks(disconnectTimeoutRunnable)
            mainHandler.removeCallbacks(statsSupervisorRunnable)
            pendingRemoteIce.clear()

            localHandles = detachLocalVideoFieldsLocked()
            remoteHandles = detachRemoteVideoFieldsLocked()

            audioTrackToClean = localAudioTrack
            localAudioTrack = null
            remoteAudioTrackToClean = remoteAudioTrack
            remoteAudioTrack = null
            audioSourceToClean = audioSource
            audioSource = null
            pcToClean = peerConnection
            peerConnection = null
            admToClean = audioDeviceModule
            audioDeviceModule = null
            factoryToClean = factory
            factory = null
            leaseToRelease = callResourceLease
            callResourceLease = null
        }

        val socketToClean: Socket?
        val shouldDisconnectSocket: Boolean
        synchronized(socketLock) {
            pendingOutboundEvents.clear()
            socketToClean = socket
            shouldDisconnectSocket = ownsSocket
            socket = null
            ownsSocket = false
        }

        if (sendHangup) {
            try {
                val hangupPayload = JSONObject().apply { put("callUuid", callUuid) }
                socketToClean?.takeIf { it.connected() }?.emit("ft-bridge-hangup", hangupPayload)
            } catch (_: Exception) {}
        }

        try {
            // Stop camera capture before closing PeerConnection so no new frames enter the source.
            try {
                localHandles.capturer?.stopCapture()
            } catch (_: Exception) {}

            // Close and dispose PeerConnection BEFORE disposing tracks/sources/EGL so native
            // RtpSender/RtpReceiver references are released cleanly without aborting.
            try {
                pcToClean?.close()
                pcToClean?.dispose()
            } catch (_: Exception) {}

            disposeLocalVideoHandles(localHandles)
            disposeRemoteVideoHandles(remoteHandles)

            try {
                audioTrackToClean?.setEnabled(false)
                audioTrackToClean?.dispose()
            } catch (_: Exception) {}

            try {
                remoteAudioTrackToClean?.setEnabled(false)
                remoteAudioTrackToClean?.dispose()
            } catch (_: Exception) {}

            try {
                audioSourceToClean?.dispose()
            } catch (_: Exception) {}

            try {
                admToClean?.release()
            } catch (_: Exception) {}

            try {
                factoryToClean?.dispose()
            } catch (_: Exception) {}

            val eglToRelease = remoteHandles.egl
            if (eglToRelease != null) {
                mainHandler.post {
                    try {
                        eglToRelease.release()
                    } catch (_: Exception) {}
                }
            }
        } finally {
            try {
                leaseToRelease?.releaseAll()
            } catch (_: Exception) {}
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
            synchronized(socketLock) {
                socket = existing
                ownsSocket = false
                connectLatch = CountDownLatch(0)
            }
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
            synchronized(socketLock) {
                connectLatch = CountDownLatch(1)
                socket = newSocket
                ownsSocket = true
            }
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

        val hasRecordAudio = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
        if (!hasRecordAudio) {
            PersistentLog.w(context, TAG, "RECORD_AUDIO permission not granted for $callUuid; microphone capture will produce silence or fail")
        }

        val adm = JavaAudioDeviceModule.builder(context.applicationContext)
            .setAudioSource(MediaRecorder.AudioSource.VOICE_COMMUNICATION)
            .setUseHardwareAcousticEchoCanceler(JavaAudioDeviceModule.isBuiltInAcousticEchoCancelerSupported())
            .setUseHardwareNoiseSuppressor(JavaAudioDeviceModule.isBuiltInNoiseSuppressorSupported())
            .setAudioRecordErrorCallback(object : JavaAudioDeviceModule.AudioRecordErrorCallback {
                override fun onWebRtcAudioRecordInitError(errorMessage: String?) {
                    PersistentLog.e(context, TAG, "[$TAG] AudioRecord init error: $errorMessage")
                }
                override fun onWebRtcAudioRecordStartError(
                    errorCode: JavaAudioDeviceModule.AudioRecordStartErrorCode?,
                    errorMessage: String?
                ) {
                    PersistentLog.e(context, TAG, "[$TAG] AudioRecord start error: $errorCode - $errorMessage")
                }
                override fun onWebRtcAudioRecordError(errorMessage: String?) {
                    PersistentLog.e(context, TAG, "[$TAG] AudioRecord error: $errorMessage")
                }
            })
            .setAudioTrackErrorCallback(object : JavaAudioDeviceModule.AudioTrackErrorCallback {
                override fun onWebRtcAudioTrackInitError(errorMessage: String?) {
                    PersistentLog.e(context, TAG, "[$TAG] AudioTrack init error: $errorMessage")
                }
                override fun onWebRtcAudioTrackStartError(
                    errorCode: JavaAudioDeviceModule.AudioTrackStartErrorCode?,
                    errorMessage: String?
                ) {
                    PersistentLog.e(context, TAG, "[$TAG] AudioTrack start error: $errorCode - $errorMessage")
                }
                override fun onWebRtcAudioTrackError(errorMessage: String?) {
                    PersistentLog.e(context, TAG, "[$TAG] AudioTrack error: $errorMessage")
                }
            })
            .createAudioDeviceModule()
        try {
            adm.setNoiseSuppressorEnabled(voiceIsolationEnabled)
        } catch (_: Exception) {}
        audioDeviceModule = adm

        val factoryBuilder = PeerConnectionFactory.builder()
            .setAudioDeviceModule(adm)

        if (wantVideo) {
            val egl = EglBase.create()
            eglBase = egl
            factoryBuilder
                .setVideoDecoderFactory(buildVideoDecoderFactory(egl))
                .setVideoEncoderFactory(buildVideoEncoderFactory(egl))
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
                        mainHandler.post {
                            if (!stopped) {
                                MethodCallHandler.invokeMethod(
                                    "facetime-call-state",
                                    mapOf(
                                        "phase" to "ice-state",
                                        "call_uuid" to callUuid,
                                        "state" to "connected"
                                    )
                                )
                            }
                        }
                        onConnected()
                    }
                    PeerConnection.IceConnectionState.DISCONNECTED -> {
                        mainHandler.removeCallbacks(disconnectTimeoutRunnable)
                        mainHandler.post {
                            if (!stopped) {
                                MethodCallHandler.invokeMethod(
                                    "facetime-call-state",
                                    mapOf(
                                        "phase" to "ice-state",
                                        "call_uuid" to callUuid,
                                        "state" to "disconnected"
                                    )
                                )
                            }
                        }
                        synchronized(lock) {
                            if (!stopped) {
                                mainHandler.postDelayed(disconnectTimeoutRunnable, 45_000L)
                            }
                        }
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
                PersistentLog.d(
                    context,
                    Constants.logTag,
                    "[$TAG] Local ICE ($callUuid): ${summarizeIceCandidate(candidate.sdp)} mid=${candidate.sdpMid}"
                )
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
                if (stopped) return
                val track = receiver?.track()
                if (track is AudioTrack) {
                    track.setEnabled(true)
                    track.setVolume(1.0)
                    synchronized(lock) {
                        remoteAudioTrack = track
                    }
                    PersistentLog.d(
                        context,
                        Constants.logTag,
                        "[$TAG] Remote audio track attached ($callUuid): id=${track.id()} enabled=${track.enabled()}"
                    )
                } else if (wantVideo && track is VideoTrack) {
                    attachRemoteVideoTrack(track)
                }
            }
        }) ?: throw IllegalStateException("createPeerConnection returned null")

        peerConnection = pc

        val source = pcFactory.createAudioSource(buildAudioConstraints(voiceIsolationEnabled))
        audioSource = source
        val track = pcFactory.createAudioTrack("ARDAMSa0", source)
        track.setEnabled(!muted)
        localAudioTrack = track
        audioSender = pc.addTrack(track, listOf("ARDAMS"))

        mainHandler.removeCallbacks(statsSupervisorRunnable)
        mainHandler.postDelayed(statsSupervisorRunnable, 2_000L)

        if (wantVideo) {
            val localTrack = setupLocalVideoTrack(pcFactory)
            if (localTrack != null) {
                val transceiver = pc.addTransceiver(
                    localTrack,
                    RtpTransceiver.RtpTransceiverInit(
                        RtpTransceiver.RtpTransceiverDirection.SEND_RECV,
                        listOf("ARDAMS")
                    )
                )
                videoSender = transceiver.sender
                configureVideoSenderParameters(transceiver.sender)
                attachLocalVideoTrack(localTrack)
                mainHandler.removeCallbacks(statsSupervisorRunnable)
                mainHandler.postDelayed(statsSupervisorRunnable, 2_000L)
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

            val capturer = enumerator.createCapturer(
                selectedDevice,
                object : CameraVideoCapturer.CameraEventsHandler {
                    override fun onCameraError(errorDescription: String?) {
                        PersistentLog.w(context, TAG, "Camera2 error for $callUuid: $errorDescription")
                    }
                    override fun onCameraDisconnected() {
                        PersistentLog.w(context, TAG, "Camera2 disconnected for $callUuid")
                    }
                    override fun onCameraFreezed(errorDescription: String?) {
                        PersistentLog.w(context, TAG, "Camera2 freezed for $callUuid: $errorDescription")
                    }
                    override fun onCameraOpening(cameraName: String?) {}
                    override fun onFirstFrameAvailable() {}
                    override fun onCameraClosed() {}
                }
            )
            if (capturer == null) {
                PersistentLog.w(context, TAG, "createCapturer returned null for $selectedDevice; falling back to downlink-only")
                return null
            }
            videoCapturer = capturer

            val (w, h, fps) = selectCaptureSize(enumerator.getSupportedFormats(selectedDevice))
            captureWidth = w
            captureHeight = h
            captureFps = fps

            val helper = SurfaceTextureHelper.create("bb-cam", egl.eglBaseContext)
            surfaceTextureHelper = helper

            val source = pcFactory.createVideoSource(capturer.isScreencast)
            videoSource = source

            val proc = FaceTimeVideoProcessor(context.applicationContext, egl.eglBaseContext).apply {
                updateConfig(pendingVideoEffect, pendingVideoDenoise, pendingVirtualBgPath)
            }
            videoProcessor = proc
            source.setVideoProcessor(proc)

            capturer.initialize(helper, context.applicationContext, source.capturerObserver)
            capturer.startCapture(w, h, fps)

            val track = pcFactory.createVideoTrack("ARDAMSv0", source)
            localVideoTrack = track
            track.setEnabled(true)

            cameraEnabled = true
            hasLocalVideo = true
            track
        } catch (e: Exception) {
            PersistentLog.w(context, TAG, "Failed to initialize local camera for $callUuid; falling back to downlink-only: ${e.message}")
            disposeLocalVideoHandles(detachLocalVideoFieldsLocked())
            null
        }
    }

    fun getRemoteVideoWidth(): Int = synchronized(lock) { remoteVideoWidth }
    fun getRemoteVideoHeight(): Int = synchronized(lock) { remoteVideoHeight }
    fun getLocalVideoWidth(): Int = synchronized(lock) { localVideoWidth }
    fun getLocalVideoHeight(): Int = synchronized(lock) { localVideoHeight }

    fun getRemoteVideoTextureId(): Long? {
        val existingEntry: TextureRegistry.SurfaceTextureEntry?
        val existingRegistry: TextureRegistry?
        val existingW: Int
        val existingH: Int
        val track: VideoTrack?
        val egl: EglBase?
        synchronized(lock) {
            if (stopped) return null
            existingEntry = surfaceTextureEntry
            existingRegistry = remoteAttachedRegistry
            existingW = remoteVideoWidth
            existingH = remoteVideoHeight
            track = remoteVideoTrack
            egl = eglBase
        }
        val currentRegistry = MainActivity.getEngine()?.renderer
        if (existingEntry != null && (currentRegistry == null || existingRegistry === currentRegistry)) {
            val id = existingEntry.id()
            if (existingW > 0 && existingH > 0) {
                mainHandler.post {
                    val active = synchronized(lock) { !stopped && surfaceTextureEntry === existingEntry }
                    if (active) {
                        MethodCallHandler.invokeMethod(
                            "facetime-call-state",
                            mapOf(
                                "phase" to "video-texture",
                                "call_uuid" to callUuid,
                                "texture_id" to id,
                                "width" to existingW,
                                "height" to existingH
                            )
                        )
                    }
                }
            }
            return id
        }
        track ?: return null
        egl ?: return null
        val registry = MainActivity.getEngine()?.renderer ?: return null
        if (Looper.myLooper() == Looper.getMainLooper()) {
            return attachRemoteVideoTrackOnMain(track, egl, registry)
        }
        mainHandler.post {
            val shouldAttach = synchronized(lock) {
                !stopped && surfaceTextureEntry == null && remoteVideoTrack === track
            }
            if (shouldAttach) {
                val e = synchronized(lock) { if (stopped) null else eglBase } ?: return@post
                val r = MainActivity.getEngine()?.renderer ?: return@post
                attachRemoteVideoTrackOnMain(track, e, r)
            }
        }
        return null
    }

    fun getLocalVideoTextureId(): Long? {
        val existingEntry: TextureRegistry.SurfaceTextureEntry?
        val existingRegistry: TextureRegistry?
        val track: VideoTrack?
        val egl: EglBase?
        synchronized(lock) {
            if (stopped) return null
            existingEntry = localSurfaceTextureEntry
            existingRegistry = localAttachedRegistry
            track = localVideoTrack
            egl = eglBase
        }
        val currentRegistry = MainActivity.getEngine()?.renderer
        if (existingEntry != null && (currentRegistry == null || existingRegistry === currentRegistry)) {
            val id = existingEntry.id()
            mainHandler.post {
                val w: Int
                val h: Int
                val enabled: Boolean
                val canFlip: Boolean
                val isFront: Boolean
                synchronized(lock) {
                    if (stopped || localSurfaceTextureEntry !== existingEntry) return@post
                    w = localVideoWidth
                    h = localVideoHeight
                    enabled = cameraEnabled
                    canFlip = cameraCount >= 2
                    isFront = frontCamera
                }
                MethodCallHandler.invokeMethod(
                    "facetime-call-state",
                    buildLocalVideoTexturePayload(
                        callUuid = callUuid,
                        textureId = id,
                        width = w,
                        height = h,
                        cameraEnabled = enabled,
                        canFlipCamera = canFlip,
                        frontCamera = isFront
                    )
                )
            }
            return id
        }
        track ?: return null
        egl ?: return null
        val registry = MainActivity.getEngine()?.renderer ?: return null
        if (Looper.myLooper() == Looper.getMainLooper()) {
            return attachLocalVideoTrackOnMain(track, egl, registry)
        }
        mainHandler.post {
            val shouldAttach = synchronized(lock) {
                !stopped && localSurfaceTextureEntry == null && localVideoTrack === track
            }
            if (shouldAttach) {
                val e = synchronized(lock) { if (stopped) null else eglBase } ?: return@post
                val r = MainActivity.getEngine()?.renderer ?: return@post
                attachLocalVideoTrackOnMain(track, e, r)
            }
        }
        return null
    }

    private fun attachLocalVideoTrack(track: VideoTrack) {
        mainHandler.post {
            val egl: EglBase?
            synchronized(lock) {
                if (stopped) return@post
                if (localVideoTrack === track && localSurfaceTextureEntry != null) return@post
                localVideoTrack = track
                egl = eglBase
            }
            val activeEgl = egl ?: return@post
            val registry = MainActivity.getEngine()?.renderer ?: return@post
            attachLocalVideoTrackOnMain(track, activeEgl, registry)
        }
    }

    private fun createNonZeroSurfaceTexture(registry: TextureRegistry): TextureRegistry.SurfaceTextureEntry {
        // ActiveCallController treats texture_id <= 0 as cleared; skip id 0 if Flutter's counter starts at 0.
        val entry = registry.createSurfaceTexture()
        if (entry.id() > 0L) return entry
        releaseTextureEntry(entry)
        return registry.createSurfaceTexture()
    }

    private fun attachLocalVideoTrackOnMain(
        track: VideoTrack,
        egl: EglBase,
        registry: TextureRegistry
    ): Long? {
        val prevTrack: VideoTrack?
        val prevRenderer: SurfaceEglRenderer?
        val prevSurface: Surface?
        val prevEntry: TextureRegistry.SurfaceTextureEntry?
        synchronized(lock) {
            if (stopped) return null
            prevTrack = localVideoTrack
            prevRenderer = localSurfaceEglRenderer
            prevSurface = localVideoSurface
            prevEntry = localSurfaceTextureEntry
            localSurfaceEglRenderer = null
            localVideoSurface = null
            localSurfaceTextureEntry = null
            localVideoWidth = 0
            localVideoHeight = 0
        }
        try {
            if (prevTrack != null && prevRenderer != null) {
                prevTrack.removeSink(prevRenderer)
            }
        } catch (_: Exception) {}
        try { prevRenderer?.release() } catch (_: Exception) {}
        try { prevSurface?.release() } catch (_: Exception) {}
        releaseTextureEntry(prevEntry)

        val entry = createNonZeroSurfaceTexture(registry)
        val surfaceTexture = entry.surfaceTexture()
        val surface = Surface(surfaceTexture)
        val renderer = SurfaceEglRenderer("WebRtcLocalVideo-$callUuid")
        try {
            renderer.init(egl.eglBaseContext, object : RendererCommon.RendererEvents {
                override fun onFirstFrameRendered() {}
                override fun onFrameResolutionChanged(videoWidth: Int, videoHeight: Int, rotation: Int) {
                    if (videoWidth > 0 && videoHeight > 0) {
                        val (effectiveWidth, effectiveHeight) = rotatedFrameSize(videoWidth, videoHeight, rotation)
                        mainHandler.post {
                            val enabled: Boolean
                            val canFlip: Boolean
                            val isFront: Boolean
                            synchronized(lock) {
                                if (stopped || localSurfaceTextureEntry !== entry) return@post
                                localVideoWidth = effectiveWidth
                                localVideoHeight = effectiveHeight
                                enabled = cameraEnabled
                                canFlip = cameraCount >= 2
                                isFront = frontCamera
                            }
                            surfaceTexture.setDefaultBufferSize(effectiveWidth, effectiveHeight)
                            MethodCallHandler.invokeMethod(
                                "facetime-call-state",
                                buildLocalVideoTexturePayload(
                                    callUuid = callUuid,
                                    textureId = entry.id(),
                                    width = effectiveWidth,
                                    height = effectiveHeight,
                                    cameraEnabled = enabled,
                                    canFlipCamera = canFlip,
                                    frontCamera = isFront
                                )
                            )
                        }
                    }
                }
            }, EglBase.CONFIG_PLAIN, GlRectDrawer())
            renderer.createEglSurface(surface)
            track.addSink(renderer)
        } catch (e: Exception) {
            PersistentLog.w(context, TAG, "attachLocalVideoTrackOnMain failed for $callUuid: ${e.message}")
            try { renderer.release() } catch (_: Exception) {}
            try { surface.release() } catch (_: Exception) {}
            releaseTextureEntry(entry)
            return null
        }

        val enabled: Boolean
        val canFlip: Boolean
        val isFront: Boolean
        val committed = synchronized(lock) {
            if (stopped || localVideoTrack !== track) {
                enabled = false
                canFlip = false
                isFront = true
                false
            } else {
                localSurfaceTextureEntry = entry
                localAttachedRegistry = registry
                localVideoSurface = surface
                localSurfaceEglRenderer = renderer
                enabled = cameraEnabled
                canFlip = cameraCount >= 2
                isFront = frontCamera
                true
            }
        }
        if (!committed) {
            try { track.removeSink(renderer) } catch (_: Exception) {}
            try { renderer.release() } catch (_: Exception) {}
            try { surface.release() } catch (_: Exception) {}
            releaseTextureEntry(entry)
            return null
        }

        val textureId = entry.id()
        onLocalVideoTexture(textureId)
        MethodCallHandler.invokeMethod(
            "facetime-call-state",
            buildLocalVideoTexturePayload(
                callUuid = callUuid,
                textureId = textureId,
                width = 0,
                height = 0,
                cameraEnabled = enabled,
                canFlipCamera = canFlip,
                frontCamera = isFront
            )
        )
        return textureId
    }

    private fun attachRemoteVideoTrack(track: VideoTrack) {
        mainHandler.post {
            val prevTrack: VideoTrack?
            val prevRenderer: SurfaceEglRenderer?
            val prevSurface: Surface?
            val prevEntry: TextureRegistry.SurfaceTextureEntry?
            val egl: EglBase?
            synchronized(lock) {
                if (stopped) return@post
                if (remoteVideoTrack === track && surfaceTextureEntry != null) return@post
                if (remoteVideoTrack !== track) {
                    prevTrack = remoteVideoTrack
                    prevRenderer = surfaceEglRenderer
                    prevSurface = videoSurface
                    prevEntry = surfaceTextureEntry
                    surfaceEglRenderer = null
                    videoSurface = null
                    surfaceTextureEntry = null
                    remoteVideoWidth = 0
                    remoteVideoHeight = 0
                } else {
                    prevTrack = null
                    prevRenderer = null
                    prevSurface = null
                    prevEntry = null
                }
                remoteVideoTrack = track
                egl = eglBase
            }
            try {
                if (prevTrack != null && prevRenderer != null) {
                    prevTrack.removeSink(prevRenderer)
                }
            } catch (_: Exception) {}
            try { prevRenderer?.release() } catch (_: Exception) {}
            try { prevSurface?.release() } catch (_: Exception) {}
            releaseTextureEntry(prevEntry)
            try { track.setEnabled(true) } catch (_: IllegalStateException) {}

            val activeEgl = egl ?: return@post
            val registry = MainActivity.getEngine()?.renderer ?: return@post
            attachRemoteVideoTrackOnMain(track, activeEgl, registry)
        }
    }

    private fun attachRemoteVideoTrackOnMain(
        track: VideoTrack,
        egl: EglBase,
        registry: TextureRegistry
    ): Long? {
        val prevTrack: VideoTrack?
        val prevRenderer: SurfaceEglRenderer?
        val prevSurface: Surface?
        val prevEntry: TextureRegistry.SurfaceTextureEntry?
        synchronized(lock) {
            if (stopped) return null
            prevTrack = remoteVideoTrack
            prevRenderer = surfaceEglRenderer
            prevSurface = videoSurface
            prevEntry = surfaceTextureEntry
            surfaceEglRenderer = null
            videoSurface = null
            surfaceTextureEntry = null
            remoteVideoWidth = 0
            remoteVideoHeight = 0
        }
        try {
            if (prevTrack != null && prevRenderer != null) {
                prevTrack.removeSink(prevRenderer)
            }
        } catch (_: Exception) {}
        try { prevRenderer?.release() } catch (_: Exception) {}
        try { prevSurface?.release() } catch (_: Exception) {}
        releaseTextureEntry(prevEntry)

        val entry = createNonZeroSurfaceTexture(registry)
        val surfaceTexture = entry.surfaceTexture()
        val surface = Surface(surfaceTexture)
        val renderer = SurfaceEglRenderer("WebRtcRemoteVideo-$callUuid")
        try {
            renderer.init(egl.eglBaseContext, object : RendererCommon.RendererEvents {
                override fun onFirstFrameRendered() {}
                override fun onFrameResolutionChanged(videoWidth: Int, videoHeight: Int, rotation: Int) {
                    if (videoWidth > 0 && videoHeight > 0) {
                        val (effectiveWidth, effectiveHeight) = rotatedFrameSize(videoWidth, videoHeight, rotation)
                        mainHandler.post {
                            val active = synchronized(lock) {
                                if (stopped || surfaceTextureEntry !== entry) return@synchronized false
                                remoteVideoWidth = effectiveWidth
                                remoteVideoHeight = effectiveHeight
                                true
                            }
                            if (!active) return@post
                            surfaceTexture.setDefaultBufferSize(effectiveWidth, effectiveHeight)
                            MethodCallHandler.invokeMethod(
                                "facetime-call-state",
                                mapOf(
                                    "phase" to "video-texture",
                                    "call_uuid" to callUuid,
                                    "texture_id" to entry.id(),
                                    "width" to effectiveWidth,
                                    "height" to effectiveHeight
                                )
                            )
                        }
                    }
                }
            }, EglBase.CONFIG_PLAIN, GlRectDrawer())
            renderer.createEglSurface(surface)
            try { track.setEnabled(true) } catch (_: IllegalStateException) {}
            track.addSink(renderer)
        } catch (e: Exception) {
            PersistentLog.w(context, TAG, "attachRemoteVideoTrackOnMain failed for $callUuid: ${e.message}")
            try { renderer.release() } catch (_: Exception) {}
            try { surface.release() } catch (_: Exception) {}
            releaseTextureEntry(entry)
            return null
        }

        val committed = synchronized(lock) {
            if (stopped || remoteVideoTrack !== track) {
                false
            } else {
                surfaceTextureEntry = entry
                remoteAttachedRegistry = registry
                videoSurface = surface
                surfaceEglRenderer = renderer
                true
            }
        }
        if (!committed) {
            try { track.removeSink(renderer) } catch (_: Exception) {}
            try { renderer.release() } catch (_: Exception) {}
            try { surface.release() } catch (_: Exception) {}
            releaseTextureEntry(entry)
            return null
        }

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
        return textureId
    }

    private fun detachLocalVideoFieldsLocked(): LocalVideoHandles {
        val handles = LocalVideoHandles(
            track = localVideoTrack,
            renderer = localSurfaceEglRenderer,
            surface = localVideoSurface,
            entry = localSurfaceTextureEntry,
            capturer = videoCapturer,
            helper = surfaceTextureHelper,
            source = videoSource,
            proc = videoProcessor
        )
        localVideoTrack = null
        localSurfaceEglRenderer = null
        localVideoSurface = null
        localSurfaceTextureEntry = null
        localVideoWidth = 0
        localVideoHeight = 0
        videoCapturer = null
        surfaceTextureHelper = null
        videoSource = null
        videoProcessor = null
        hasLocalVideo = false
        cameraEnabled = false
        cameraCount = 0
        return handles
    }

    private fun disposeLocalVideoHandles(h: LocalVideoHandles) {
        if (h.track != null || h.renderer != null || h.surface != null || h.entry != null ||
            h.capturer != null || h.helper != null || h.source != null || h.proc != null
        ) {
            onLocalVideoTexture(null)
            try {
                if (h.track != null && h.renderer != null) {
                    h.track.removeSink(h.renderer)
                }
            } catch (_: Exception) {}
            try {
                h.track?.setEnabled(false)
                h.track?.dispose()
            } catch (_: Exception) {}
            val capturer = h.capturer
            if (capturer != null) {
                cameraExecutor.execute {
                    try {
                        capturer.stopCapture()
                    } catch (_: Exception) {}
                    try {
                        capturer.dispose()
                    } catch (_: Exception) {}
                }
            }
            try {
                h.renderer?.release()
            } catch (_: Exception) {}
            try {
                h.surface?.release()
            } catch (_: Exception) {}
            releaseTextureEntry(h.entry)
            try {
                h.helper?.dispose()
            } catch (_: Exception) {}
            try {
                h.source?.setVideoProcessor(null)
            } catch (_: Exception) {}
            try {
                h.proc?.release()
            } catch (_: Exception) {}
            try {
                h.source?.dispose()
            } catch (_: Exception) {}
        }
    }

    private fun detachRemoteVideoFieldsLocked(): RemoteVideoHandles {
        val handles = RemoteVideoHandles(
            track = remoteVideoTrack,
            renderer = surfaceEglRenderer,
            surface = videoSurface,
            entry = surfaceTextureEntry,
            egl = eglBase
        )
        remoteVideoTrack = null
        surfaceEglRenderer = null
        videoSurface = null
        surfaceTextureEntry = null
        remoteVideoWidth = 0
        remoteVideoHeight = 0
        eglBase = null
        return handles
    }

    private fun disposeRemoteVideoHandles(h: RemoteVideoHandles) {
        if (h.track != null || h.renderer != null || h.surface != null || h.entry != null) {
            onRemoteVideoTexture(null)
            try {
                if (h.track != null && h.renderer != null) {
                    h.track.removeSink(h.renderer)
                }
            } catch (_: Exception) {}
            try {
                h.renderer?.release()
            } catch (_: Exception) {}
            try {
                h.surface?.release()
            } catch (_: Exception) {}
            releaseTextureEntry(h.entry)
        }
    }

    private fun createAndSendOffer(pc: PeerConnection) {
        val constraints = MediaConstraints().apply {
            mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveAudio", "true"))
            mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveVideo", if (wantVideo) "true" else "false"))
        }
        pc.createOffer(object : SdpObserver {
            override fun onCreateSuccess(desc: SessionDescription?) {
                if (desc == null || stopped) return
                PersistentLog.d(
                    context,
                    Constants.logTag,
                    "[$TAG] Offer SDP ($callUuid): wantVideo=$wantVideo hasH264=${sdpContainsH264(desc.description)}"
                )
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
                        stopAsync(sendHangup = false)
                    }

                    override fun onCreateSuccess(p0: SessionDescription?) {}
                    override fun onCreateFailure(p0: String?) {}
                }, desc)
            }

            override fun onCreateFailure(error: String?) {
                PersistentLog.e(context, TAG, "createOffer failed: $error")
                onError(error ?: "createOffer failed")
                stopAsync(sendHangup = false)
            }

            override fun onSetSuccess() {}
            override fun onSetFailure(error: String?) {}
        }, constraints)
    }

    private fun handleRemoteAnswer(sdp: String) {
        val answer = SessionDescription(SessionDescription.Type.ANSWER, sdp)
        val observer = object : SdpObserver {
            override fun onSetSuccess() {
                val activePc: PeerConnection
                val queued: List<IceCandidate>
                synchronized(lock) {
                    if (stopped) return
                    activePc = peerConnection ?: return
                    remoteDescriptionSet = true
                    queued = pendingRemoteIce.toList()
                    pendingRemoteIce.clear()
                }
                try {
                    queued.forEach { activePc.addIceCandidate(it) }
                } catch (_: Exception) {}
            }

            override fun onSetFailure(error: String?) {
                PersistentLog.e(context, TAG, "setRemoteDescription failed: $error")
                onError(error ?: "setRemoteDescription failed")
                stopAsync(sendHangup = false)
            }

            override fun onCreateSuccess(p0: SessionDescription?) {}
            override fun onCreateFailure(p0: String?) {}
        }
        val activePc = synchronized(lock) {
            if (stopped) return
            peerConnection
        }
        try {
            activePc?.setRemoteDescription(observer, answer)
        } catch (_: Exception) {}
    }

    private fun handleRemoteIce(candidate: IceCandidate) {
        PersistentLog.d(
            context,
            Constants.logTag,
            "[$TAG] Remote ICE ($callUuid): ${summarizeIceCandidate(candidate.sdp)} mid=${candidate.sdpMid}"
        )
        val activePc = synchronized(lock) {
            if (stopped) return
            val pc = peerConnection
            if (!remoteDescriptionSet || pc == null) {
                pendingRemoteIce.add(candidate)
                return
            }
            pc
        }
        try {
            activePc.addIceCandidate(candidate)
        } catch (_: Exception) {}
    }

    private fun emitEvent(event: String, payload: JSONObject) {
        val activeSock = synchronized(socketLock) {
            if (stopped) return
            val s = socket
            if (s != null && s.connected()) {
                s
            } else {
                pendingOutboundEvents.add(event to payload)
                null
            }
        }
        activeSock?.emit(event, payload)
    }

    private fun flushPendingOutbound() {
        val toFlush: List<Pair<String, JSONObject>>
        val activeSock: Socket
        synchronized(socketLock) {
            val s = socket
            if (stopped || s == null || !s.connected()) return
            activeSock = s
            toFlush = pendingOutboundEvents.toList()
            pendingOutboundEvents.clear()
        }
        toFlush.forEach { (event, payload) -> activeSock.emit(event, payload) }
    }
}

private class MediaCodecH264FallbackEncoder(
    private val codecName: String,
    private val colorFormat: Int
) : VideoEncoder {
    private data class PendingFrameMeta(
        val width: Int,
        val height: Int,
        val captureTimeNs: Long,
        val rotation: Int
    )

    private var callback: VideoEncoder.Callback? = null
    private var codec: MediaCodec? = null
    private var width = 0
    private var height = 0
    private var bitrateBps = 500_000
    private var fps = 30
    private var nextPtsUs = 0L
    private var configBytes: ByteArray? = null
    private val pendingMeta = ArrayDeque<PendingFrameMeta>()

    override fun initEncode(settings: VideoEncoder.Settings, encodeCallback: VideoEncoder.Callback): VideoCodecStatus {
        callback = encodeCallback
        bitrateBps = (settings.startBitrate.coerceAtLeast(300)) * 1000
        fps = settings.maxFramerate.coerceIn(1, 30)
        return configureCodec(settings.width, settings.height)
    }

    private fun configureCodec(w: Int, h: Int): VideoCodecStatus {
        releaseCodecOnly()
        return try {
            val c = MediaCodec.createByCodecName(codecName)
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, w, h).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT, colorFormat)
                setInteger(MediaFormat.KEY_BIT_RATE, bitrateBps)
                setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
                setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
            }
            c.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            c.start()
            codec = c
            width = w
            height = h
            configBytes = null
            VideoCodecStatus.OK
        } catch (_: Exception) {
            releaseCodecOnly()
            VideoCodecStatus.ERROR
        }
    }

    override fun release(): VideoCodecStatus {
        releaseCodecOnly()
        callback = null
        return VideoCodecStatus.OK
    }

    private fun releaseCodecOnly() {
        pendingMeta.clear()
        configBytes = null
        try { codec?.stop() } catch (_: Exception) {}
        try { codec?.release() } catch (_: Exception) {}
        codec = null
    }

    override fun encode(frame: VideoFrame, encodeInfo: VideoEncoder.EncodeInfo): VideoCodecStatus {
        val w = frame.buffer.width
        val h = frame.buffer.height
        if (w <= 0 || h <= 0) return VideoCodecStatus.ERR_PARAMETER
        if (codec == null || w != width || h != height) {
            val status = configureCodec(w, h)
            if (status != VideoCodecStatus.OK) return status
        }
        val activeCodec = codec ?: return VideoCodecStatus.UNINITIALIZED

        if (encodeInfo.frameTypes?.any { it == EncodedImage.FrameType.VideoFrameKey } == true) {
            try {
                activeCodec.setParameters(Bundle().apply {
                    putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                })
            } catch (_: Exception) {}
        }

        var inIdx = activeCodec.dequeueInputBuffer(10_000L)
        if (inIdx < 0) {
            drainOutput(activeCodec, w, h, frame.timestampNs, frame.rotation)
            inIdx = activeCodec.dequeueInputBuffer(5_000L)
        }
        if (inIdx < 0) return VideoCodecStatus.OK

        val inputBuf = activeCodec.getInputBuffer(inIdx) ?: return VideoCodecStatus.ERROR
        val inFormat = try { activeCodec.inputFormat } catch (_: Exception) { null }
        val dstStride = inFormat?.takeIf { it.containsKey(MediaFormat.KEY_STRIDE) }
            ?.getInteger(MediaFormat.KEY_STRIDE)?.coerceAtLeast(w) ?: w
        val dstSliceHeight = inFormat?.takeIf { it.containsKey(MediaFormat.KEY_SLICE_HEIGHT) }
            ?.getInteger(MediaFormat.KEY_SLICE_HEIGHT)?.coerceAtLeast(h) ?: h
        val uvH = (h + 1) / 2
        val requiredBytes = if (colorFormat == MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar) {
            dstStride * dstSliceHeight + dstStride * uvH
        } else {
            val uvStride = (dstStride + 1) / 2
            val uvSlice = (dstSliceHeight + 1) / 2
            dstStride * dstSliceHeight + 2 * uvStride * uvSlice
        }
        inputBuf.clear()
        if (inputBuf.remaining() < requiredBytes) return VideoCodecStatus.ERR_SIZE

        val i420 = frame.buffer.toI420() ?: return VideoCodecStatus.ERROR
        try {
            val yPlane = inputBuf.duplicate().apply { position(0) }
            val uOffset = dstStride * dstSliceHeight
            if (colorFormat == MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar) {
                val uvPlane = inputBuf.duplicate().apply { position(uOffset) }
                YuvHelper.I420ToNV12(
                    i420.dataY, i420.strideY,
                    i420.dataU, i420.strideU,
                    i420.dataV, i420.strideV,
                    yPlane, dstStride,
                    uvPlane, dstStride,
                    w, h
                )
            } else {
                val uvStride = (dstStride + 1) / 2
                val uvSlice = (dstSliceHeight + 1) / 2
                val uPlane = inputBuf.duplicate().apply { position(uOffset) }
                val vPlane = inputBuf.duplicate().apply { position(uOffset + uvStride * uvSlice) }
                YuvHelper.I420Copy(
                    i420.dataY, i420.strideY,
                    i420.dataU, i420.strideU,
                    i420.dataV, i420.strideV,
                    yPlane, dstStride,
                    uPlane, uvStride,
                    vPlane, uvStride,
                    w, h
                )
            }
        } finally {
            i420.release()
        }

        val ptsUs = nextPtsUs
        nextPtsUs += (1_000_000L / fps.coerceAtLeast(1))
        pendingMeta.addLast(PendingFrameMeta(w, h, frame.timestampNs, frame.rotation))
        activeCodec.queueInputBuffer(inIdx, 0, requiredBytes, ptsUs, 0)
        drainOutput(activeCodec, w, h, frame.timestampNs, frame.rotation)
        return VideoCodecStatus.OK
    }

    private fun drainOutput(
        activeCodec: MediaCodec,
        fallbackW: Int,
        fallbackH: Int,
        fallbackTsNs: Long,
        fallbackRotation: Int
    ) {
        val cb = callback ?: return
        val info = MediaCodec.BufferInfo()
        while (true) {
            val outIdx = activeCodec.dequeueOutputBuffer(info, 0L)
            if (outIdx == MediaCodec.INFO_TRY_AGAIN_LATER) break
            if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) continue
            if (outIdx < 0) break

            try {
                val outBuf = activeCodec.getOutputBuffer(outIdx) ?: continue
                if (info.size <= 0) continue
                outBuf.position(info.offset)
                outBuf.limit(info.offset + info.size)
                val raw = ByteArray(info.size)
                outBuf.get(raw)

                if ((info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                    configBytes = raw
                    continue
                }

                val meta = pendingMeta.removeFirstOrNull()
                    ?: PendingFrameMeta(fallbackW, fallbackH, fallbackTsNs, fallbackRotation)
                val isKey = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                val payload = WebRtcAudioClient.prependH264ConfigIfMissing(raw, configBytes, isKey)
                val direct = ByteBuffer.allocateDirect(payload.size).apply {
                    put(payload)
                    rewind()
                }
                val encoded = EncodedImage.builder()
                    .setBuffer(direct, null)
                    .setEncodedWidth(meta.width)
                    .setEncodedHeight(meta.height)
                    .setCaptureTimeNs(meta.captureTimeNs)
                    .setFrameType(
                        if (isKey) EncodedImage.FrameType.VideoFrameKey
                        else EncodedImage.FrameType.VideoFrameDelta
                    )
                    .setRotation(meta.rotation)
                    .createEncodedImage()
                cb.onEncodedFrame(encoded, VideoEncoder.CodecSpecificInfoH264())
            } finally {
                activeCodec.releaseOutputBuffer(outIdx, false)
            }
        }
    }

    override fun setRateAllocation(bitrateAllocation: VideoEncoder.BitrateAllocation, framerate: Int): VideoCodecStatus {
        val sumBps = bitrateAllocation.sum
        if (sumBps > 0) bitrateBps = sumBps
        if (framerate > 0) fps = framerate.coerceIn(1, 30)
        val activeCodec = codec ?: return VideoCodecStatus.OK
        try {
            activeCodec.setParameters(Bundle().apply {
                putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, bitrateBps)
            })
        } catch (_: Exception) {}
        return VideoCodecStatus.OK
    }

    override fun setRates(rcParameters: VideoEncoder.RateControlParameters): VideoCodecStatus =
        setRateAllocation(rcParameters.bitrate, rcParameters.framerateFps.toInt())

    override fun getScalingSettings(): VideoEncoder.ScalingSettings =
        VideoEncoder.ScalingSettings(24, 37)

    override fun getImplementationName(): String = "BlueBubblesMediaCodecH264"
}
