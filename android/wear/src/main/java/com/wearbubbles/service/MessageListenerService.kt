package com.wearbubbles.service

import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
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
import com.wearbubbles.data.MessageRepository
import com.wearbubbles.data.SettingsDataStore
import com.wearbubbles.db.AppDatabase
import com.wearbubbles.notifications.CallNotificationHelper
import com.wearbubbles.notifications.NotificationHelper
import com.wearbubbles.socket.SocketEvent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

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
        val app = applicationContext as WearBubblesApp
        val settings = SettingsDataStore(this)
        val db = AppDatabase.getInstance(this)
        val relay = app.phoneRelayClient
        val contactRepo = ContactRepository(this, db.contactDao(), settings, relay)
        val messageRepo = MessageRepository(db.messageDao(), db.chatDao(), settings, relay)

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
                        messageRepo.handleIncomingSocketMessage(msg)

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

                            val haptic = settings.hapticEnabled.first()
                            NotificationHelper.showMessageNotification(
                                context = this@MessageListenerService,
                                chatGuid = chatGuid,
                                senderName = senderName,
                                messageText = bodyText,
                                isGroup = chat?.isGroup ?: false,
                                groupTitle = chat?.displayName,
                                hapticEnabled = haptic,
                                timestamp = msg.dateCreated,
                                senderAddress = senderAddr,
                                senderAvatarPath = senderAvatar,
                                isTapback = false,
                                attachmentPath = cachedImagePath,
                                attachmentMimeType = firstAttachment?.mimeType
                            )
                        } else if (!msg.isFromMe && TapbackUtils.isTapbackCode(msg.associatedMessageType)) {
                            val reactionLabel = TapbackType.fromAddCode(msg.associatedMessageType)?.label
                            if (reactionLabel != null) {
                                val chat = db.chatDao().getChat(chatGuid)
                                val senderAddr = msg.handle?.address ?: chat?.chatIdentifier ?: "Someone"
                                val senderName = contactRepo.resolveDisplayName(senderAddr)
                                val senderAvatar = contactRepo.resolveAvatarPath(senderAddr)
                                val haptic = settings.hapticEnabled.first()
                                NotificationHelper.showMessageNotification(
                                    context = this@MessageListenerService,
                                    chatGuid = chatGuid,
                                    senderName = senderName,
                                    messageText = "$reactionLabel a message",
                                    isGroup = chat?.isGroup ?: false,
                                    groupTitle = chat?.displayName,
                                    hapticEnabled = haptic,
                                    timestamp = msg.dateCreated,
                                    senderAddress = senderAddr,
                                    senderAvatarPath = senderAvatar,
                                    isTapback = true
                                )
                            }
                        }
                    }

                    is SocketEvent.UpdatedMessage -> {
                        messageRepo.handleIncomingSocketMessage(event.message)
                    }

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

                    else -> {}
                }
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        eventJob?.cancel()
        connectJob?.cancel()
        scope.cancel()
        super.onDestroy()
    }
}
