package com.bluebubbles.messaging.services.telecom

import android.app.NotificationManager
import android.content.Context
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import com.bluebubbles.messaging.services.wear.WearSyncManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal fun cancelIncomingCallNotifications(context: Context, callUuid: String, notificationId: Int? = null) {
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
        val ended = FaceTimeConnectionService.endCall(callUuid, onlyIfRinging = onlyIfRinging)
        cancelIncomingCallNotifications(context, callUuid, notificationId)
        if (onlyIfRinging) {
            WearSyncManager.notifyCallEndedIfNotWatchAnswered(context, callUuid)
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
        val isTelephony: Boolean = call.argument("is_telephony") ?: false
        val isVideo: Boolean = call.argument("is_video") ?: false
        val routed = FaceTimeConnectionService.addIncomingCall(
            context = context,
            callUuid = callUuid,
            callerName = callerName,
            address = callerAddress,
            autoAnswer = true,
            isTelephony = isTelephony,
            isVideo = isVideo
        )
        if (routed) {
            cancelIncomingCallNotifications(context, callUuid)
            WearSyncManager.notifyCallEndedIfNotWatchAnswered(context, callUuid)
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
        val callUuid = call.argument<String>("call_uuid")
        if (callUuid.isNullOrBlank()) {
            result.error("INVALID_ARGS", "call_uuid is required", null)
            return
        }
        val isOutgoing = call.argument<Boolean>("is_outgoing") ?: false
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
