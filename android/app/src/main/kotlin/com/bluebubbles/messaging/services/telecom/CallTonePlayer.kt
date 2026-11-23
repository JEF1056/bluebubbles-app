package com.bluebubbles.messaging.services.telecom

import android.app.NotificationManager
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
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
import android.telecom.DisconnectCause
import com.bluebubbles.messaging.services.notifications.CreateIncomingFaceTimeNotification
import com.bluebubbles.messaging.utils.PersistentLog
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.roundToInt
import kotlin.math.sin

internal enum class IncomingAlertMode {
    NONE,
    VIBRATE_ONLY,
    RING_ONLY,
    RING_AND_VIBRATE,
    CALL_WAITING_TONE
}

object CallTonePlayer {
    private const val TAG = "CallTonePlayer"
    internal const val SAMPLE_RATE = 16_000
    private const val INCOMING_RING_TIMEOUT_MS = CreateIncomingFaceTimeNotification.INCOMING_CALL_TIMEOUT_MS
    private const val OUTGOING_RINGBACK_TIMEOUT_MS = 90_000L
    private const val RINGTONE_FALLBACK_POLL_MS = 500L
    private const val CALL_WAITING_REPEAT_MS = 3_500L
    private const val CALL_ENDED_RELEASE_DELAY_MS = 460L
    private const val CALL_WAITING_RELEASE_DELAY_MS = 450L

    // Matches Google Phone (Dialer) ramping ring vibration cadence (vgi.a).
    private val RAMPING_VIBRATION_TIMINGS = longArrayOf(
        0, 12, 250, 12, 500,
        50, 50, 50, 50, 50, 50, 50, 50, 50, 50, 50, 50, 50, 50,
        300, 1000
    )
    private val RAMPING_VIBRATION_AMPLITUDES = intArrayOf(
        0, 255, 0, 255, 0,
        77, 77, 78, 79, 81, 84, 87, 93, 102, 114, 133, 162, 205, 255,
        255, 0
    )
    private const val RAMPING_VIBRATION_REPEAT = 5
    private val FALLBACK_VIBRATION_TIMINGS = longArrayOf(0, 1000, 1000)

    private val toneThread: HandlerThread by lazy {
        HandlerThread("BlueBubblesCallTones").apply { start() }
    }
    private val toneHandler: Handler by lazy { Handler(toneThread.looper) }

    private val ringbackPcm: ShortArray by lazy { synthesizeRingbackPcm(SAMPLE_RATE) }
    private val callEndedPcm: ShortArray by lazy { synthesizeCallEndedPcm(SAMPLE_RATE) }
    private val callWaitingPcm: ShortArray by lazy { synthesizeCallWaitingPcm(SAMPLE_RATE) }

    @Volatile
    private var incomingRingingFlag: Boolean = false

    // Accessed exclusively on toneHandler.
    private var activeIncomingUuid: String? = null
    private var activeRingtone: Ringtone? = null
    private var activeVibrator: Vibrator? = null
    private var activeWaitingTrack: AudioTrack? = null
    private var activeRingbackToken: String? = null
    private var activeRingbackTrack: AudioTrack? = null
    private var activeEndedTrack: AudioTrack? = null

