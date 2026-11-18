package com.wearbubbles.notifications

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.app.RemoteInput
import com.wearbubbles.MainActivity
import com.wearbubbles.R
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.concurrent.ConcurrentHashMap

object NotificationHelper {

    const val CHANNEL_MESSAGES = "messages"
    const val CHANNEL_SERVICE = "service"
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

    private val messageHistory = ConcurrentHashMap<String, MutableList<NotificationCompat.MessagingStyle.Message>>()

    fun setActiveChat(chatGuid: String?) {
        _activeChatGuid.value = chatGuid
        if (chatGuid != null) {
            clearConversationHistory(chatGuid)
        }
    }

    fun clearConversationHistory(chatGuid: String) {
        messageHistory.remove(chatGuid)
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

        manager.createNotificationChannel(messagesChannel)
        manager.createNotificationChannel(serviceChannel)
    }

    fun showMessageNotification(
        context: Context,
        chatGuid: String,
        senderName: String,
        messageText: String,
        isGroup: Boolean = false,
        groupTitle: String? = null,
        hapticEnabled: Boolean = true
    ) {
        if (_activeChatGuid.value == chatGuid) return

        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val notificationId = chatGuid.hashCode()

        val senderPerson = Person.Builder()
            .setName(senderName)
            .setKey(senderName)
            .setImportant(true)
            .build()

        val mePerson = Person.Builder()
            .setName("Me")
            .setKey("me")
            .build()

        val history = messageHistory.getOrPut(chatGuid) { mutableListOf() }
        val snapshot = synchronized(history) {
            history.add(
                NotificationCompat.MessagingStyle.Message(
                    messageText,
                    System.currentTimeMillis(),
                    senderPerson
                )
            )
            if (history.size > 6) {
                history.removeAt(0)
            }
            history.toList()
        }

        val style = NotificationCompat.MessagingStyle(mePerson)
        if (isGroup && !groupTitle.isNullOrBlank()) {
            style.conversationTitle = groupTitle
            style.isGroupConversation = true
        }
        snapshot.forEach { style.addMessage(it) }

        val tapIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
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
            .build()

        val markReadIntent = Intent(context, MarkReadReceiver::class.java).apply {
            action = ACTION_MARK_READ
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
            .setContentIntent(tapPendingIntent)
            .setDeleteIntent(dismissPendingIntent)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(publicNotification)
            .addAction(replyAction)
            .addAction(markReadAction)
            .addAction(openOnPhoneAction)
            .extend(NotificationCompat.WearableExtender().setDismissalId(chatGuid))
            .build()

        manager.notify(notificationId, notification)

        if (hapticEnabled) {
            vibrateDoublePulse(context)
        }
    }

    fun cancelNotification(context: Context, chatGuid: String) {
        clearConversationHistory(chatGuid)
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.cancel(chatGuid.hashCode())
    }

    fun vibrateDoublePulse(context: Context) {
        try {
            val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = context.getSystemService(VibratorManager::class.java)
                vm?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            }
            vibrator?.vibrate(
                VibrationEffect.createWaveform(longArrayOf(0, 120, 70, 120), -1)
            )
        } catch (_: Exception) {
        }
    }

    fun vibrateLightTick(context: Context) {
        try {
            val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = context.getSystemService(VibratorManager::class.java)
                vm?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            }
            vibrator?.vibrate(
                VibrationEffect.createOneShot(25, VibrationEffect.DEFAULT_AMPLITUDE)
            )
        } catch (_: Exception) {
        }
    }
}
