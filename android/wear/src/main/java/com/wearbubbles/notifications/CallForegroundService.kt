package com.wearbubbles.notifications

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import androidx.core.content.ContextCompat

/**
 * Foreground service hosting active CallStyle ongoing call notifications on Android 14+ (API 34+).
 */
class CallForegroundService : Service() {

    companion object {
        private const val EXTRA_CALL_UUID = "extra_call_uuid"
        private const val EXTRA_CALLER_NAME = "extra_caller_name"
        private const val EXTRA_CALLER_ADDRESS = "extra_caller_address"
        private const val EXTRA_STARTED_AT_ELAPSED_MS = "extra_started_at_elapsed_ms"
        private const val EXTRA_AVATAR_PATH = "extra_avatar_path"
        private const val EXTRA_IS_TELEPHONY = "extra_is_telephony"
        private const val EXTRA_FROM_PHONE_RELAY = "extra_from_phone_relay"

        fun start(context: Context, state: ActiveCallState) {
            val intent = Intent(context, CallForegroundService::class.java).apply {
                putExtra(EXTRA_CALL_UUID, state.callUuid)
                putExtra(EXTRA_CALLER_NAME, state.callerName)
                putExtra(EXTRA_CALLER_ADDRESS, state.callerAddress)
                putExtra(EXTRA_STARTED_AT_ELAPSED_MS, state.startedAtElapsedMs)
                putExtra(EXTRA_AVATAR_PATH, state.avatarPath)
                putExtra(EXTRA_IS_TELEPHONY, state.isTelephony)
                putExtra(EXTRA_FROM_PHONE_RELAY, state.fromPhoneRelay)
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CallForegroundService::class.java))
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val state = stateFromIntent(intent) ?: CallNotificationHelper.activeCallState.value
        val notification = if (state != null) {
            CallNotificationHelper.buildOngoingCallNotification(this, state, useCallStyle = true)
        } else {
            CallNotificationHelper.buildFallbackOngoingCallNotification(this)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NotificationHelper.CALL_NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
            )
        } else {
            startForeground(NotificationHelper.CALL_NOTIFICATION_ID, notification)
        }
        if (state == null) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun stateFromIntent(intent: Intent?): ActiveCallState? {
        val uuid = intent?.getStringExtra(EXTRA_CALL_UUID)?.takeIf { it.isNotBlank() } ?: return null
        return ActiveCallState(
            callUuid = uuid,
            callerName = intent.getStringExtra(EXTRA_CALLER_NAME) ?: "FaceTime Call",
            callerAddress = intent.getStringExtra(EXTRA_CALLER_ADDRESS) ?: "",
            isVideo = false,
            fromPhoneRelay = intent.getBooleanExtra(EXTRA_FROM_PHONE_RELAY, false),
            phase = CallPhase.ONGOING,
            startedAtElapsedMs = intent.getLongExtra(EXTRA_STARTED_AT_ELAPSED_MS, SystemClock.elapsedRealtime()),
            avatarPath = intent.getStringExtra(EXTRA_AVATAR_PATH),
            isTelephony = intent.getBooleanExtra(EXTRA_IS_TELEPHONY, false)
        )
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
