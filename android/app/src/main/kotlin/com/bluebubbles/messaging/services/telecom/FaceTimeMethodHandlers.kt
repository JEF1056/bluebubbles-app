package com.bluebubbles.messaging.services.telecom

import android.app.NotificationManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import com.bluebubbles.messaging.services.wear.WearSyncManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal fun cancelIncomingCallNotifications(context: Context, callUuid: String, notificationId: Int? = null) {
    CallTonePlayer.stopIncomingRing(callUuid)
    val nm = context.getSystemService(NotificationManager::class.java) ?: return
    if (notificationId != null) {
        nm.cancel(Constants.newFaceTimeNotificationTag, notificationId)
    }
    try {
        for (sbn in nm.activeNotifications) {
            if (sbn.tag == Constants.newFaceTimeNotificationTag &&
                sbn.notification.extras?.getString("callUuid") == callUuid
            ) {
                nm.cancel(sbn.tag, sbn.id)
            }
        }
    } catch (_: Exception) {}
}

class PlaceFaceTimeCallHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "place-facetime-call"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val address: String? = call.argument("address")
        val callerName: String? = call.argument("caller_name")
        val callerAvatar: ByteArray? = call.argument("caller_avatar") ?: call.argument("callerAvatar")
        val isTelephony: Boolean = call.argument("is_telephony") ?: false
        val isVideo: Boolean = call.argument("is_video") ?: false
        if (address.isNullOrBlank()) {
            result.success(false)
            return
        }
        val placed = FaceTimeConnectionService.placeOutgoingCall(
            context = context,
            address = address,
            callerName = callerName,
            callerAvatar = callerAvatar,
            isTelephony = isTelephony,
            isVideo = isVideo
        )
        result.success(placed)
    }
}

class EndFaceTimeCallHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "end-facetime-call"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val callUuid: String? = call.argument("call_uuid")
        val onlyIfRinging: Boolean = call.argument("only_if_ringing") ?: false
        val notificationId: Int? = call.argument("notification_id")
        if (callUuid.isNullOrBlank()) {
            result.success(false)
            return
        }
        val ended = FaceTimeConnectionService.endCall(
            callUuid,
            onlyIfRinging = onlyIfRinging,
            recordIfPending = !onlyIfRinging
        )
        cancelIncomingCallNotifications(context, callUuid, notificationId)
        if (!onlyIfRinging || ended || !FaceTimeConnectionService.isCallActive(callUuid)) {
            com.bluebubbles.messaging.MainActivity.clearCallLockScreenFlags()
        }
        if (onlyIfRinging) {
            if (!FaceTimeConnectionService.isCallActive(callUuid)) {
                WearSyncManager.notifyCallEndedIfNotWatchAnswered(context, callUuid)
            }
        } else {
            WearSyncManager.notifyCallEnded(context, callUuid)
        }
        result.success(ended)
    }
}

class AnswerFaceTimeAudioHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "answer-facetime-audio"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val callUuid: String? = call.argument("call_uuid")
        if (callUuid.isNullOrBlank()) {
            result.success(false)
            return
        }
        val callerName: String = (call.argument<String>("caller_name") ?: "").ifBlank { "Unknown Caller" }
        val callerAddress: String? = call.argument("caller_address")
        val callerAvatar: ByteArray? = call.argument("caller_avatar") ?: call.argument("callerAvatar")
        val isTelephony: Boolean = call.argument("is_telephony") ?: false
        val isVideo: Boolean = call.argument("is_video") ?: false
        val routed = FaceTimeConnectionService.addIncomingCall(
            context = context,
            callUuid = callUuid,
            callerName = callerName,
            address = callerAddress,
            callerAvatar = callerAvatar,
            autoAnswer = true,
            isTelephony = isTelephony,
            isVideo = isVideo
        )
        if (routed) {
            cancelIncomingCallNotifications(context, callUuid)
        }
        result.success(routed)
    }
}

class IsTelecomEnabledHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "is-telecom-enabled"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        result.success(FaceTimeConnectionService.isPhoneAccountEnabled(context))
    }
}

class OpenCallingAccountsHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "open-calling-accounts"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        FaceTimeConnectionService.openCallingAccountsSettings(context)
        result.success(null)
    }
}

class RegisterPhoneAccountHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "register-phone-account"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        FaceTimeConnectionService.registerPhoneAccount(context)
        result.success(null)
    }
}

class MarkFaceTimeCallActiveHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "mark-facetime-call-active"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val callUuid = call.argument<String>("call_uuid") ?: call.argument<String>("callUuid")
        if (callUuid.isNullOrBlank()) {
            result.error("INVALID_ARGS", "call_uuid is required", null)
            return
        }
        val isOutgoing = call.argument<Boolean>("is_outgoing") ?: call.argument<Boolean>("isOutgoing") ?: false
        val callerName = call.argument<String>("callerName") ?: call.argument<String>("caller_name")
        val callerAddress = call.argument<String>("callerAddress") ?: call.argument<String>("caller_address")
        val callerAvatar = call.argument<ByteArray>("callerAvatar") ?: call.argument<ByteArray>("caller_avatar")
        val isVideo = call.argument<Boolean>("isVideo") ?: call.argument<Boolean>("is_video")
        val isGroup = call.argument<Boolean>("isGroup") ?: call.argument<Boolean>("is_group")
        val isTelephony = call.argument<Boolean>("isTelephony") ?: call.argument<Boolean>("is_telephony")

        FaceTimeConnectionService.getActiveConnection(callUuid)?.updateCallerInfo(
            callerName = callerName,
            callerAddress = callerAddress,
            callerAvatar = callerAvatar,
            isVideo = isVideo,
            isGroup = isGroup,
            isTelephony = isTelephony
        )
        result.success(FaceTimeConnectionService.markCallActive(callUuid, recordIfPending = isOutgoing))
    }
}

class SetFaceTimeMutedHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "set-facetime-muted"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val callUuid = call.argument<String>("call_uuid")
        if (callUuid.isNullOrBlank()) {
            result.error("INVALID_ARGS", "call_uuid is required", null)
            return
        }
        val muted = call.argument<Boolean>("muted") ?: false
        result.success(FaceTimeConnectionService.setCallMuted(callUuid, muted))
    }
}

class SetFaceTimeSpeakerHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "set-facetime-speaker"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val callUuid = call.argument<String>("call_uuid")
        val enabled = call.argument<Boolean>("enabled") ?: call.argument<Boolean>("speaker") ?: false
        result.success(FaceTimeConnectionService.setCallSpeakerphone(context, callUuid, enabled))
    }
}

class ToggleFaceTimeSpeakerHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "toggle-facetime-speaker"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val callUuid = call.argument<String>("call_uuid")
        val next = !FaceTimeConnectionService.isCallSpeakerphoneOn(context, callUuid)
        FaceTimeConnectionService.setCallSpeakerphone(context, callUuid, next)
        result.success(next)
    }
}

class IsFaceTimeSpeakerOnHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "is-facetime-speaker-on"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val callUuid = call.argument<String>("call_uuid")
        result.success(FaceTimeConnectionService.isCallSpeakerphoneOn(context, callUuid))
    }
}

class GetFaceTimeVideoTextureHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "get-facetime-video-texture"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val callUuid = call.argument<String>("call_uuid")
        val textureId = try {
            FaceTimeConnectionService.getCallVideoTextureId(callUuid)
        } catch (_: Exception) {
            null
        }
        result.success(textureId)
    }
}

class GetFaceTimeLocalVideoTextureHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "get-facetime-local-video-texture"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val callUuid = call.argument<String>("call_uuid")
        val textureId = try {
            FaceTimeConnectionService.getCallLocalVideoTextureId(callUuid)
        } catch (_: Exception) {
            null
        }
        result.success(textureId)
    }
}

class GetFaceTimeVideoTexturesHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "get-facetime-video-textures"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val callUuid = call.argument<String>("call_uuid")
        val textures = try {
            FaceTimeConnectionService.getCallVideoTextures(callUuid)
        } catch (_: Exception) {
            emptyMap<String, Any?>()
        }
        result.success(textures)
    }
}

class SetFaceTimeCameraEnabledHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "set-facetime-camera-enabled"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val callUuid = call.argument<String>("call_uuid")
        val enabled = call.argument<Boolean>("enabled") ?: false
        result.success(FaceTimeConnectionService.setCallCameraEnabled(callUuid, enabled))
    }
}

class FlipFaceTimeCameraHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "flip-facetime-camera"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val callUuid = call.argument<String>("call_uuid")
        result.success(FaceTimeConnectionService.flipCallCamera(callUuid))
    }
}

class ResumeFaceTimeVideoHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "resume-facetime-video"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val callUuid = call.argument<String>("call_uuid")
        result.success(FaceTimeConnectionService.resumeCallVideo(callUuid))
    }
}

class GetFaceTimeAudioDevicesHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "get-facetime-audio-devices"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val callUuid = call.argument<String>("call_uuid")
        result.success(FaceTimeConnectionService.getCallAudioDevices(context, callUuid))
    }
}

class SetFaceTimeAudioOutputHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "set-facetime-audio-output"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val callUuid = call.argument<String>("call_uuid")
        val deviceId = call.argument<String>("device_id")
        if (deviceId.isNullOrBlank()) {
            result.success(false)
            return
        }
        result.success(FaceTimeConnectionService.setCallAudioOutput(callUuid, deviceId))
    }
}

class SetFaceTimeAudioInputHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "set-facetime-audio-input"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val callUuid = call.argument<String>("call_uuid")
        val deviceId = call.argument<String>("device_id") ?: ""
        result.success(FaceTimeConnectionService.setCallAudioInput(callUuid, deviceId))
    }
}

class SetFaceTimeVoiceIsolationHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "set-facetime-voice-isolation"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val callUuid = call.argument<String>("call_uuid")
        val enabled = call.argument<Boolean>("enabled") ?: true
        result.success(FaceTimeConnectionService.setCallVoiceIsolation(callUuid, enabled))
    }
}

class SetFaceTimeVideoProcessingHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "set-facetime-video-processing"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val callUuid = call.argument<String>("call_uuid")
        val effect = call.argument<String>("effect")
        val denoise = call.argument<Boolean>("denoise") ?: false
        val backgroundPath = call.argument<String>("background_path") ?: call.argument<String>("background_id")
        result.success(
            FaceTimeConnectionService.setCallVideoProcessing(
                callUuid = callUuid,
                effect = effect,
                denoise = denoise,
                backgroundPath = backgroundPath
            )
        )
    }
}

class IsWearWatchConnectedHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "is-wear-watch-connected"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        WearSyncManager.isWatchConnected(context) { connected ->
            Handler(Looper.getMainLooper()).post {
                result.success(connected)
            }
        }
    }
}

class TransferCallToWatchHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "transfer-call-to-watch"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val callUuid = call.argument<String>("call_uuid")
        if (callUuid.isNullOrBlank()) {
            result.success(false)
            return
        }
        result.success(FaceTimeConnectionService.transferCallAudioToWatch(context, callUuid))
    }
}

class SetCallToneHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "set-call-tone"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val action = call.argument<String>("action")
        val callUuid = call.argument<String>("call_uuid") ?: call.argument<String>("callUuid")
        when (action) {
            "start_ringback" -> CallTonePlayer.startOutgoingRingback(context, callUuid ?: "dart-ringback")
            "stop_ringback" -> CallTonePlayer.stopOutgoingRingback(callUuid)
            "play_ended" -> CallTonePlayer.playCallEndedTone(context)
            "stop_incoming" -> CallTonePlayer.stopIncomingRing(callUuid)
            else -> {
                result.success(false)
                return
            }
        }
        result.success(true)
    }
}
