package com.bluebubbles.messaging.services.telecom

import android.content.Context
import android.media.AudioManager
import android.telecom.CallAudioState
import android.telecom.Connection
import android.telecom.DisconnectCause
import com.bluebubbles.messaging.services.network.HttpService
import com.bluebubbles.messaging.utils.PersistentLog

class FaceTimeConnection(
    private val context: Context,
    @Volatile var callUuid: String?,
    private val isIncoming: Boolean
) : Connection() {

    companion object {
        private const val TAG = "FaceTimeConnection"
    }

    @Volatile
    private var ended = false

    @Volatile
    private var webRtcClient: WebRtcAudioClient? = null

    @Volatile
    private var lastMuted: Boolean? = null

    fun bindCallUuid(uuid: String) {
        callUuid = uuid
        FaceTimeConnectionService.registerActiveConnection(uuid, this)
    }

    fun startAudioBridge(answerCall: Boolean) {
        val uuid = callUuid ?: return
        if (ended || webRtcClient != null) return

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
        client.start()
    }

    fun answerFromHandoff() {
        if (ended) return
        setActive()
        startAudioBridge(answerCall = true)
    }

    override fun onAnswer() {
        if (ended) return
        PersistentLog.d(context, TAG, "onAnswer for $callUuid")
        setActive()
        startAudioBridge(answerCall = true)
    }

    override fun onReject() {
        if (ended) return
        ended = true
        val uuid = callUuid
        PersistentLog.d(context, TAG, "onReject for $uuid")

        cleanupAudio(sendHangup = false)
        if (!uuid.isNullOrBlank()) {
            FaceTimeConnectionService.unregisterActiveConnection(uuid, this)
            HttpService(context).declineFaceTimeCall(uuid)
        }
        setDisconnected(DisconnectCause(DisconnectCause.REJECTED))
        destroy()
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
        if (state == null || ended) return
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
        if (ended) return
        ended = true
        val uuid = callUuid
        PersistentLog.d(context, TAG, "onRemoteDisconnect for $uuid")

        cleanupAudio(sendHangup = false)
        if (!uuid.isNullOrBlank()) {
            FaceTimeConnectionService.unregisterActiveConnection(uuid, this)
        }
        setDisconnected(DisconnectCause(DisconnectCause.REMOTE))
        destroy()
    }

    fun failOutgoing(reason: String) {
        if (ended) return
        ended = true
        val uuid = callUuid
        cleanupAudio(sendHangup = false)
        if (!uuid.isNullOrBlank()) {
            FaceTimeConnectionService.unregisterActiveConnection(uuid, this)
        }
        setDisconnected(DisconnectCause(DisconnectCause.ERROR, reason))
        destroy()
    }

    private fun endLocalCall(causeCode: Int) {
        if (ended) return
        ended = true
        val uuid = callUuid
        PersistentLog.d(context, TAG, "endLocalCall($causeCode) for $uuid")

        cleanupAudio(sendHangup = true)
        if (!uuid.isNullOrBlank()) {
            FaceTimeConnectionService.unregisterActiveConnection(uuid, this)
            HttpService(context).leaveFaceTimeCall(uuid)
        }
        setDisconnected(DisconnectCause(causeCode))
        destroy()
    }

    private fun cleanupAudio(sendHangup: Boolean) {
        webRtcClient?.stop(sendHangup = sendHangup)
        webRtcClient = null
    }
}
