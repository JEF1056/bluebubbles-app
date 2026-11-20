package com.wearbubbles.worker

import android.content.Context
import android.util.Log
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.wearbubbles.WearBubblesApp
import com.wearbubbles.data.ChatRepository
import com.wearbubbles.data.ContactRepository
import com.wearbubbles.data.SettingsDataStore
import com.wearbubbles.db.AppDatabase
import com.wearbubbles.notifications.NotificationHelper
import kotlinx.coroutines.flow.first
import java.util.concurrent.TimeUnit

class MessageSyncWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    companion object {
        private const val TAG = "MessageSyncWorker"
        private const val WORK_NAME = "wearbubbles_message_sync"

        fun schedule(context: Context) {
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.CONNECTED)
                .build()

            val request = PeriodicWorkRequestBuilder<MessageSyncWorker>(
                15, TimeUnit.MINUTES
            )
                .setConstraints(constraints)
                .build()

            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                WORK_NAME,
                ExistingPeriodicWorkPolicy.KEEP,
                request
            )
        }

        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
        }
    }

    override suspend fun doWork(): Result {
        val app = applicationContext as WearBubblesApp
        if (app.socketManager.isConnected.value) {
            return Result.success()
        }
        if (app.phoneRelayClient.refreshPhoneConnected()) {
            // Tethered to phone: cancel periodic polling so watch doesn't wake every 15m.
            cancel(applicationContext)
            return Result.success()
        }

        val settings = SettingsDataStore(applicationContext)
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
