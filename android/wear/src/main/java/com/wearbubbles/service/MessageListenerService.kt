package com.wearbubbles.service

import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.wear.ongoing.OngoingActivity
import androidx.wear.ongoing.Status
import com.wearbubbles.MainActivity
import com.wearbubbles.R
import com.wearbubbles.WearBubblesApp
import com.wearbubbles.api.dto.TapbackType
import com.wearbubbles.api.dto.TapbackUtils
import com.wearbubbles.data.ContactRepository
import com.wearbubbles.data.SettingsDataStore
import com.wearbubbles.db.AppDatabase
import com.wearbubbles.notifications.CallNotificationHelper
import com.wearbubbles.notifications.NotificationHelper
import com.wearbubbles.socket.SocketEvent
import com.wearbubbles.worker.MessageSyncWorker
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap

class MessageListenerService : Service() {

    companion object {
        private const val SERVICE_NOTIFICATION_ID = 1001

        fun start(context: Context) {
            val intent = Intent(context, MessageListenerService::class.java)
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, MessageListenerService::class.java))
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var eventJob: Job? = null
    private var connectJob: Job? = null
    private var hapticJob: Job? = null
    private var relayJob: Job? = null
    @Volatile
    private var hapticEnabled: Boolean = true
    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private val validatedNetworks = ConcurrentHashMap.newKeySet<Network>()

    override fun onCreate() {
        super.onCreate()
        NotificationHelper.createChannels(this)
        val touchIntent = PendingIntent.getActivity(
            this,
            SERVICE_NOTIFICATION_ID,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notificationBuilder = NotificationCompat.Builder(this, NotificationHelper.CHANNEL_SERVICE)
            .setSmallIcon(R.drawable.ic_stat_icon)
            .setContentTitle("BlueBubbles")
            .setContentText("Standalone connection active")
            .setContentIntent(touchIntent)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setSilent(true)
            .setOngoing(true)

        try {
            val status = Status.Builder()
                .addTemplate("Connected")
                .build()
            OngoingActivity.Builder(applicationContext, SERVICE_NOTIFICATION_ID, notificationBuilder)
                .setStaticIcon(R.drawable.ic_stat_icon)
                .setTouchIntent(touchIntent)
                .setStatus(status)
                .build()
                .apply(applicationContext)
        } catch (_: Throwable) {
        }

        val notification = notificationBuilder.build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                SERVICE_NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING
            )
        } else {
            startForeground(SERVICE_NOTIFICATION_ID, notification)
        }

