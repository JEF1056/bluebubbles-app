package com.wearbubbles.notifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.app.RemoteInput
import com.wearbubbles.WearBubblesApp
import com.wearbubbles.data.ChatRepository
import com.wearbubbles.data.MessageRepository
import com.wearbubbles.data.SettingsDataStore
import com.wearbubbles.db.AppDatabase
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

class ReplyReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val chatGuid = intent.getStringExtra(NotificationHelper.EXTRA_CHAT_GUID) ?: return
        val remoteInput = RemoteInput.getResultsFromIntent(intent)
        val replyText = remoteInput?.getCharSequence(NotificationHelper.KEY_TEXT_REPLY)?.toString()
        if (replyText.isNullOrBlank()) return

        val pendingResult = goAsync()
        val app = context.applicationContext as WearBubblesApp
        val db = AppDatabase.getInstance(context)
        val settings = SettingsDataStore(context)
        val relay = app.phoneRelayClient
        val messageRepo = MessageRepository(db.messageDao(), db.chatDao(), settings, relay)
        val chatRepo = ChatRepository(db.chatDao(), settings, relay)

        CoroutineScope(Dispatchers.IO).launch {
            try {
                withTimeout(10_000L) {
                    messageRepo.sendMessage(chatGuid, replyText)
                    chatRepo.markChatRead(chatGuid)
                }
                NotificationHelper.cancelNotification(context, chatGuid)
            } catch (e: Exception) {
                Log.w("ReplyReceiver", "Failed to send reply for $chatGuid", e)
            } finally {
                pendingResult.finish()
            }
        }
    }
}
