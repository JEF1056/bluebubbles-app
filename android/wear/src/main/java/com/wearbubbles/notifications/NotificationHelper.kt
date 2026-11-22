package com.wearbubbles.notifications

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.collection.LruCache
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.app.RemoteInput
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.core.graphics.drawable.IconCompat
import androidx.wear.phone.interactions.notifications.BridgingConfig
import androidx.wear.phone.interactions.notifications.BridgingManager
import androidx.compose.ui.graphics.toArgb
import com.wearbubbles.MainActivity
import com.wearbubbles.R
import com.wearbubbles.ui.theme.avatarMonogram
import com.wearbubbles.ui.theme.avatarSwatchFor
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File
import java.util.concurrent.ConcurrentHashMap

object NotificationHelper {

    const val CHANNEL_MESSAGES = "messages"
    const val CHANNEL_SERVICE = "service"
    const val CHANNEL_CALLS = "calls"
    const val GROUP_KEY_MESSAGES = "com.wearbubbles.MESSAGES"
    const val SUMMARY_NOTIFICATION_ID = 1002
    const val CALL_NOTIFICATION_ID = 1003

    const val KEY_TEXT_REPLY = "key_text_reply"
    const val EXTRA_CHAT_GUID = "extra_chat_guid"
    const val EXTRA_SENDER_NAME = "extra_sender_name"
    const val ACTION_REPLY = "com.wearbubbles.ACTION_REPLY"
    const val ACTION_OPEN_ON_PHONE = "com.wearbubbles.ACTION_OPEN_ON_PHONE"
    const val ACTION_MARK_READ = "com.wearbubbles.ACTION_MARK_READ"
    const val ACTION_DISMISS = "com.wearbubbles.ACTION_DISMISS"
    val QUICK_REPLY_CHOICES = arrayOf("Yes", "No", "On my way", "Sounds good", "Thanks!")

    private val _activeChatGuid = MutableStateFlow<String?>(null)
    val activeChatGuid: StateFlow<String?> = _activeChatGuid.asStateFlow()

    // Require MainActivity.onResume() (true) so early ViewModel init before lifecycle binding cannot mark read.
    private val _isAppResumed = MutableStateFlow<Boolean?>(null)
    @Volatile
    private var pendingLaunchChatGuid: String? = null

    private val messageHistory = ConcurrentHashMap<String, MutableList<NotificationCompat.MessagingStyle.Message>>()
    private val chatMetadata = ConcurrentHashMap<String, ChatNotifMeta>()
    private val personIconCache = LruCache<String, IconCompat>(24)

    private data class ChatNotifMeta(
        val senderName: String,
        val senderAddress: String?,
        val senderAvatarPath: String?,
        val isGroup: Boolean,
        val groupTitle: String?
    )

    fun setAppResumed(resumed: Boolean) {
        _isAppResumed.value = resumed
    }

    fun setPendingLaunchChatGuid(chatGuid: String?) {
        pendingLaunchChatGuid = chatGuid?.takeIf { it.isNotBlank() }
    }

    internal fun isAppResumedOrUnbound(): Boolean = _isAppResumed.value == true

    internal fun resetLifecycleForTest() {
        _isAppResumed.value = null
        pendingLaunchChatGuid = null
    }

    internal fun shouldActivateChat(chatGuid: String): Boolean {
        if (!isAppResumedOrUnbound()) return false
        val pending = pendingLaunchChatGuid
        return pending == null || pending == chatGuid
    }

    internal fun shouldMarkChatReadOnIncoming(
        activeChatGuid: String?,
        targetChatGuid: String,
        isFromMe: Boolean
    ): Boolean = !isFromMe && activeChatGuid == targetChatGuid

    fun setActiveChat(chatGuid: String?, context: Context? = null) {
        _activeChatGuid.value = chatGuid
        if (chatGuid != null) {
            clearConversationHistory(chatGuid)
            if (context != null) {
                cancelNotification(context, chatGuid)
            }
        }
        if (context != null) {
            updateBridgingExclusion(context, chatGuid)
        }
    }