        startListening()
    }

    private fun startListening() {
        connectJob?.cancel()
        eventJob?.cancel()
        hapticJob?.cancel()
        relayJob?.cancel()
        val app = applicationContext as WearBubblesApp
        val settings = SettingsDataStore(this)
        val db = AppDatabase.getInstance(this)
        val relay = app.phoneRelayClient
        val contactRepo = ContactRepository(this, db.contactDao(), settings, relay)

        hapticJob = scope.launch {
            settings.hapticEnabled.collect { hapticEnabled = it }
        }

        relayJob = scope.launch {
            relay.isPhoneConnected.collect { connected ->
                if (connected) {
                    app.socketManager.disconnect()
                    stopSelf()
                }
            }
        }

        registerNetworkCallback(app, relay)

        connectJob = scope.launch {
            if (relay.refreshPhoneConnected()) {
                // Phone-Relay is active; avoid running a persistent watch Socket.IO service.
                app.socketManager.disconnect()
                stopSelf()
                return@launch
            }
            val url = settings.getServerUrl()
            val password = settings.getPassword()
            val headers = settings.getCustomHeaders()
            if (url.isNotBlank() && password.isNotBlank()) {
                contactRepo.loadFromDb()
                app.socketManager.connect(url, password, headers)
            } else {
                stopSelf()
            }
        }

        eventJob = scope.launch {
            app.socketManager.events.collect { event ->
                when (event) {
                    is SocketEvent.NewMessage -> {
                        val msg = event.message
                        val chatGuid = msg.chats?.firstOrNull()?.guid ?: return@collect
                        if (!msg.isFromMe && !TapbackUtils.isTapbackCode(msg.associatedMessageType)) {
                            val chat = db.chatDao().getChat(chatGuid)
                            val senderAddr = msg.handle?.address ?: chat?.chatIdentifier ?: "Message"
                            val senderName = contactRepo.resolveDisplayName(senderAddr)
                            val senderAvatar = contactRepo.resolveAvatarPath(senderAddr)
                            val firstAttachment = msg.attachments?.firstOrNull()
                            val cachedImagePath = firstAttachment
                                ?.takeIf { it.mimeType?.startsWith("image/") == true }
                                ?.let { relay.getCachedAttachmentFile(it.guid)?.absolutePath }
                            val bodyText = msg.text?.takeIf { it.isNotBlank() }
                                ?: firstAttachment?.let { att ->
                                    when {
                                        att.mimeType?.startsWith("image/") == true -> "Sent an image"
                                        att.mimeType?.startsWith("video/") == true -> "Sent a video"
                                        att.mimeType?.startsWith("audio/") == true -> "Sent a voice memo"
                                        else -> "Sent an attachment"
                                    }
                                } ?: "New message"

                            NotificationHelper.showMessageNotification(
                                context = this@MessageListenerService,
                                chatGuid = chatGuid,
                                senderName = senderName,
                                messageText = bodyText,
                                isGroup = chat?.isGroup ?: false,
                                groupTitle = chat?.displayName,
                                hapticEnabled = hapticEnabled,
                                timestamp = msg.dateCreated,
                                senderAddress = senderAddr,
                                senderAvatarPath = senderAvatar,
                                isTapback = false,
                                attachmentPath = cachedImagePath,
                                attachmentMimeType = firstAttachment?.mimeType
                            )
                        } else if (!msg.isFromMe && TapbackUtils.isTapbackCode(msg.associatedMessageType)) {
                            val tapback = TapbackType.fromAddCode(msg.associatedMessageType)
                            val reactionLabel = if (tapback == TapbackType.EMOJI && !msg.associatedMessageEmoji.isNullOrBlank()) {
                                "Reacted ${msg.associatedMessageEmoji} to"
                            } else {
                                tapback?.label
                            }
                            if (reactionLabel != null) {
                                val chat = db.chatDao().getChat(chatGuid)
                                val senderAddr = msg.handle?.address ?: chat?.chatIdentifier ?: "Someone"
                                val senderName = contactRepo.resolveDisplayName(senderAddr)
                                val senderAvatar = contactRepo.resolveAvatarPath(senderAddr)
                                NotificationHelper.showMessageNotification(
                                    context = this@MessageListenerService,
                                    chatGuid = chatGuid,
                                    senderName = senderName,
                                    messageText = "$reactionLabel a message",
                                    isGroup = chat?.isGroup ?: false,
                                    groupTitle = chat?.displayName,
                                    hapticEnabled = hapticEnabled,
                                    timestamp = msg.dateCreated,
                                    senderAddress = senderAddr,
                                    senderAvatarPath = senderAvatar,
                                    isTapback = true
                                )
                            }
                        }
                    }

                    is SocketEvent.UpdatedMessage -> {}

                    is SocketEvent.IncomingFaceTime -> {
                        val resolvedName = if (event.callerAddress.isNotBlank()) {
                            contactRepo.resolveDisplayName(event.callerAddress)
                        } else {
                            event.callerName
                        }
                        CallNotificationHelper.showIncomingCall(
                            context = this@MessageListenerService,
                            callUuid = event.callUuid,
                            callerName = resolvedName,
                            callerAddress = event.callerAddress,
                            isVideo = event.isVideo,
                            fromPhoneRelay = false
                        )
                    }

                    is SocketEvent.FaceTimeCallEnded -> {
                        CallNotificationHelper.endCall(this@MessageListenerService, event.callUuid)
                    }

                    is SocketEvent.Connected -> {
                        MessageSyncWorker.runOnce(this@MessageListenerService)
                    }

                    else -> {}
                }
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val app = applicationContext as WearBubblesApp
        if (connectJob?.isActive != true && !app.socketManager.isConnected.value) {
            startListening()
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun registerNetworkCallback(app: WearBubblesApp, relay: com.wearbubbles.relay.PhoneRelayClient) {
        if (networkCallback != null) return
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        connectivityManager = cm
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                val hasInternet = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                if (hasInternet) {
                    val wasEmpty = validatedNetworks.isEmpty()
                    validatedNetworks.add(network)
                    if (wasEmpty && !relay.isPhoneConnected.value) {
                        app.socketManager.reconnectIfConfigured()
                    }
                } else {
                    validatedNetworks.remove(network)
                    if (validatedNetworks.isEmpty()) {
                        app.socketManager.disconnect()
                    }
                }
            }

            override fun onLost(network: Network) {
                validatedNetworks.remove(network)
                if (validatedNetworks.isEmpty()) {
                    app.socketManager.disconnect()
                }
            }
        }
        networkCallback = callback
        try {
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            cm.registerNetworkCallback(request, callback)
        } catch (_: Exception) {
            networkCallback = null
        }
    }

    override fun onDestroy() {
        networkCallback?.let { cb ->
            try {
                connectivityManager?.unregisterNetworkCallback(cb)
            } catch (_: Exception) {
            }
        }
        networkCallback = null
        eventJob?.cancel()
        connectJob?.cancel()
        hapticJob?.cancel()
        relayJob?.cancel()
        scope.cancel()
        super.onDestroy()
    }
}
