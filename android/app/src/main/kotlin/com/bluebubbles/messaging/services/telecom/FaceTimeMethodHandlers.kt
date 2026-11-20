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
        if (address.isNullOrBlank()) {
            result.success(false)
            return
        }
        val placed = FaceTimeConnectionService.placeOutgoingCall(
            context = context,
            address = address,
            callerName = callerName,
            isTelephony = isTelephony
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
        val routed = FaceTimeConnectionService.addIncomingCall(
            context = context,
            callUuid = callUuid,
            callerName = callerName,
            address = callerAddress,
            autoAnswer = true,
            isTelephony = isTelephony
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
