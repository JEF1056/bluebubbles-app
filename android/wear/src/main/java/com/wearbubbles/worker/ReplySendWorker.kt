package com.wearbubbles.worker

import android.content.Context
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
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
import kotlinx.coroutines.CancellationException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.UUID
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLHandshakeException

internal fun shouldRetrySend(error: Throwable?, runAttemptCount: Int): Boolean {
    if (error == null || runAttemptCount >= 4) return false
    var current: Throwable? = error
    var depth = 0
    while (current != null && depth < 8) {
        when (current) {
            is UnknownHostException,
            is ConnectException,
            is NoRouteToHostException,
            is SSLHandshakeException -> return true
            is SocketTimeoutException -> {
                // Only retry connect-phase timeouts; read timeouts mean the server may have already sent.
                if (current.message?.contains("connect", ignoreCase = true) == true) {
                    return true
                }
            }
        }
        current = current.cause
        depth++
    }
    return false
}

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
        private const val KEY_FROM_NOTIFICATION = "from_notification"
        private const val FOREGROUND_NOTIFICATION_ID = 1004
        private const val BACKOFF_DELAY_SECONDS = 10L

        private fun uniqueWorkName(tempGuid: String): String = "reply-$tempGuid"

        fun enqueue(
            context: Context,
            chatGuid: String,
            senderName: String?,
            replyText: String,
            tempGuid: String? = null,
            fromNotification: Boolean = true
        ) {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()

            val data = workDataOf(
                KEY_CHAT_GUID to chatGuid,
                KEY_SENDER_NAME to senderName,
                KEY_REPLY_TEXT to replyText,
                KEY_TEMP_GUID to tempGuid,
                KEY_FROM_NOTIFICATION to fromNotification
            )

            val request = OneTimeWorkRequestBuilder<ReplySendWorker>()
                .setInputData(data)
                .setConstraints(constraints)
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, BACKOFF_DELAY_SECONDS, TimeUnit.SECONDS)
                .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                .build()

            val uniqueName = if (!tempGuid.isNullOrBlank()) {
                uniqueWorkName(tempGuid)
            } else {
                "reply-${UUID.randomUUID()}"
            }
            WorkManager.getInstance(context)
                .enqueueUniqueWork(uniqueName, ExistingWorkPolicy.KEEP, request)
        }

        fun cancel(context: Context, tempGuid: String) {
            if (tempGuid.isBlank()) return
            WorkManager.getInstance(context).cancelUniqueWork(uniqueWorkName(tempGuid))
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
        val fromNotification = inputData.getBoolean(KEY_FROM_NOTIFICATION, true)

        val app = applicationContext as WearBubblesApp
        val db = AppDatabase.getInstance(applicationContext)
        if (!existingTempGuid.isNullOrBlank() && !db.messageDao().existsByGuid(existingTempGuid)) {
            return Result.success()
        }

        val settings = SettingsDataStore(applicationContext)
        val relay = app.phoneRelayClient
        val messageRepo = MessageRepository(db.messageDao(), db.chatDao(), settings, relay)
        val chatRepo = ChatRepository(db.chatDao(), settings, relay)

        return try {
            val sendResult = messageRepo.sendMessage(
                chatGuid = chatGuid,
                text = replyText,
                existingTempGuid = existingTempGuid,
                shouldMarkFailed = { err -> !shouldRetrySend(err, runAttemptCount) }
            )
            if (sendResult.isFailure) {
                throw sendResult.exceptionOrNull() ?: IllegalStateException("Send failed")
            }
            val resolvedGuid = sendResult.getOrNull()?.chatGuid ?: chatGuid
            runCatching { chatRepo.markChatRead(resolvedGuid) }
            if (fromNotification) {
                NotificationHelper.appendOutgoingReply(applicationContext, resolvedGuid, replyText)
            }
            Result.success()
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            if (shouldRetrySend(e, runAttemptCount)) {
                Log.w(TAG, "Transient reply send failure for $chatGuid (attempt $runAttemptCount), retrying", e)
                return Result.retry()
            }
            Log.w(TAG, "Standalone reply send failed for $chatGuid", e)
            if (fromNotification || NotificationHelper.activeChatGuid.value != chatGuid) {
                NotificationHelper.showReplyFailureNotification(applicationContext, chatGuid, senderName, replyText)
            }
            Result.failure()
        }
    }
}