    private val incomingTimeoutRunnable = Runnable {
        stopIncomingRingInternal(null)
    }
    private val ringbackTimeoutRunnable = Runnable {
        stopOutgoingRingbackInternal(null)
    }
    private val endedReleaseRunnable = Runnable {
        releaseAudioTrack(activeEndedTrack)
        activeEndedTrack = null
    }
    private val waitingReleaseRunnable = Runnable {
        releaseAudioTrack(activeWaitingTrack)
        activeWaitingTrack = null
    }
    private val ringtoneLoopRunnable: Runnable = object : Runnable {
        override fun run() {
            val ringtone = activeRingtone ?: return
            if (activeIncomingUuid == null) return
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

    internal fun resolveIncomingAlertMode(
        ringerMode: Int,
        dndAllows: Boolean,
        vibrateWhenRinging: Boolean,
        callInProgress: Boolean
    ): IncomingAlertMode {
        if (!dndAllows || ringerMode == AudioManager.RINGER_MODE_SILENT) {
            return IncomingAlertMode.NONE
        }
        if (callInProgress) {
            return IncomingAlertMode.CALL_WAITING_TONE
        }
        return when (ringerMode) {
            AudioManager.RINGER_MODE_VIBRATE -> IncomingAlertMode.VIBRATE_ONLY
            AudioManager.RINGER_MODE_NORMAL ->
                if (vibrateWhenRinging) IncomingAlertMode.RING_AND_VIBRATE else IncomingAlertMode.RING_ONLY
            else -> IncomingAlertMode.NONE
        }
    }

    internal fun shouldPlayCallEndedTone(wasDialingOrActive: Boolean, causeCode: Int): Boolean {
        if (!wasDialingOrActive) return false
        return when (causeCode) {
            DisconnectCause.REMOTE,
            DisconnectCause.LOCAL,
            DisconnectCause.ERROR,
            DisconnectCause.BUSY,
            DisconnectCause.MISSED -> true
            else -> false
        }
    }

    internal fun synthesizeRingbackPcm(sampleRate: Int = SAMPLE_RATE): ShortArray {
        val totalSamples = sampleRate * 6
        val leadInSamples = (sampleRate * 0.25).roundToInt()
        val toneSamples = sampleRate * 2
        val fadeSamples = (sampleRate * 0.015).roundToInt().coerceAtLeast(1)
        val peak = 0.18 * Short.MAX_VALUE
        val out = ShortArray(totalSamples)
        for (i in 0 until toneSamples) {
            val env = when {
                i < fadeSamples -> 0.5 * (1.0 - cos(PI * i / fadeSamples))
                i >= toneSamples - fadeSamples -> 0.5 * (1.0 - cos(PI * (toneSamples - 1 - i) / fadeSamples))
                else -> 1.0
            }
            val t = i.toDouble() / sampleRate
            val wave = 0.5 * (sin(2.0 * PI * 440.0 * t) + sin(2.0 * PI * 480.0 * t))
            out[leadInSamples + i] = (wave * env * peak).roundToInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
        }
        return out
    }

    internal fun synthesizeCallEndedPcm(sampleRate: Int = SAMPLE_RATE): ShortArray {
        val note1Samples = (sampleRate * 0.130).roundToInt()
        val gapSamples = (sampleRate * 0.030).roundToInt()
        val note2Samples = (sampleRate * 0.180).roundToInt()
        val fadeSamples = (sampleRate * 0.005).roundToInt().coerceAtLeast(1)
        val peak = 0.15 * Short.MAX_VALUE
        val out = ShortArray(note1Samples + gapSamples + note2Samples)

        for (i in 0 until note1Samples) {
            val t = i.toDouble() / sampleRate
            val attack = if (i < fadeSamples) 0.5 * (1.0 - cos(PI * i / fadeSamples)) else 1.0
            val tail = if (i >= note1Samples - fadeSamples) 0.5 * (1.0 - cos(PI * (note1Samples - 1 - i) / fadeSamples)) else 1.0
            val decay = exp(-4.5 * i / note1Samples)
            val sample = sin(2.0 * PI * 480.0 * t) * attack * tail * decay * peak
            out[i] = sample.roundToInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
        }

        val note2Offset = note1Samples + gapSamples
        for (i in 0 until note2Samples) {
            val t = i.toDouble() / sampleRate
            val attack = if (i < fadeSamples) 0.5 * (1.0 - cos(PI * i / fadeSamples)) else 1.0
            val tail = if (i >= note2Samples - fadeSamples) 0.5 * (1.0 - cos(PI * (note2Samples - 1 - i) / fadeSamples)) else 1.0
            val decay = exp(-4.0 * i / note2Samples)
            val sample = sin(2.0 * PI * 360.0 * t) * attack * tail * decay * peak
            out[note2Offset + i] = sample.roundToInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt()).toShort()
        }
        return out
    }

    private fun synthesizeCallWaitingPcm(sampleRate: Int = SAMPLE_RATE): ShortArray {
        val beepSamples = (sampleRate * 0.110).roundToInt()
        val gapSamples = (sampleRate * 0.080).roundToInt()
        val fadeSamples = (sampleRate * 0.010).roundToInt().coerceAtLeast(1)
        val peak = 0.12 * Short.MAX_VALUE
        val out = ShortArray(beepSamples * 2 + gapSamples)
        for (beepIndex in 0..1) {
            val offset = beepIndex * (beepSamples + gapSamples)
            for (i in 0 until beepSamples) {
                val env = when {
                    i < fadeSamples -> 0.5 * (1.0 - cos(PI * i / fadeSamples))
                    i >= beepSamples - fadeSamples -> 0.5 * (1.0 - cos(PI * (beepSamples - 1 - i) / fadeSamples))
                    else -> 1.0
                }
                val t = i.toDouble() / sampleRate
                out[offset + i] = (sin(2.0 * PI * 440.0 * t) * env * peak)
                    .roundToInt()
                    .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                    .toShort()
            }
        }
        return out
    }

    fun isIncomingRinging(): Boolean = incomingRingingFlag

    fun startIncomingRing(
        context: Context,
        callUuid: String,
        isCallInProgress: Boolean = false
    ) {
        if (callUuid.isBlank()) return
        val appCtx = context.applicationContext ?: context
        toneHandler.post {
            startIncomingRingInternal(appCtx, callUuid, isCallInProgress)
        }
    }

    fun stopIncomingRing(callUuid: String? = null) {
        toneHandler.post {
            stopIncomingRingInternal(callUuid)
        }
    }

    fun startOutgoingRingback(context: Context, token: String) {
        if (token.isBlank()) return
        val appCtx = context.applicationContext ?: context
        toneHandler.post {
            startOutgoingRingbackInternal(appCtx, token)
        }
    }

    fun stopOutgoingRingback(token: String? = null) {
        toneHandler.post {
            stopOutgoingRingbackInternal(token)
        }
    }

    fun playCallEndedTone(context: Context) {
        val appCtx = context.applicationContext ?: context
        toneHandler.post {
            playCallEndedToneInternal(appCtx)
        }
    }

    private fun startIncomingRingInternal(
        appCtx: Context,
        callUuid: String,
        isCallInProgress: Boolean
    ) {
        if (activeIncomingUuid == callUuid) return
        if (activeIncomingUuid != null) {
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
        val vibrateWhenRinging = readVibrateWhenRinging(appCtx)
        val mode = resolveIncomingAlertMode(
            ringerMode = ringerMode,
            dndAllows = dndAllows,
            vibrateWhenRinging = vibrateWhenRinging,
            callInProgress = isCallInProgress
        )
        if (mode == IncomingAlertMode.NONE) return

        activeIncomingUuid = callUuid
        incomingRingingFlag = true
        toneHandler.removeCallbacks(incomingTimeoutRunnable)
        toneHandler.postDelayed(incomingTimeoutRunnable, INCOMING_RING_TIMEOUT_MS)

        if (mode == IncomingAlertMode.CALL_WAITING_TONE) {
            playCallWaitingBeep(appCtx, callUuid)
            return
        }

        if (mode == IncomingAlertMode.RING_ONLY || mode == IncomingAlertMode.RING_AND_VIBRATE) {
            startSystemRingtone(appCtx)
        }
        if (mode == IncomingAlertMode.VIBRATE_ONLY || mode == IncomingAlertMode.RING_AND_VIBRATE) {
            startRingVibration(appCtx)
        }
    }

    private fun stopIncomingRingInternal(callUuid: String?) {
        if (callUuid != null && activeIncomingUuid != null && activeIncomingUuid != callUuid) {
            return
        }
        toneHandler.removeCallbacks(incomingTimeoutRunnable)
        toneHandler.removeCallbacks(ringtoneLoopRunnable)
        toneHandler.removeCallbacks(waitingReleaseRunnable)
        toneHandler.removeCallbacksAndMessages(CALL_WAITING_CALLBACK_TOKEN)

        activeRingtone?.let { ringtone ->
            runCatching { ringtone.stop() }
        }
        activeRingtone = null

        activeVibrator?.let { vibrator ->
            runCatching { vibrator.cancel() }
        }
        activeVibrator = null

        releaseAudioTrack(activeWaitingTrack)
        activeWaitingTrack = null

        activeIncomingUuid = null
        incomingRingingFlag = false
    }

    private fun readVibrateWhenRinging(context: Context): Boolean {
        return try {
            val cr = context.contentResolver
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val intensity = Settings.System.getInt(cr, "ring_vibration_intensity", -1)
                if (intensity >= 0) {
                    return intensity > 0
                }
            }
            @Suppress("DEPRECATION")
            val legacy = Settings.System.getInt(cr, Settings.System.VIBRATE_WHEN_RINGING, -1)
            if (legacy >= 0) {
                return legacy != 0
            }
            // Default to true when neither setting is explicitly stored (e.g. fresh Android 13+ devices).
            true
        } catch (_: Exception) {
            true
        }
    }

    private fun startSystemRingtone(context: Context) {
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
            PersistentLog.w(context, TAG, "Failed to start system ringtone: ${t.message}")
        }
    }

