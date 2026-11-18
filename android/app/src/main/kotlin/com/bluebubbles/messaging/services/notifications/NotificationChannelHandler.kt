package com.bluebubbles.messaging.services.notifications

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import com.bluebubbles.messaging.utils.PersistentLog
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class NotificationChannelHandler: MethodCallHandlerImpl() {
    companion object {
        const val tag: String = "create-notification-channel"
        private const val PREFS_NAME = "notification_channel_prefs"
        private const val KEY_NEW_MESSAGES_VIBRATION_MIGRATED = "new_messages_vibration_migrated"
        private const val KEY_NEW_MESSAGES_DND_MIGRATED = "new_messages_dnd_migrated"

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
            val channelName: String = call.argument("channel_name")!!
            val channelDescription: String = call.argument("channel_description")!!
            val channelId: String = call.argument("channel_id")!!
            PersistentLog.d(context, Constants.logTag, "Creating channel with name $channelName")
            
            // Perform one-time migrations for the 'New Messages' channel:
            // 1. Vibration wasn't explicitly enabled previously.
            // 2. Hardcoded setBypassDnd(true) broke DND contact breakthrough; recreate once to clear it.
            if (channelId == "com.bluebubbles.new_messages") {
                val prefs: SharedPreferences = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                val vibrationMigrated = prefs.getBoolean(KEY_NEW_MESSAGES_VIBRATION_MIGRATED, false)
                val dndMigrated = prefs.getBoolean(KEY_NEW_MESSAGES_DND_MIGRATED, false)
                val existing = notificationManager.getNotificationChannel(channelId)
                if (shouldRecreateNewMessagesChannel(
                        exists = existing != null,
                        shouldVibrate = existing?.shouldVibrate() ?: true,
                        vibrationMigrated = vibrationMigrated,
                        canBypassDnd = existing?.canBypassDnd() ?: false,
                        dndMigrated = dndMigrated
                    )
                ) {
                    PersistentLog.d(context, Constants.logTag, "Recreating new messages channel for one-time vibration/DND migration")
                    notificationManager.deleteNotificationChannel(channelId)
                    prefs.edit()
                        .putBoolean(KEY_NEW_MESSAGES_VIBRATION_MIGRATED, true)
                        .putBoolean(KEY_NEW_MESSAGES_DND_MIGRATED, true)
                        .apply()
                } else if (existing != null) {
                    if (!vibrationMigrated || !dndMigrated) {
                        prefs.edit()
                            .putBoolean(KEY_NEW_MESSAGES_VIBRATION_MIGRATED, true)
                            .putBoolean(KEY_NEW_MESSAGES_DND_MIGRATED, true)
                            .apply()
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
            // set the 'New Messages' channel to allow bubbling and showing badges (let DND contact breakthrough handle DND)
            if (channelId == "com.bluebubbles.new_messages") {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    channel.setAllowBubbles(true)
                }
                channel.setShowBadge(true)
                channel.enableVibration(true)
            // set 'Foreground Service' channel to low importance (avoid heads-up notification)
            } else if (channelId == "com.bluebubbles.foreground_service") {
                channel.importance = NotificationManager.IMPORTANCE_LOW
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