    fun updateBridgingExclusion(context: Context, excludedChatGuid: String?) {
        try {
            val appContext = context.applicationContext
            val builder = BridgingConfig.Builder(appContext, true)
            if (!excludedChatGuid.isNullOrBlank()) {
                builder.addExcludedTag(excludedChatGuid)
            }
            BridgingManager.fromContext(appContext).setConfig(builder.build())
        } catch (_: Throwable) {
            // BridgingManager is unavailable in unit tests or non-Wear environments.
        }
    }

    fun clearConversationHistory(chatGuid: String) {
        messageHistory.remove(chatGuid)
    }

    fun canPostNotifications(context: Context): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted = ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
            if (!granted) return false
        }
        return try {
            NotificationManagerCompat.from(context).areNotificationsEnabled()
        } catch (_: Exception) {
            true
        }
    }

    fun createChannels(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return

        val messagesChannel = NotificationChannel(
            CHANNEL_MESSAGES,
            "Messages",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Incoming BlueBubbles messages"
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 150, 80, 150)
        }

        val serviceChannel = NotificationChannel(
            CHANNEL_SERVICE,
            "Background Connection",
            NotificationManager.IMPORTANCE_MIN
        ).apply {
            description = "Keeps WearBubbles connected in standalone mode"
            setShowBadge(false)
        }

        val callsChannel = NotificationChannel(
            CHANNEL_CALLS,
            "Incoming Calls",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Incoming FaceTime calls"
            enableVibration(true)
            setSound(
                Settings.System.DEFAULT_RINGTONE_URI,
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
        }

        manager.createNotificationChannel(messagesChannel)
        manager.createNotificationChannel(serviceChannel)
        manager.createNotificationChannel(callsChannel)
    }

    fun showMessageNotification(
        context: Context,
        chatGuid: String,
        senderName: String,
        messageText: String,
        isGroup: Boolean = false,
        groupTitle: String? = null,
        hapticEnabled: Boolean = true,
        timestamp: Long = System.currentTimeMillis(),
        senderAddress: String? = null,
        senderAvatarPath: String? = null,
        isTapback: Boolean = false,
        attachmentPath: String? = null,
        attachmentMimeType: String? = null
    ) {
        if (_activeChatGuid.value == chatGuid) return
        if (!canPostNotifications(context)) return

        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val notificationId = chatGuid.hashCode()
        val msgTime = timestamp.takeIf { it > 0L } ?: System.currentTimeMillis()

        chatMetadata[chatGuid] = ChatNotifMeta(
            senderName = senderName,
            senderAddress = senderAddress,
            senderAvatarPath = senderAvatarPath,
            isGroup = isGroup,
            groupTitle = groupTitle
        )

        val senderPerson = buildPerson(
            name = senderName,
            address = senderAddress,
            avatarPath = senderAvatarPath,
            important = true
        )

        val msg = NotificationCompat.MessagingStyle.Message(messageText, msgTime, senderPerson).apply {
            if (!attachmentPath.isNullOrBlank() && attachmentMimeType?.startsWith("image/") == true) {
                resolveAttachmentUri(context, attachmentPath)?.let { uri ->
                    setData(attachmentMimeType, uri)
                }
            }
        }
        val snapshot = appendHistoryMessage(manager, notificationId, chatGuid, msg)

        postMessagingNotification(
            context = context,
            manager = manager,
            chatGuid = chatGuid,
            senderName = senderName,
            senderPerson = senderPerson,
            mePerson = mePerson(),
            snapshot = snapshot,
            isGroup = isGroup,
            groupTitle = groupTitle,
            timestamp = msgTime,
            silent = !hapticEnabled,
            onlyAlertOnce = isTapback
        )
    }

    fun appendOutgoingReply(context: Context, chatGuid: String, replyText: String) {
        if (!canPostNotifications(context)) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val notificationId = chatGuid.hashCode()
        val meta = chatMetadata[chatGuid]
        val now = System.currentTimeMillis()
        val me = mePerson()
        val snapshot = appendHistoryMessage(
            manager,
            notificationId,
            chatGuid,
            // Pass null Person so MessagingStyle always treats the reply as from mePerson.
            NotificationCompat.MessagingStyle.Message(replyText, now, null as Person?)
        )

        val senderName = meta?.senderName ?: "BlueBubbles"
        val senderPerson = buildPerson(
            name = senderName,
            address = meta?.senderAddress,
            avatarPath = meta?.senderAvatarPath,
            important = true
        )

        postMessagingNotification(
            context = context,
            manager = manager,
            chatGuid = chatGuid,
            senderName = senderName,
            senderPerson = senderPerson,
            mePerson = me,
            snapshot = snapshot,
            isGroup = meta?.isGroup ?: false,
            groupTitle = meta?.groupTitle,
            timestamp = now,
            silent = true,
            onlyAlertOnce = true
        )
    }

    private fun mePerson(): Person = Person.Builder().setName("Me").setKey("me").build()

    private fun appendHistoryMessage(
        manager: NotificationManager,
        notificationId: Int,
        chatGuid: String,
        msg: NotificationCompat.MessagingStyle.Message
    ): List<NotificationCompat.MessagingStyle.Message> {
        val history = messageHistory.getOrPut(chatGuid) { mutableListOf() }
        return synchronized(history) {
            if (history.isEmpty()) {
                recoverHistoryFromActive(manager, notificationId, history)
            }
            history.add(msg)
            while (history.size > 6) history.removeAt(0)
            history.toList()
        }
    }

    fun showReplyFailureNotification(
        context: Context,
        chatGuid: String,
        senderName: String?,
        replyText: String
    ) {
        if (!canPostNotifications(context)) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val encodedGuid = Uri.encode(chatGuid)
        val notificationId = chatGuid.hashCode() + 5000

        val tapIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            data = Uri.parse("wearbubbles://chat/$encodedGuid/reply_failed")
            putExtra(EXTRA_CHAT_GUID, chatGuid)
        }
        val tapPendingIntent = PendingIntent.getActivity(
            context,
            notificationId,
            tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val title = if (!senderName.isNullOrBlank()) {
            "Failed to send to $senderName"
        } else {
            "Failed to send reply"
        }
        val notification = NotificationCompat.Builder(context, CHANNEL_MESSAGES)
            .setSmallIcon(R.drawable.ic_stat_icon)
            .setContentTitle(title)
            .setContentText(replyText)
            .setContentIntent(tapPendingIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_ERROR)
            .build()

        manager.notify(notificationId, notification)
    }

    private fun postMessagingNotification(
        context: Context,
        manager: NotificationManager,
        chatGuid: String,
        senderName: String,
        senderPerson: Person,
        mePerson: Person,
        snapshot: List<NotificationCompat.MessagingStyle.Message>,
        isGroup: Boolean,
        groupTitle: String?,
        timestamp: Long,
        silent: Boolean,
        onlyAlertOnce: Boolean
    ) {
        val notificationId = chatGuid.hashCode()
        val style = NotificationCompat.MessagingStyle(mePerson)
        if (isGroup) {
            style.isGroupConversation = true
            if (!groupTitle.isNullOrBlank()) {
                style.conversationTitle = groupTitle
            }
        }
        snapshot.forEach { style.addMessage(it) }

        val encodedGuid = Uri.encode(chatGuid)

        val tapIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            data = Uri.parse("wearbubbles://chat/$encodedGuid/tap")
            putExtra(EXTRA_CHAT_GUID, chatGuid)
        }
        val tapPendingIntent = PendingIntent.getActivity(
            context,
            notificationId,
            tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val remoteInput = RemoteInput.Builder(KEY_TEXT_REPLY)
            .setLabel("Reply")
            .setChoices(QUICK_REPLY_CHOICES)
            .build()

        val replyIntent = Intent(context, ReplyReceiver::class.java).apply {
            action = ACTION_REPLY
            data = Uri.parse("wearbubbles://chat/$encodedGuid/reply")
            putExtra(EXTRA_CHAT_GUID, chatGuid)
            putExtra(EXTRA_SENDER_NAME, senderName)
        }
        val replyPendingIntent = PendingIntent.getBroadcast(
            context,
            notificationId + 1000,
            replyIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        )

        val replyAction = NotificationCompat.Action.Builder(
            android.R.drawable.ic_menu_send,
            "Reply",
            replyPendingIntent
        )
            .addRemoteInput(remoteInput)
            .setAllowGeneratedReplies(true)
            .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_REPLY)
            .setShowsUserInterface(false)
            .extend(
                NotificationCompat.Action.WearableExtender()
                    .setHintDisplayActionInline(true)
            )
            .build()

        val markReadIntent = Intent(context, MarkReadReceiver::class.java).apply {
            action = ACTION_MARK_READ
            data = Uri.parse("wearbubbles://chat/$encodedGuid/mark_read")
            putExtra(EXTRA_CHAT_GUID, chatGuid)
        }
        val markReadPendingIntent = PendingIntent.getBroadcast(
            context,
            notificationId + 3000,
            markReadIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val markReadAction = NotificationCompat.Action.Builder(
            android.R.drawable.ic_menu_agenda,
            "Mark as Read",
            markReadPendingIntent
        )
            .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_MARK_AS_READ)
            .setShowsUserInterface(false)
            .build()

        val dismissIntent = Intent(context, MarkReadReceiver::class.java).apply {
            action = ACTION_DISMISS
            data = Uri.parse("wearbubbles://chat/$encodedGuid/dismiss")
            putExtra(EXTRA_CHAT_GUID, chatGuid)
        }
        val dismissPendingIntent = PendingIntent.getBroadcast(
            context,
            notificationId + 4000,
            dismissIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val openOnPhoneIntent = Intent(context, OpenOnPhoneReceiver::class.java).apply {
            action = ACTION_OPEN_ON_PHONE
            data = Uri.parse("wearbubbles://chat/$encodedGuid/open_on_phone")
            putExtra(EXTRA_CHAT_GUID, chatGuid)
        }
        val openOnPhonePendingIntent = PendingIntent.getBroadcast(
            context,
            notificationId + 2000,
            openOnPhoneIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val openOnPhoneAction = NotificationCompat.Action.Builder(
            android.R.drawable.ic_menu_view,
            "Open on Phone",
            openOnPhonePendingIntent
        ).build()

        val publicNotification = NotificationCompat.Builder(context, CHANNEL_MESSAGES)
            .setSmallIcon(R.drawable.ic_stat_icon)
            .setContentTitle(context.getString(R.string.app_name_en))
            .setContentText("New message")
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .build()

        val notification = NotificationCompat.Builder(context, CHANNEL_MESSAGES)
            .setSmallIcon(R.drawable.ic_stat_icon)
            .setStyle(style)
            .addPerson(senderPerson)
            .setWhen(timestamp)
            .setShowWhen(true)
            .setContentIntent(tapPendingIntent)
            .setDeleteIntent(dismissPendingIntent)
            .setAutoCancel(true)
            .setSilent(silent)
            .setOnlyAlertOnce(onlyAlertOnce)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(publicNotification)
            .setGroup(GROUP_KEY_MESSAGES)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
            .setAllowSystemGeneratedContextualActions(true)
            .addAction(replyAction)
            .addAction(markReadAction)
            .addAction(openOnPhoneAction)
            .extend(
                NotificationCompat.WearableExtender()
                    .setBridgeTag(chatGuid)
                    .setDismissalId(chatGuid)
            )
            .build()

        manager.notify(notificationId, notification)

        val summary = NotificationCompat.Builder(context, CHANNEL_MESSAGES)
            .setSmallIcon(R.drawable.ic_stat_icon)
            .setContentTitle(context.getString(R.string.app_name_en))
            .setContentText("New messages")
            .setGroup(GROUP_KEY_MESSAGES)
            .setGroupSummary(true)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
            .setAutoCancel(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .build()
        manager.notify(SUMMARY_NOTIFICATION_ID, summary)
    }

    fun cancelNotification(context: Context, chatGuid: String) {
        clearConversationHistory(chatGuid)
        chatMetadata.remove(chatGuid)
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.cancel(chatGuid.hashCode())
        val notificationId = chatGuid.hashCode()
        val remaining = try {
            manager.activeNotifications.count {
                it.id != SUMMARY_NOTIFICATION_ID &&
                    it.id != notificationId &&
                    it.notification.group == GROUP_KEY_MESSAGES
            }
        } catch (_: Exception) {
            0
        }
        if (remaining == 0) {
            manager.cancel(SUMMARY_NOTIFICATION_ID)
        }
    }

    fun cancelAll(context: Context) {
        messageHistory.clear()
        chatMetadata.clear()
        personIconCache.evictAll()
        _activeChatGuid.value = null
        pendingLaunchChatGuid = null
        NotificationManagerCompat.from(context).cancelAll()
    }

    private fun recoverHistoryFromActive(
        manager: NotificationManager,
        notificationId: Int,
        target: MutableList<NotificationCompat.MessagingStyle.Message>
    ) {
        try {
            val active = manager.activeNotifications.firstOrNull { it.id == notificationId } ?: return
            val existingStyle = NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(
                active.notification
            ) ?: return
            target.addAll(existingStyle.messages.takeLast(5))
        } catch (_: Exception) {
        }
    }

    internal fun buildPersonUri(address: String?): String? {
        val trimmed = address?.trim()?.takeIf { it.isNotBlank() } ?: return null
        return if (trimmed.contains("@")) {
            "mailto:$trimmed"
        } else {
            "tel:$trimmed"
        }
    }

    internal fun buildPerson(
        name: String,
        address: String? = null,
        avatarPath: String? = null,
        important: Boolean = true
    ): Person {
        val builder = Person.Builder()
            .setName(name)
            .setKey(address?.takeIf { it.isNotBlank() } ?: name)
            .setImportant(important)
        buildPersonUri(address)?.let { builder.setUri(it) }
        val avatarMtime = avatarPath?.takeIf { it.isNotBlank() }?.let {
            File(it).takeIf { f -> f.exists() && f.length() > 0L }?.lastModified()
        } ?: 0L
        val iconKey = "${avatarPath.orEmpty()}|$avatarMtime|${address ?: name}|$name"
        val icon = personIconCache.get(iconKey)
            ?: (decodeAvatarIcon(avatarPath) ?: buildMonogramAvatarIcon(name, address ?: name))?.also {
                personIconCache.put(iconKey, it)
            }
        icon?.let { builder.setIcon(it) }
        return builder.build()
    }

    private fun buildMonogramAvatarIcon(name: String, seed: String): IconCompat? {
        val monogram = avatarMonogram(name) ?: return null
        return try {
            val size = 96
            val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val swatch = avatarSwatchFor(seed)
            val canvas = Canvas(bitmap)
            val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = swatch.container.toArgb()
            }
            canvas.drawCircle(size / 2f, size / 2f, size / 2f, bgPaint)

            val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = swatch.content.toArgb()
                textSize = size * 0.44f
                typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
                textAlign = Paint.Align.CENTER
            }
            val fm = textPaint.fontMetrics
            val baseline = size / 2f - (fm.ascent + fm.descent) / 2f
            canvas.drawText(monogram, size / 2f, baseline, textPaint)
            IconCompat.createWithBitmap(bitmap)
        } catch (_: Throwable) {
            null
        }
    }

    private fun decodeAvatarIcon(avatarPath: String?): IconCompat? {
        if (avatarPath.isNullOrBlank()) return null
        return try {
            val file = File(avatarPath)
            if (!file.exists() || file.length() <= 0L) return null
            val raw = BitmapFactory.decodeFile(file.absolutePath) ?: return null
            val scaled = if (raw.width > 128 || raw.height > 128) {
                Bitmap.createScaledBitmap(raw, 128, 128, true).also {
                    if (it !== raw) raw.recycle()
                }
            } else {
                raw
            }
            IconCompat.createWithBitmap(scaled)
        } catch (_: Exception) {
            null
        }
    }

    private fun resolveAttachmentUri(context: Context, attachmentPath: String): Uri? {
        return try {
            val file = File(attachmentPath)
            if (!file.exists() || file.length() <= 0L) return null
            val uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.wear.fileprovider",
                file
            )
            try {
                context.grantUriPermission(
                    "com.android.systemui",
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            } catch (_: Exception) {
            }
            uri
        } catch (_: Exception) {
            null
        }
    }
}
