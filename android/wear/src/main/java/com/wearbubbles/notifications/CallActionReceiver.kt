package com.wearbubbles.notifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val callUuid = intent.getStringExtra(CallNotificationHelper.EXTRA_CALL_UUID) ?: return
        val appContext = context.applicationContext
        val pendingResult = goAsync()

        CoroutineScope(Dispatchers.IO).launch {
            try {
                withTimeoutOrNull(8_000L) {
                    when (intent.action) {
                        CallNotificationHelper.ACTION_ANSWER_CALL -> {
                            CallNotificationHelper.answerCallAudio(appContext, callUuid)
                        }
                        CallNotificationHelper.ACTION_DECLINE_CALL,
                        CallNotificationHelper.ACTION_END_CALL -> {
                            CallNotificationHelper.declineOrEndCall(appContext, callUuid)
                        }
                        CallNotificationHelper.ACTION_TOGGLE_MUTE -> {
                            CallNotificationHelper.toggleMute(appContext, callUuid)
                        }
                    }
                }
            } finally {
                pendingResult.finish()
            }
        }
    }
}
