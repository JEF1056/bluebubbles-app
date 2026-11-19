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
        val senderName = intent.getStringExtra(NotificationHelper.EXTRA_SENDER_NAME)
        val remoteInput = RemoteInput.getResultsFromIntent(intent)
        val replyText = remoteInput?.getCharSequence(NotificationHelper.KEY_TEXT_REPLY)?.toString()
        if (replyText.isNullOrBlank()) return

        val pendingResult = goAsync()
        val appContext = context.applicationContext
        val app = appContext as WearBubblesApp
        val db = AppDatabase.getInstance(appContext)
        val settings = SettingsDataStore(appContext)
        val relay = app.phoneRelayClient
        val messageRepo = MessageRepository(db.messageDao(), db.chatDao(), settings, relay)
        val chatRepo = ChatRepository(db.chatDao(), settings, relay)

        CoroutineScope(Dispatchers.IO).launch {
            try {
                val sendResult = withTimeout(10_000L) {
                    messageRepo.sendMessage(chatGuid, replyText)
                }
                if (sendResult.isFailure) {
                    throw sendResult.exceptionOrNull() ?: IllegalStateException("Send failed")
                }
                runCatching { chatRepo.markChatRead(chatGuid) }
                NotificationHelper.appendOutgoingReply(appContext, chatGuid, replyText)
            } catch (e: Exception) {
                Log.w("ReplyReceiver", "Failed to send reply for $chatGuid", e)
                NotificationHelper.showReplyFailureNotification(appContext, chatGuid, senderName, replyText)
            } finally {
                pendingResult.finish()
            }
        }
    }
}
