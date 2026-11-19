package com.wearbubbles.notifications

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.content.ContextCompat

/**
 * Foreground service hosting active CallStyle ongoing call notifications on Android 14+ (API 34+).
 */
class CallForegroundService : Service() {

    companion object {
        @Volatile
        private var pendingNotification: Notification? = null

        fun start(context: Context, notification: Notification) {
            pendingNotification = notification
            ContextCompat.startForegroundService(
                context,
                Intent(context, CallForegroundService::class.java)
            )
        }

        fun stop(context: Context) {
            pendingNotification = null
            context.stopService(Intent(context, CallForegroundService::class.java))
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = pendingNotification
            ?: CallNotificationHelper.buildFallbackOngoingCallNotification(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NotificationHelper.CALL_NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
            )
        } else {
            startForeground(NotificationHelper.CALL_NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
