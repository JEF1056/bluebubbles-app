package com.bluebubbles.messaging.services.telecom

import android.content.Context
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.telecom.CallAudioState
import android.telecom.Connection
import android.telecom.DisconnectCause
import com.bluebubbles.messaging.services.network.HttpService
import com.bluebubbles.messaging.services.notifications.CreateIncomingFaceTimeNotification
import com.bluebubbles.messaging.utils.PersistentLog
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class FaceTimeConnection(
    private val context: Context,
    @Volatile var callUuid: String?,
    val isTelephony: Boolean = false,
    val isVideo: Boolean = false
) : Connection() {

    companion object {
        private const val TAG = "FaceTimeConnection"
        private const val RINGING_TIMEOUT_MS = CreateIncomingFaceTimeNotification.INCOMING_CALL_TIMEOUT_MS
        private val DTMF_DIGIT_REGEX = Regex("^[0-9*#ABCD]$")
        private val audioExecutor = Executors.newSingleThreadExecutor()

        internal fun normalizeDtmfDigit(c: Char): String? {
            val digit = c.uppercaseChar().toString()
            return digit.takeIf { DTMF_DIGIT_REGEX.matches(it) }
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val ringingTimeoutRunnable = Runnable {
        if (!ended.get() && state == STATE_RINGING) {
            PersistentLog.w(context, TAG, "Ringing timeout for $callUuid")
            onRemoteDisconnect()
        }
    }

    private val ended = AtomicBoolean(false)
    val isEnded: Boolean
        get() = ended.get()

    @Volatile
    private var webRtcClient: WebRtcAudioClient? = null

    @Volatile
    private var lastMuted: Boolean? = null

    @Volatile
    private var remoteVideoTextureId: Long? = null

    @Volatile
    private var localVideoTextureId: Long? = null

    fun getRemoteVideoTextureId(): Long? = webRtcClient?.getRemoteVideoTextureId() ?: remoteVideoTextureId

    fun getLocalVideoTextureId(): Long? = webRtcClient?.getLocalVideoTextureId() ?: localVideoTextureId

    fun bindCallUuid(uuid: String) {
        callUuid = uuid
        FaceTimeConnectionService.registerActiveConnection(uuid, this)
        if (!ended.get() && state == STATE_DIALING) {
            emitCallState("dialing", uuid)
        }
    }

    fun onRemoteAnswered() {
        if (ended.get() || state != STATE_DIALING) return
        PersistentLog.d(context, TAG, "onRemoteAnswered for $callUuid")
        setActive()
        startAudioBridge(answerCall = false)
        callUuid?.let { emitCallState("active", it) }
    }

    fun setMutedFromUi(muted: Boolean) {
        if (ended.get()) return
        lastMuted = muted
        webRtcClient?.setMuted(muted)
    }

    fun setCameraEnabled(enabled: Boolean): Boolean {
        if (ended.get()) return false
        return webRtcClient?.setCameraEnabled(enabled) ?: false
    }

    fun flipCamera(): Boolean {
        if (ended.get()) return false
        return webRtcClient?.flipCamera() ?: false
    }

    fun setSpeakerphone(enabled: Boolean): Boolean {
        if (ended.get()) return false
        @Suppress("DEPRECATION")
        val route = if (enabled) {
            CallAudioState.ROUTE_SPEAKER
        } else if (((callAudioState?.supportedRouteMask ?: 0) and CallAudioState.ROUTE_BLUETOOTH) != 0) {
            CallAudioState.ROUTE_BLUETOOTH
        } else {
            CallAudioState.ROUTE_WIRED_OR_EARPIECE
        }
        @Suppress("DEPRECATION")
        try {
            setAudioRoute(route)
        } catch (_: Exception) {}
        @Suppress("DEPRECATION")
        return try {
            val audioManager = context.getSystemService(AudioManager::class.java)
            audioManager?.isSpeakerphoneOn = enabled
            true
        } catch (_: Exception) {
            false
        }
    }

    fun isSpeakerphoneOn(): Boolean {
        if (callAudioState?.route == CallAudioState.ROUTE_SPEAKER) return true
        @Suppress("DEPRECATION")
        return try {
            context.getSystemService(AudioManager::class.java)?.isSpeakerphoneOn == true
        } catch (_: Exception) {
            false
        }
    }

    private fun emitCallState(phase: String, uuid: String, muted: Boolean? = null) {
        val payload = HashMap<String, Any>(4).apply {
            put("phase", phase)
            put("call_uuid", uuid)
            put("is_telephony", isTelephony)
            if (muted != null) put("muted", muted)
        }
        com.bluebubbles.messaging.services.backend_ui_interop.MethodCallHandler.invokeMethod(
            "facetime-call-state",
            payload
        )
    }

    fun scheduleRingingTimeout() {
        mainHandler.removeCallbacks(ringingTimeoutRunnable)
        mainHandler.postDelayed(ringingTimeoutRunnable, RINGING_TIMEOUT_MS)
    }

    fun startAudioBridge(answerCall: Boolean, wantVideo: Boolean = isVideo) {
        val uuid = callUuid ?: return
        if (ended.get() || webRtcClient != null) return

        val client = WebRtcAudioClient(
            context = context,
            callUuid = uuid,
            answerCall = answerCall,
            wantVideo = wantVideo,
            onRemoteHangup = { onRemoteDisconnect() },
            onError = { err ->
                PersistentLog.e(context, TAG, "Audio bridge error for $uuid: $err")
            },
            onRemoteVideoTexture = { textureId ->
                remoteVideoTextureId = textureId
            },
            onLocalVideoTexture = { textureId ->
                localVideoTextureId = textureId
            }
        )
        webRtcClient = client
        audioExecutor.execute {
            if (!ended.get() && webRtcClient === client) {
                client.start()
            }
        }
    }

    fun answerFromHandoff() = onAnswer()

    override fun onAnswer() {
        if (ended.get()) return
        mainHandler.removeCallbacks(ringingTimeoutRunnable)
        PersistentLog.d(context, TAG, "onAnswer for $callUuid")
        setActive()
        startAudioBridge(answerCall = true)
        callUuid?.let {
            emitCallState("active", it)
            com.bluebubbles.messaging.services.wear.WearSyncManager.notifyCallEndedIfNotWatchAnswered(context, it)
        }
    }

    override fun onReject() {
        PersistentLog.d(context, TAG, "onReject for $callUuid")
        finishCall(DisconnectCause(DisconnectCause.REJECTED)) { uuid, done ->
            HttpService(context).declineFaceTimeCall(
                callUuid = uuid,
                onSuccess = { done() },
                onError = { err ->
                    PersistentLog.w(context, TAG, "declineFaceTimeCall failed for $uuid: $err")
                    done()
                }
            )
        }
    }

    override fun onDisconnect() {
        endLocalCall(DisconnectCause.LOCAL)
    }

    override fun onAbort() {
        endLocalCall(DisconnectCause.CANCELED)
    }

    override fun onHold() {
        setOnHold()
        webRtcClient?.setMuted(true)
    }

    override fun onUnhold() {
        setActive()
        val isMuted = callAudioState?.isMuted ?: false
        webRtcClient?.setMuted(isMuted)
    }

    override fun onPlayDtmfTone(c: Char) {
        val uuid = callUuid ?: return
        if (ended.get()) return
        val digit = normalizeDtmfDigit(c) ?: return
        PersistentLog.d(context, TAG, "onPlayDtmfTone($digit) for $uuid (telephony=$isTelephony)")
        HttpService(context).sendFaceTimeDtmf(
            callUuid = uuid,
            digit = digit,
            onError = { err ->
                PersistentLog.w(context, TAG, "sendFaceTimeDtmf failed for $uuid: $err")
            }
        )
    }

    override fun onStopDtmfTone() {
        // Server plays discrete DTMF tones on onPlayDtmfTone.
    }

    override fun onCallAudioStateChanged(state: CallAudioState?) {
        if (state == null || ended.get()) return
        if (lastMuted != state.isMuted) {
            lastMuted = state.isMuted
            webRtcClient?.setMuted(state.isMuted)
            callUuid?.let { emitCallState("mute", it, muted = state.isMuted) }
        }
        @Suppress("DEPRECATION")
        try {
            val audioManager = context.getSystemService(AudioManager::class.java)
            audioManager?.isSpeakerphoneOn = (state.route == CallAudioState.ROUTE_SPEAKER)
        } catch (_: Exception) {}
    }

    fun onRemoteDisconnect() {
        PersistentLog.d(context, TAG, "onRemoteDisconnect for $callUuid")
        finishCall(DisconnectCause(DisconnectCause.REMOTE))
    }

    fun failOutgoing(reason: String) {
        finishCall(DisconnectCause(DisconnectCause.ERROR, reason))
    }

    private fun endLocalCall(causeCode: Int) {
        PersistentLog.d(context, TAG, "endLocalCall($causeCode) for $callUuid")
        finishCall(DisconnectCause(causeCode), sendHangup = true) { uuid, done ->
            HttpService(context).leaveFaceTimeCall(
                callUuid = uuid,
                onSuccess = { done() },
                onError = { err ->
                    PersistentLog.w(context, TAG, "leaveFaceTimeCall failed for $uuid: $err")
                    done()
                }
            )
        }
    }

    private fun finishCall(
        cause: DisconnectCause,
        sendHangup: Boolean = false,
        onUuid: ((String, () -> Unit) -> Unit)? = null
    ) {
        if (!ended.compareAndSet(false, true)) return
        val uuid = callUuid
        cleanupAudio(sendHangup = sendHangup)
        if (!uuid.isNullOrBlank()) {
            FaceTimeConnectionService.unregisterActiveConnection(uuid, this)
            CreateIncomingFaceTimeNotification.cancelIncomingCallNotification(context, uuid)
            emitCallState("ended", uuid)
            com.bluebubbles.messaging.services.wear.WearSyncManager.notifyCallEnded(context, uuid)
        }
        setDisconnected(cause)
        if (onUuid != null && !uuid.isNullOrBlank()) {
            // Keep ConnectionService bound briefly until leave/decline HTTP completes or times out.
            var destroyed = false
            val destroyOnce: () -> Unit = {
                mainHandler.post {
                    if (!destroyed) {
                        destroyed = true
                        destroy()
                    }
                }
            }
            mainHandler.postDelayed({
                if (!destroyed) {
                    PersistentLog.w(context, TAG, "Timed out waiting for FaceTime end HTTP for $uuid; destroying connection")
                    destroyOnce()
                }
            }, 3_000L)
            onUuid(uuid, destroyOnce)
        } else {
            destroy()
        }
    }

    private fun cleanupAudio(sendHangup: Boolean) {
        mainHandler.removeCallbacks(ringingTimeoutRunnable)
        webRtcClient?.stop(sendHangup = sendHangup)
        webRtcClient = null
        remoteVideoTextureId = null
        localVideoTextureId = null
    }
}
