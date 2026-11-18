package com.wearbubbles.notifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class OpenOnPhoneReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val chatGuid = intent.getStringExtra(NotificationHelper.EXTRA_CHAT_GUID) ?: return
        val pendingResult = goAsync()
        Thread {
            try {
                RemoteLauncher.openServerOnPhone(context)
                NotificationHelper.cancelNotification(context, chatGuid)
            } finally {
                pendingResult.finish()
            }
        }.start()
    }
}
