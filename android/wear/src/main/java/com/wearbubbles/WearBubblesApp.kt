package com.wearbubbles

import android.app.Application
import android.util.Log
import coil.ImageLoader
import coil.ImageLoaderFactory
import coil.decode.GifDecoder
import coil.decode.ImageDecoderDecoder
import coil.disk.DiskCache
import com.wearbubbles.api.ApiClient
import com.wearbubbles.data.ChatRepository
import com.wearbubbles.data.MessageRepository
import com.wearbubbles.data.SettingsDataStore
import com.wearbubbles.db.AppDatabase
import com.wearbubbles.notifications.NotificationHelper
import com.wearbubbles.relay.PhoneRelayClient
import com.wearbubbles.service.ForegroundSocketSession
import com.wearbubbles.socket.SocketEvent
import com.wearbubbles.socket.SocketManager
import com.wearbubbles.worker.MessageSyncWorker
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class WearBubblesApp : Application(), ImageLoaderFactory {

    companion object {
        private const val TAG = "WearBubblesApp"
        private const val COIL_DISK_CACHE_BYTES = 20L * 1024 * 1024
    }

    val applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    val socketManager = SocketManager()
    val foregroundSocketSession = ForegroundSocketSession()
    lateinit var phoneRelayClient: PhoneRelayClient
        private set

    override fun onCreate() {
        super.onCreate()
        phoneRelayClient = PhoneRelayClient(this)
        NotificationHelper.createChannels(this)
        // Purge legacy periodic sync work from upgraded installs.
        MessageSyncWorker.cancel(this)
        observeSocketPersistence()
    }

    override fun newImageLoader(): ImageLoader {
        return ImageLoader.Builder(this)
            .okHttpClient(ApiClient.okHttpClient)
            .diskCache {
                DiskCache.Builder()
                    .directory(cacheDir.resolve("coil_image_cache"))
                    .maxSizeBytes(COIL_DISK_CACHE_BYTES)
                    .build()
            }
            .components {
                add(ImageDecoderDecoder.Factory())
                add(GifDecoder.Factory())
            }
            .build()
    }

    private fun observeSocketPersistence() {
        val db = AppDatabase.getInstance(this)
        val settings = SettingsDataStore(this)
        val chatRepo = ChatRepository(db.chatDao(), settings, phoneRelayClient)
        val messageRepo = MessageRepository(db.messageDao(), db.chatDao(), settings, phoneRelayClient)

        applicationScope.launch {
            socketManager.events.collect { event ->
                try {
                    when (event) {
                        is SocketEvent.NewMessage -> {
                            messageRepo.handleIncomingSocketMessage(event.message, isUpdate = false)
                        }
                        is SocketEvent.UpdatedMessage -> {
                            messageRepo.handleIncomingSocketMessage(event.message, isUpdate = true)
                        }
                        is SocketEvent.MessageSendError -> {
                            messageRepo.handleMessageSendError(event.message)
                        }
                        is SocketEvent.PinnedChatsUpdated -> {
                            chatRepo.updatePinnedOrder(event.pinnedChatGuids)
                        }
                        is SocketEvent.ChatReadStatusChanged -> {
                            chatRepo.handleReadStatusChanged(event.chatGuid, event.read, event.readAt)
                            if (event.read) {
                                NotificationHelper.cancelNotification(this@WearBubblesApp, event.chatGuid)
                            }
                        }
                        else -> {}
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "Socket persistence failed: ${e.message}")
                }
            }
        }
    }
}
