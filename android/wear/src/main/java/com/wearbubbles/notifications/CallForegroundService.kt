package com.wearbubbles.notifications

import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Foreground service hosting active CallStyle ongoing call notifications on Android 14+ (API 34+).
 */
class CallForegroundService : Service() {

    companion object {
        private const val TAG = "CallForegroundService"
        private const val EXTRA_CALL_UUID = "extra_call_uuid"
        private const val EXTRA_CALLER_NAME = "extra_caller_name"
        private const val EXTRA_CALLER_ADDRESS = "extra_caller_address"
        private const val EXTRA_STARTED_AT_ELAPSED_MS = "extra_started_at_elapsed_ms"
        private const val EXTRA_AVATAR_PATH = "extra_avatar_path"
        private const val EXTRA_IS_VIDEO = "extra_is_video"
        private const val EXTRA_IS_TELEPHONY = "extra_is_telephony"
        private const val EXTRA_IS_GROUP = "extra_is_group"
        private const val EXTRA_FROM_PHONE_RELAY = "extra_from_phone_relay"
        private const val EXTRA_MUTED = "extra_muted"

        @Volatile
        internal var isForegroundStarted: Boolean = false

        fun start(context: Context, state: ActiveCallState) {
            val intent = Intent(context, CallForegroundService::class.java).apply {
                putExtra(EXTRA_CALL_UUID, state.callUuid)
                putExtra(EXTRA_CALLER_NAME, state.callerName)
                putExtra(EXTRA_CALLER_ADDRESS, state.callerAddress)
                putExtra(EXTRA_STARTED_AT_ELAPSED_MS, state.startedAtElapsedMs)
                putExtra(EXTRA_AVATAR_PATH, state.avatarPath)
                putExtra(EXTRA_IS_VIDEO, state.isVideo)
                putExtra(EXTRA_IS_TELEPHONY, state.isTelephony)
                putExtra(EXTRA_IS_GROUP, state.isGroup)
                putExtra(EXTRA_FROM_PHONE_RELAY, state.fromPhoneRelay)
                putExtra(EXTRA_MUTED, state.muted)
            }
            ContextCompat.startForegroundService(context, intent)
        }

        internal fun shouldStopService(): Boolean = isForegroundStarted

        fun stop(context: Context) {
            if (!shouldStopService()) return
            context.stopService(Intent(context, CallForegroundService::class.java))
        }

        internal fun resolveOngoingState(
            activeState: ActiveCallState?,
            intentUuid: String?
        ): ActiveCallState? = activeState?.takeIf {
            it.phase == CallPhase.ONGOING && (intentUuid.isNullOrBlank() || it.callUuid == intentUuid)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val intentUuid = intent?.getStringExtra(EXTRA_CALL_UUID)?.takeIf { it.isNotBlank() }
        val state = resolveOngoingState(CallNotificationHelper.activeCallState.value, intentUuid)
        val notification = if (state != null) {
            CallNotificationHelper.buildOngoingCallNotification(this, state, useCallStyle = true)
        } else {
            CallNotificationHelper.buildFallbackOngoingCallNotification(this)
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NotificationHelper.CALL_NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
                )
            } else {
                startForeground(NotificationHelper.CALL_NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.w(TAG, "startForeground blocked for call FGS, falling back to non-CallStyle notify: ${e.message}")
            if (state != null && NotificationHelper.canPostNotifications(this)) {
                try {
                    val fallback = CallNotificationHelper.buildOngoingCallNotification(this, state, useCallStyle = false)
                    getSystemService(NotificationManager::class.java)
                        ?.notify(NotificationHelper.CALL_NOTIFICATION_ID, fallback)
                } catch (notifyErr: Exception) {
                    Log.w(TAG, "Fallback ongoing call notify failed: ${notifyErr.message}")
                }
            }
            stopSelf()
            return START_NOT_STICKY
        }
        if (state == null || resolveOngoingState(CallNotificationHelper.activeCallState.value, intentUuid) == null) {
            isForegroundStarted = false
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        } else {
            isForegroundStarted = true
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        isForegroundStarted = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
