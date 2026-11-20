package com.wearbubbles.worker

import android.content.Context
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.wearbubbles.R
import com.wearbubbles.WearBubblesApp
import com.wearbubbles.data.ChatRepository
import com.wearbubbles.data.MessageRepository
import com.wearbubbles.data.SettingsDataStore
import com.wearbubbles.db.AppDatabase
import com.wearbubbles.notifications.NotificationHelper

class ReplySendWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    companion object {
        private const val TAG = "ReplySendWorker"
        private const val KEY_CHAT_GUID = "chat_guid"
        private const val KEY_SENDER_NAME = "sender_name"
        private const val KEY_REPLY_TEXT = "reply_text"
        private const val KEY_TEMP_GUID = "temp_guid"
        private const val FOREGROUND_NOTIFICATION_ID = 1004

        fun enqueue(
            context: Context,
            chatGuid: String,
            senderName: String?,
            replyText: String,
            tempGuid: String? = null
        ) {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()

            val data = workDataOf(
                KEY_CHAT_GUID to chatGuid,
                KEY_SENDER_NAME to senderName,
                KEY_REPLY_TEXT to replyText,
                KEY_TEMP_GUID to tempGuid
            )

            val request = OneTimeWorkRequestBuilder<ReplySendWorker>()
                .setInputData(data)
                .setConstraints(constraints)
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .build()

            WorkManager.getInstance(context).enqueue(request)
        }
    }

    override suspend fun getForegroundInfo(): ForegroundInfo {
        NotificationHelper.createChannels(applicationContext)
        val notification = NotificationCompat.Builder(applicationContext, NotificationHelper.CHANNEL_SERVICE)
            .setSmallIcon(R.drawable.ic_stat_icon)
            .setContentTitle("Sending reply")
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setSilent(true)
            .build()
        return ForegroundInfo(FOREGROUND_NOTIFICATION_ID, notification)
    }

    override suspend fun doWork(): Result {
        val chatGuid = inputData.getString(KEY_CHAT_GUID) ?: return Result.failure()
        val senderName = inputData.getString(KEY_SENDER_NAME)
        val replyText = inputData.getString(KEY_REPLY_TEXT) ?: return Result.failure()
        val existingTempGuid = inputData.getString(KEY_TEMP_GUID)

        val app = applicationContext as WearBubblesApp
        val db = AppDatabase.getInstance(applicationContext)
        val settings = SettingsDataStore(applicationContext)
        val relay = app.phoneRelayClient
        val messageRepo = MessageRepository(db.messageDao(), db.chatDao(), settings, relay)
        val chatRepo = ChatRepository(db.chatDao(), settings, relay)

        return try {
            val sendResult = messageRepo.sendMessage(chatGuid, replyText, existingTempGuid)
            if (sendResult.isFailure) {
                throw sendResult.exceptionOrNull() ?: IllegalStateException("Send failed")
            }
            runCatching { chatRepo.markChatRead(chatGuid) }
            NotificationHelper.appendOutgoingReply(applicationContext, chatGuid, replyText)
            Result.success()
        } catch (e: Exception) {
            Log.w(TAG, "Standalone reply send failed for $chatGuid", e)
            NotificationHelper.showReplyFailureNotification(applicationContext, chatGuid, senderName, replyText)
            Result.failure()
        }
    }
}
