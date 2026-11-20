package com.wearbubbles.notifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

class OpenOnPhoneReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val chatGuid = intent.getStringExtra(NotificationHelper.EXTRA_CHAT_GUID) ?: return
        val appContext = context.applicationContext
        val pendingResult = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            try {
                RemoteLauncher.openChatOnPhone(appContext, chatGuid)
                NotificationHelper.cancelNotification(appContext, chatGuid)
            } finally {
                pendingResult.finish()
            }
        }
    }
}
