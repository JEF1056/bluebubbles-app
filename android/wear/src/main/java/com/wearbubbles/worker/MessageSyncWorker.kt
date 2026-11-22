package com.wearbubbles.worker

import android.content.Context
import android.util.Log
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.wearbubbles.WearBubblesApp
import com.wearbubbles.data.ChatRepository
import com.wearbubbles.data.ContactRepository
import com.wearbubbles.data.SettingsDataStore
import com.wearbubbles.db.AppDatabase
import com.wearbubbles.notifications.NotificationHelper
import kotlinx.coroutines.flow.first

class MessageSyncWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    companion object {
        private const val TAG = "MessageSyncWorker"
        private const val WORK_NAME = "wearbubbles_message_sync"
        private const val ONCE_WORK_NAME = "wearbubbles_message_sync_once"
        const val KEY_FORCE = "force"

        internal fun shouldSkipSync(isSocketConnected: Boolean, force: Boolean): Boolean =
            isSocketConnected && !force

        fun runOnce(context: Context) {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()

            val request = OneTimeWorkRequestBuilder<MessageSyncWorker>()
                .setConstraints(constraints)
                .setInputData(workDataOf(KEY_FORCE to true))
                .build()

            WorkManager.getInstance(context).enqueueUniqueWork(
                ONCE_WORK_NAME,
                ExistingWorkPolicy.KEEP,
                request
            )
        }

        fun cancel(context: Context) {
            val wm = WorkManager.getInstance(context)
            wm.cancelUniqueWork(WORK_NAME)
            wm.cancelUniqueWork(ONCE_WORK_NAME)
        }
    }

    override suspend fun doWork(): Result {
        val app = applicationContext as WearBubblesApp
        val settings = SettingsDataStore(applicationContext)
        if (settings.isUserDisconnected()) {
            cancel(applicationContext)
            return Result.success()
        }
        val force = inputData.getBoolean(KEY_FORCE, false)
        if (shouldSkipSync(app.socketManager.isConnected.value, force)) {
            return Result.success()
        }
        if (app.phoneRelayClient.refreshPhoneConnected()) {
            // Tethered to phone: cancel periodic polling so watch doesn't wake every 15m.
            cancel(applicationContext)
            return Result.success()
        }

        val url = settings.getServerUrl()
        val password = settings.getPassword()
        if (url.isBlank() || password.isBlank()) {
            cancel(applicationContext)
            return Result.success()
        }

        return try {
            val db = AppDatabase.getInstance(applicationContext)
            val chatDao = db.chatDao()
            val contactRepo = ContactRepository(applicationContext, db.contactDao(), settings, app.phoneRelayClient)
            contactRepo.loadFromDb()

            val prevChats = chatDao.getChatCount()
            val prevLastTime = chatDao.getLastMessageTime() ?: 0L

            val chatRepo = ChatRepository(chatDao, settings, app.phoneRelayClient)
            chatRepo.refreshChats()

            val newLastTime = chatDao.getLastMessageTime() ?: 0L
            if (prevChats > 0 && newLastTime > prevLastTime) {
                Log.d(TAG, "New messages detected via background sync")
                val chats = chatDao.getAllChatsOnce()
                val haptic = settings.hapticEnabled.first()
                chats.filter { it.hasUnreadMessage && it.lastMessageDate > prevLastTime }
                    .take(3)
                    .forEach { chat ->
                        val title = contactRepo.resolveChatTitle(
                            chat.displayName,
                            chat.chatIdentifier,
                            chat.participantAddresses
                        )
                        val avatarPath = contactRepo.resolveAvatarForChat(
                            chat.guid,
                            chat.participantAddresses
                        )
                        NotificationHelper.showMessageNotification(
                            context = applicationContext,
                            chatGuid = chat.guid,
                            senderName = title,
                            messageText = chat.lastMessageText ?: "New message",
                            isGroup = chat.isGroup,
                            groupTitle = chat.displayName,
                            hapticEnabled = haptic,
                            timestamp = chat.lastMessageDate,
                            senderAddress = chat.chatIdentifier,
                            senderAvatarPath = avatarPath
                        )
                    }
            }

            Result.success()
        } catch (e: Exception) {
            Log.w(TAG, "Background sync failed: ${e.message}")
            Result.retry()
        }
    }
}
