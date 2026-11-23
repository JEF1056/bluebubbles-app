package com.wearbubbles.notifications

import android.app.NotificationManager
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.util.Log

internal enum class WearAlertMode {
    NONE,
    VIBRATE_ONLY,
    RING_AND_VIBRATE
}

object WearCallTonePlayer {
    private const val TAG = "WearCallTonePlayer"
    private const val RINGTONE_FALLBACK_POLL_MS = 500L
    internal val RING_VIBRATION_PATTERN = longArrayOf(0, 1000, 1000)

    private val toneThread: HandlerThread by lazy {
        HandlerThread("WearBubblesCallTones").apply { start() }
    }
    private val toneHandler: Handler by lazy { Handler(toneThread.looper) }

    // Accessed exclusively on toneHandler; volatile for fast-path stop checks when idle.
    @Volatile
    private var activeCallUuid: String? = null
    private var activeRingtone: Ringtone? = null
    private var activeVibrator: Vibrator? = null

    private val ringTimeoutRunnable = Runnable {
        stopIncomingRingInternal(null)
    }

    private val ringtoneLoopRunnable: Runnable = object : Runnable {
        override fun run() {
            val ringtone = activeRingtone ?: return
            if (activeCallUuid == null) return
            runCatching {
                if (!ringtone.isPlaying) {
                    ringtone.play()
                }
            }
            toneHandler.postDelayed(this, RINGTONE_FALLBACK_POLL_MS)
        }
    }

    internal fun shouldAllowByDnd(
        interruptionFilter: Int,
        priorityCategories: Int,
        priorityCallSenders: Int
    ): Boolean {
        return when (interruptionFilter) {
            NotificationManager.INTERRUPTION_FILTER_UNKNOWN,
            NotificationManager.INTERRUPTION_FILTER_ALL -> true
            NotificationManager.INTERRUPTION_FILTER_PRIORITY -> {
                val callsAllowed = (priorityCategories and NotificationManager.Policy.PRIORITY_CATEGORY_CALLS) != 0
                callsAllowed && priorityCallSenders == NotificationManager.Policy.PRIORITY_SENDERS_ANY
            }
            else -> false
        }
    }

    internal fun resolveAlertMode(
        ringerMode: Int,
        dndAllows: Boolean
    ): WearAlertMode {
        if (!dndAllows || ringerMode == AudioManager.RINGER_MODE_SILENT) {
            return WearAlertMode.NONE
        }
        return when (ringerMode) {
            AudioManager.RINGER_MODE_VIBRATE -> WearAlertMode.VIBRATE_ONLY
            AudioManager.RINGER_MODE_NORMAL -> WearAlertMode.RING_AND_VIBRATE
            else -> WearAlertMode.NONE
        }
    }

    fun startIncomingRing(context: Context, callUuid: String) {
        if (callUuid.isBlank()) return
        val appCtx = context.applicationContext ?: context
        toneHandler.post {
            startIncomingRingInternal(appCtx, callUuid)
        }
    }

    fun stopIncomingRing(callUuid: String? = null) {
        if (activeCallUuid == null) return
        toneHandler.post {
            stopIncomingRingInternal(callUuid)
        }
    }

    private fun startIncomingRingInternal(appCtx: Context, callUuid: String) {
        if (activeCallUuid == callUuid) return
        if (activeCallUuid != null) {
            stopIncomingRingInternal(null)
        }

        val nm = appCtx.getSystemService(NotificationManager::class.java)
        val filter = nm?.currentInterruptionFilter ?: NotificationManager.INTERRUPTION_FILTER_ALL
        val policy = try {
            nm?.notificationPolicy
        } catch (_: SecurityException) {
            null
        }
        val dndAllows = shouldAllowByDnd(
            interruptionFilter = filter,
            priorityCategories = policy?.priorityCategories ?: 0,
            priorityCallSenders = policy?.priorityCallSenders ?: NotificationManager.Policy.PRIORITY_SENDERS_STARRED
        )
        val am = appCtx.getSystemService(AudioManager::class.java)
        val ringerMode = am?.ringerMode ?: AudioManager.RINGER_MODE_NORMAL
        val mode = resolveAlertMode(ringerMode = ringerMode, dndAllows = dndAllows)
        if (mode == WearAlertMode.NONE) return

        activeCallUuid = callUuid
        toneHandler.removeCallbacks(ringTimeoutRunnable)
        toneHandler.postDelayed(ringTimeoutRunnable, CallNotificationHelper.RING_TIMEOUT_MS)

        if (mode == WearAlertMode.RING_AND_VIBRATE) {
            startRingtone(appCtx)
        }
        startVibration(appCtx)
    }

    private fun stopIncomingRingInternal(callUuid: String?) {
        if (callUuid != null && activeCallUuid != null && activeCallUuid != callUuid) {
            return
        }
        toneHandler.removeCallbacks(ringTimeoutRunnable)
        toneHandler.removeCallbacks(ringtoneLoopRunnable)

        activeRingtone?.let { ringtone ->
            runCatching { ringtone.stop() }
        }
        activeRingtone = null

        activeVibrator?.let { vibrator ->
            runCatching { vibrator.cancel() }
        }
        activeVibrator = null
        activeCallUuid = null
    }

    private fun startRingtone(context: Context) {
        try {
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                ?: Settings.System.DEFAULT_RINGTONE_URI
                ?: return
            val ringtone = RingtoneManager.getRingtone(context, uri) ?: return
            ringtone.audioAttributes = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                ringtone.isLooping = true
            }
            ringtone.play()
            activeRingtone = ringtone
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
                toneHandler.postDelayed(ringtoneLoopRunnable, RINGTONE_FALLBACK_POLL_MS)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "Failed to start wear ringtone: ${t.message}")
        }
    }

    private fun startVibration(context: Context) {
        try {
            val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                context.getSystemService(VibratorManager::class.java)?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(Vibrator::class.java)
            } ?: return
            if (!vibrator.hasVibrator()) return

            val effect = VibrationEffect.createWaveform(RING_VIBRATION_PATTERN, 0)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val attrs = VibrationAttributes.Builder()
                    .setUsage(VibrationAttributes.USAGE_RINGTONE)
                    .build()
                vibrator.vibrate(effect, attrs)
            } else {
                @Suppress("DEPRECATION")
                val attrs = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
                @Suppress("DEPRECATION")
                vibrator.vibrate(effect, attrs)
            }
            activeVibrator = vibrator
        } catch (t: Throwable) {
            Log.w(TAG, "Failed to start wear ring vibration: ${t.message}")
        }
    }
}
