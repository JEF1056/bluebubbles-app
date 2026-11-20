package com.bluebubbles.messaging.services.telecom

import android.content.Context
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.telecom.CallAudioState
import android.telecom.Connection
import android.telecom.DisconnectCause
import com.bluebubbles.messaging.services.network.HttpService
import com.bluebubbles.messaging.utils.PersistentLog
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class FaceTimeConnection(
    private val context: Context,
    @Volatile var callUuid: String?
) : Connection() {

    companion object {
        private const val TAG = "FaceTimeConnection"
        private const val RINGING_TIMEOUT_MS = 60_000L
        private val audioExecutor = Executors.newSingleThreadExecutor()
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

    fun bindCallUuid(uuid: String) {
        callUuid = uuid
        FaceTimeConnectionService.registerActiveConnection(uuid, this)
    }

    fun scheduleRingingTimeout() {
        mainHandler.removeCallbacks(ringingTimeoutRunnable)
        mainHandler.postDelayed(ringingTimeoutRunnable, RINGING_TIMEOUT_MS)
    }

    fun startAudioBridge(answerCall: Boolean) {
        val uuid = callUuid ?: return
        if (ended.get() || webRtcClient != null) return

        val client = WebRtcAudioClient(
            context = context,
            callUuid = uuid,
            answerCall = answerCall,
            onRemoteHangup = { onRemoteDisconnect() },
            onError = { err ->
                PersistentLog.e(context, TAG, "Audio bridge error for $uuid: $err")
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

    override fun onCallAudioStateChanged(state: CallAudioState?) {
        if (state == null || ended.get()) return
        if (lastMuted != state.isMuted) {
            lastMuted = state.isMuted
            webRtcClient?.setMuted(state.isMuted)
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
    }
}
