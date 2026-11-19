package com.wearbubbles.notifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.wearbubbles.WearBubblesApp
import kotlinx.coroutines.runBlocking

class OpenOnPhoneReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val chatGuid = intent.getStringExtra(NotificationHelper.EXTRA_CHAT_GUID) ?: return
        val appContext = context.applicationContext
        val app = appContext as WearBubblesApp
        val pendingResult = goAsync()
        Thread {
            try {
                runBlocking {
                    val sent = if (app.phoneRelayClient.refreshPhoneConnected()) {
                        app.phoneRelayClient.sendOpenChatAwait(chatGuid)
                    } else {
                        false
                    }
                    if (!sent) {
                        RemoteLauncher.openServerOnPhone(appContext)
                    }
                }
                NotificationHelper.cancelNotification(appContext, chatGuid)
            } finally {
                pendingResult.finish()
            }
        }.start()
    }
}
