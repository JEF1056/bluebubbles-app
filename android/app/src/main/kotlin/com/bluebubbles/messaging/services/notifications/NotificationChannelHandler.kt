package com.bluebubbles.messaging.services.notifications

import android.app.NotificationChannel
import android.app.NotificationChannelGroup
import android.app.NotificationManager
import android.content.Context
import android.content.SharedPreferences
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.provider.Settings
import androidx.annotation.RequiresApi
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import com.bluebubbles.messaging.utils.PersistentLog
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class NotificationChannelHandler: MethodCallHandlerImpl() {
    companion object {
        const val tag: String = "create-notification-channel"
        const val NEW_MESSAGES_CHANNEL_ID = "com.bluebubbles.new_messages"
        const val FACETIME_CHANNEL_ID = "com.bluebubbles.incoming_facetimes"
        const val FOREGROUND_SERVICE_CHANNEL_ID = "com.bluebubbles.foreground_service"
        const val GROUP_MESSAGES = "com.bluebubbles.group.messages"
        const val GROUP_CALLS = "com.bluebubbles.group.calls"
        const val GROUP_OTHER = "com.bluebubbles.group.other"

        private const val PREFS_NAME = "notification_channel_prefs"
        private const val KEY_NEW_MESSAGES_VIBRATION_MIGRATED = "new_messages_vibration_migrated"
        private const val KEY_NEW_MESSAGES_DND_MIGRATED = "new_messages_dnd_migrated"
        private const val KEY_NEW_MESSAGES_AUDIO_MIGRATED = "new_messages_audio_migrated"
        private const val KEY_FACETIME_RINGTONE_MIGRATED = "facetime_ringtone_migrated"
        private const val KEY_FOREGROUND_MIN_MIGRATED = "foreground_min_migrated"

        internal fun shouldRecreateNewMessagesChannel(
            exists: Boolean,
            shouldVibrate: Boolean,
            vibrationMigrated: Boolean,
            canBypassDnd: Boolean,
            dndMigrated: Boolean
        ): Boolean {
            if (!exists) return false
            if (!shouldVibrate && !vibrationMigrated) return true
            if (canBypassDnd && !dndMigrated) return true
            return false
        }

        internal fun groupIdForChannel(channelId: String): String = when (channelId) {
            NEW_MESSAGES_CHANNEL_ID -> GROUP_MESSAGES
            FACETIME_CHANNEL_ID -> GROUP_CALLS
            else -> GROUP_OTHER
        }

        @RequiresApi(Build.VERSION_CODES.O)
        fun ensureChannelGroups(notificationManager: NotificationManager) {
            notificationManager.createNotificationChannelGroups(
                listOf(
                    NotificationChannelGroup(GROUP_MESSAGES, "Messages"),
                    NotificationChannelGroup(GROUP_CALLS, "Calls"),
                    NotificationChannelGroup(GROUP_OTHER, "Other")
                )
            )
        }

        fun instantCommunicationAudioAttributes(): AudioAttributes =
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_COMMUNICATION_INSTANT)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()

        fun ringtoneAudioAttributes(): AudioAttributes =
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()

        fun ensureForegroundServiceChannel(context: Context): String {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val manager = context.getSystemService(NotificationManager::class.java)
                ensureChannelGroups(manager)
                // Clean up the legacy SocketIO-only duplicate channel when unifying onto FOREGROUND_SERVICE_CHANNEL_ID.
                if (Constants.foregroundServiceNotificationChannel != FOREGROUND_SERVICE_CHANNEL_ID &&
                    manager.getNotificationChannel(Constants.foregroundServiceNotificationChannel) != null
                ) {
                    manager.deleteNotificationChannel(Constants.foregroundServiceNotificationChannel)
                }
                val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                val migrated = prefs.getBoolean(KEY_FOREGROUND_MIN_MIGRATED, false)
                val existing = manager.getNotificationChannel(FOREGROUND_SERVICE_CHANNEL_ID)
                if (existing != null && !migrated &&
                    (existing.importance != NotificationManager.IMPORTANCE_MIN || existing.canShowBadge())
                ) {
                    manager.deleteNotificationChannel(FOREGROUND_SERVICE_CHANNEL_ID)
                }
                if (!migrated) {
                    prefs.edit().putBoolean(KEY_FOREGROUND_MIN_MIGRATED, true).apply()
                }
                if (manager.getNotificationChannel(FOREGROUND_SERVICE_CHANNEL_ID) == null) {
                    val channel = NotificationChannel(
                        FOREGROUND_SERVICE_CHANNEL_ID,
                        "Foreground Service",
                        NotificationManager.IMPORTANCE_MIN
                    ).apply {
                        description = "Allows BlueBubbles to stay open in the background for notifications if FCM is not being used"
                        group = GROUP_OTHER
                        setShowBadge(false)
                        setSound(null, null)
                        enableVibration(false)
                    }
                    manager.createNotificationChannel(channel)
                }
            }
            return FOREGROUND_SERVICE_CHANNEL_ID
        }
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        try {
            // check if we are on a lower SDK
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                result.success(null)
                return
            }
            val notificationManager: NotificationManager = context.getSystemService(NotificationManager::class.java)
            ensureChannelGroups(notificationManager)
            val channelName: String = call.argument("channel_name")!!
            val channelDescription: String = call.argument("channel_description")!!
            val channelId: String = call.argument("channel_id")!!
            PersistentLog.d(context, Constants.logTag, "Creating channel with name $channelName")

            if (channelId == FOREGROUND_SERVICE_CHANNEL_ID) {
                ensureForegroundServiceChannel(context)
                result.success(null)
                return
            }

            val prefs: SharedPreferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            if (channelId == NEW_MESSAGES_CHANNEL_ID) {
                val vibrationMigrated = prefs.getBoolean(KEY_NEW_MESSAGES_VIBRATION_MIGRATED, false)
                val dndMigrated = prefs.getBoolean(KEY_NEW_MESSAGES_DND_MIGRATED, false)
                val audioMigrated = prefs.getBoolean(KEY_NEW_MESSAGES_AUDIO_MIGRATED, false)
                val existing = notificationManager.getNotificationChannel(channelId)
                val needsAudioMigration = existing != null && !audioMigrated &&
                    existing.audioAttributes?.usage != AudioAttributes.USAGE_NOTIFICATION_COMMUNICATION_INSTANT
                if (shouldRecreateNewMessagesChannel(
                        exists = existing != null,
                        shouldVibrate = existing?.shouldVibrate() ?: true,
                        vibrationMigrated = vibrationMigrated,
                        canBypassDnd = existing?.canBypassDnd() ?: false,
                        dndMigrated = dndMigrated
                    ) || needsAudioMigration
                ) {
                    PersistentLog.d(context, Constants.logTag, "Recreating new messages channel for one-time migration")
                    notificationManager.deleteNotificationChannel(channelId)
                    prefs.edit()
                        .putBoolean(KEY_NEW_MESSAGES_VIBRATION_MIGRATED, true)
                        .putBoolean(KEY_NEW_MESSAGES_DND_MIGRATED, true)
                        .putBoolean(KEY_NEW_MESSAGES_AUDIO_MIGRATED, true)
                        .apply()
                } else if (existing != null) {
                    if (!vibrationMigrated || !dndMigrated || !audioMigrated) {
                        prefs.edit()
                            .putBoolean(KEY_NEW_MESSAGES_VIBRATION_MIGRATED, true)
                            .putBoolean(KEY_NEW_MESSAGES_DND_MIGRATED, true)
                            .putBoolean(KEY_NEW_MESSAGES_AUDIO_MIGRATED, true)
                            .apply()
                    }
                    PersistentLog.d(context, Constants.logTag, "Notification channel already exists! Ignoring...")
                    result.success(null)
                    return
                }
            } else if (channelId == FACETIME_CHANNEL_ID) {
                val ringtoneMigrated = prefs.getBoolean(KEY_FACETIME_RINGTONE_MIGRATED, false)
                val existing = notificationManager.getNotificationChannel(channelId)
                if (existing != null && !ringtoneMigrated &&
                    existing.audioAttributes?.usage != AudioAttributes.USAGE_NOTIFICATION_RINGTONE
                ) {
                    PersistentLog.d(context, Constants.logTag, "Recreating facetime channel for ringtone audio attributes")
                    notificationManager.deleteNotificationChannel(channelId)
                    prefs.edit().putBoolean(KEY_FACETIME_RINGTONE_MIGRATED, true).apply()
                } else if (existing != null) {
                    if (!ringtoneMigrated) {
                        prefs.edit().putBoolean(KEY_FACETIME_RINGTONE_MIGRATED, true).apply()
                    }
                    PersistentLog.d(context, Constants.logTag, "Notification channel already exists! Ignoring...")
                    result.success(null)
                    return
                }
            } else if (notificationManager.getNotificationChannel(channelId) != null) {
                PersistentLog.d(context, Constants.logTag, "Notification channel already exists! Ignoring...")
                result.success(null)
                return
            }

            // setup channel with parameters
            val channel = NotificationChannel(channelId, channelName, NotificationManager.IMPORTANCE_HIGH)
            channel.description = channelDescription
            channel.group = groupIdForChannel(channelId)
            if (channelId == NEW_MESSAGES_CHANNEL_ID) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    channel.setAllowBubbles(true)
                }
                channel.setShowBadge(true)
                channel.enableVibration(true)
                channel.setSound(Settings.System.DEFAULT_NOTIFICATION_URI, instantCommunicationAudioAttributes())
            } else if (channelId == FACETIME_CHANNEL_ID) {
                channel.enableVibration(true)
                channel.setSound(
                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
                    ringtoneAudioAttributes()
                )
            }
            // create the channel
            notificationManager.createNotificationChannel(channel)
            result.success(null)
        } catch (e: Exception) {
            PersistentLog.e(context, Constants.logTag, "Failed to create notification channel", e)
            result.error("500", "Failed to create notification channel", e.message)
        }
    }
}