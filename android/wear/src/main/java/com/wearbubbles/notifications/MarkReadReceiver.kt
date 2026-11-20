package com.wearbubbles.notifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.wearbubbles.WearBubblesApp
import com.wearbubbles.data.ChatRepository
import com.wearbubbles.data.SettingsDataStore
import com.wearbubbles.db.AppDatabase
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

class MarkReadReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val chatGuid = intent.getStringExtra(NotificationHelper.EXTRA_CHAT_GUID) ?: return
        NotificationHelper.cancelNotification(context, chatGuid)

        val pendingResult = goAsync()
        val app = context.applicationContext as WearBubblesApp
        val relay = app.phoneRelayClient

        CoroutineScope(Dispatchers.IO).launch {
            try {
                withTimeout(5_000L) {
                    when (intent.action) {
                        NotificationHelper.ACTION_DISMISS -> {
                            if (relay.refreshPhoneConnected()) {
                                relay.sendDismissNotificationAwait(chatGuid)
                            }
                        }
                        NotificationHelper.ACTION_MARK_READ -> {
                            val db = AppDatabase.getInstance(context)
                            val chatRepo = ChatRepository(db.chatDao(), SettingsDataStore(context), relay)
                            chatRepo.markChatRead(chatGuid)
                        }
                    }
                }
            } catch (e: Exception) {
                Log.w("MarkReadReceiver", "Failed action=${intent.action} for $chatGuid", e)
            } finally {
                pendingResult.finish()
            }
        }
    }
}