    private fun startRingVibration(context: Context) {
        try {
            val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                context.getSystemService(VibratorManager::class.java)?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(Vibrator::class.java)
            } ?: return
            if (!vibrator.hasVibrator()) return

            val effect = if (vibrator.hasAmplitudeControl()) {
                VibrationEffect.createWaveform(RAMPING_VIBRATION_TIMINGS, RAMPING_VIBRATION_AMPLITUDES, RAMPING_VIBRATION_REPEAT)
            } else {
                VibrationEffect.createWaveform(FALLBACK_VIBRATION_TIMINGS, 0)
            }

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
            PersistentLog.w(context, TAG, "Failed to start ring vibration: ${t.message}")
        }
    }

    private val CALL_WAITING_CALLBACK_TOKEN = Any()

    private fun playCallWaitingBeep(context: Context, callUuid: String) {
        if (activeIncomingUuid != callUuid) return
        toneHandler.removeCallbacks(waitingReleaseRunnable)
        releaseAudioTrack(activeWaitingTrack)
        activeWaitingTrack = buildStaticSignallingTrack(context, callWaitingPcm, loop = false)?.also { track ->
            runCatching { track.play() }
            toneHandler.postDelayed(waitingReleaseRunnable, CALL_WAITING_RELEASE_DELAY_MS)
        }
        toneHandler.postDelayed(
            { playCallWaitingBeep(context, callUuid) },
            CALL_WAITING_CALLBACK_TOKEN,
            CALL_WAITING_REPEAT_MS
        )
    }

    private fun startOutgoingRingbackInternal(appCtx: Context, token: String) {
        if (activeRingbackToken == token && activeRingbackTrack != null) return
        stopOutgoingRingbackInternal(null)

        val track = buildStaticSignallingTrack(appCtx, ringbackPcm, loop = true) ?: return
        val started = runCatching {
            track.play()
            true
        }.getOrElse { t ->
            PersistentLog.w(appCtx, TAG, "Failed to play outgoing ringback: ${t.message}")
            releaseAudioTrack(track)
            false
        }
        if (!started) return

        activeRingbackToken = token
        activeRingbackTrack = track
        toneHandler.removeCallbacks(ringbackTimeoutRunnable)
        toneHandler.postDelayed(ringbackTimeoutRunnable, OUTGOING_RINGBACK_TIMEOUT_MS)
    }

    private fun stopOutgoingRingbackInternal(token: String?) {
        // Non-Telecom fallback calls may start ringback with "dart-ringback" before UUID assignment.
        if (token != null && activeRingbackToken != null &&
            activeRingbackToken != token && activeRingbackToken != "dart-ringback"
        ) {
            return
        }
        toneHandler.removeCallbacks(ringbackTimeoutRunnable)
        releaseAudioTrack(activeRingbackTrack)
        activeRingbackTrack = null
        activeRingbackToken = null
    }

    private fun playCallEndedToneInternal(appCtx: Context) {
        stopIncomingRingInternal(null)
        stopOutgoingRingbackInternal(null)
        toneHandler.removeCallbacks(endedReleaseRunnable)
        releaseAudioTrack(activeEndedTrack)
        activeEndedTrack = null

        val track = buildStaticSignallingTrack(appCtx, callEndedPcm, loop = false) ?: return
        val started = runCatching {
            track.play()
            true
        }.getOrElse { t ->
            PersistentLog.w(appCtx, TAG, "Failed to play call ended tone: ${t.message}")
            releaseAudioTrack(track)
            false
        }
        if (started) {
            activeEndedTrack = track
            toneHandler.postDelayed(endedReleaseRunnable, CALL_ENDED_RELEASE_DELAY_MS)
        }
    }

    private fun buildStaticSignallingTrack(context: Context, pcm: ShortArray, loop: Boolean): AudioTrack? {
        return try {
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION_SIGNALLING)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            val format = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(SAMPLE_RATE)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .build()
            val track = AudioTrack.Builder()
                .setAudioAttributes(attrs)
                .setAudioFormat(format)
                .setTransferMode(AudioTrack.MODE_STATIC)
                .setBufferSizeInBytes(pcm.size * 2)
                .build()
            val written = track.write(pcm, 0, pcm.size)
            if (written < 0) {
                releaseAudioTrack(track)
                return null
            }
            if (loop) {
                track.setLoopPoints(0, pcm.size, -1)
            }
            track
        } catch (t: Throwable) {
            PersistentLog.w(context, TAG, "Failed to allocate AudioTrack: ${t.message}")
            null
        }
    }

    private fun releaseAudioTrack(track: AudioTrack?) {
        if (track == null) return
        runCatching {
            if (track.playState == AudioTrack.PLAYSTATE_PLAYING) {
                track.pause()
                track.flush()
            }
            track.stop()
        }
        runCatching { track.release() }
    }
}
