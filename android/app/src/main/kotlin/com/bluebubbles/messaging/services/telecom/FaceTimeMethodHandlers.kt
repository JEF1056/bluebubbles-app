package com.bluebubbles.messaging.services.telecom

import android.content.Context
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

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
        if (callUuid.isNullOrBlank()) {
            result.success(false)
            return
        }
        result.success(FaceTimeConnectionService.endCall(callUuid))
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
