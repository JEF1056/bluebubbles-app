package com.wearbubbles.notifications

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.wear.ongoing.OngoingActivity
import androidx.wear.ongoing.Status
import com.wearbubbles.R
import com.wearbubbles.WearBubblesApp
import com.wearbubbles.api.ApiClient
import com.wearbubbles.data.SettingsDataStore
import com.wearbubbles.ui.call.IncomingCallActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.net.URLEncoder
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

enum class CallPhase {
    RINGING,
    ONGOING
}

data class ActiveCallState(
    val callUuid: String,
    val callerName: String,
    val callerAddress: String,
    val isVideo: Boolean,
    val fromPhoneRelay: Boolean,
    val phase: CallPhase,
    val startedAtElapsedMs: Long = 0L,
    val avatarPath: String? = null,
    val isTelephony: Boolean = false,
    val muted: Boolean = false,
    val isGroup: Boolean = false
)

object CallNotificationHelper {
    private const val TAG = "CallNotificationHelper"
    internal const val RING_TIMEOUT_MS = 60_000L
    internal const val ONGOING_HARD_CAP_MS = 4L * 60 * 60 * 1000L
    internal const val RELAY_DISCONNECT_GRACE_MS = 2L * 60 * 1000L
    internal const val STANDALONE_CALL_TIMEOUT_SECONDS = 6L
    internal const val RECENTLY_ENDED_TTL_MS = 60_000L
    const val ACTION_ANSWER_CALL = "com.wearbubbles.ACTION_ANSWER_CALL"
    const val ACTION_DECLINE_CALL = "com.wearbubbles.ACTION_DECLINE_CALL"
    const val ACTION_END_CALL = "com.wearbubbles.ACTION_END_CALL"
    const val ACTION_TOGGLE_MUTE = "com.wearbubbles.ACTION_TOGGLE_MUTE"
    const val EXTRA_CALL_UUID = "extra_call_uuid"

    private val callScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val callStateLock = Any()
    private val callEpoch = AtomicLong(0L)
    private val recentlyEndedCalls = LinkedHashMap<String, Long>()
    private val ringTimeoutLock = Any()
    private var ringTimeoutJob: Job? = null
    private val ongoingTimeoutLock = Any()
    private var ongoingTimeoutJob: Job? = null
    private var ongoingTimeoutUuid: String? = null

    private val standaloneCallOkHttpClient by lazy {
        ApiClient.okHttpClient.newBuilder()
            .callTimeout(STANDALONE_CALL_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .build()
    }

    private val _activeCallState = MutableStateFlow<ActiveCallState?>(null)
    val activeCallState: StateFlow<ActiveCallState?> = _activeCallState.asStateFlow()

    internal fun setActiveCallStateForTest(state: ActiveCallState?) {
        synchronized(callStateLock) {
            callEpoch.incrementAndGet()
            _activeCallState.value = state
        }
    }

    internal fun currentCallEpochForTest(): Long = callEpoch.get()

    internal fun clearRecentlyEndedForTest() {
        synchronized(callStateLock) {
            recentlyEndedCalls.clear()
        }
    }

    internal fun markRecentlyEndedForTest(callUuid: String, endedAtMs: Long) {
        synchronized(callStateLock) {
            recentlyEndedCalls[callUuid] = endedAtMs
        }
    }

    private fun pruneRecentlyEndedLocked(nowMs: Long) {
        val cutoff = nowMs - RECENTLY_ENDED_TTL_MS
        recentlyEndedCalls.entries.removeAll { it.value <= cutoff }
    }

    internal fun isRecentlyEnded(callUuid: String, nowMs: Long = System.currentTimeMillis()): Boolean {
        if (callUuid.isBlank()) return false
        synchronized(callStateLock) {
            pruneRecentlyEndedLocked(nowMs)
            return recentlyEndedCalls.containsKey(callUuid)
        }
    }

    internal fun shouldIgnoreIncomingCall(
        callUuid: String,
        nowMs: Long = System.currentTimeMillis()
    ): Boolean {
        if (callUuid.isBlank()) return true
        synchronized(callStateLock) {
            pruneRecentlyEndedLocked(nowMs)
            if (recentlyEndedCalls.containsKey(callUuid)) return true
            val current = _activeCallState.value
            return current != null && current.callUuid == callUuid && current.phase == CallPhase.ONGOING
        }
    }

    internal suspend fun tryAnswerCallAudio(
        callUuid: String,
        isTelephony: Boolean,
        fromPhoneRelay: Boolean = false,
        relayAnswer: suspend () -> Boolean,
        standaloneAnswer: suspend (String) -> Boolean
    ): Boolean {
        if (relayAnswer()) return true
        if (fromPhoneRelay) {
            return relayAnswer()
        }
        if (isTelephony) return false
        return standaloneAnswer(callUuid)
    }

    internal fun scheduleRingTimeout(
        callUuid: String,
        timeoutMs: Long = RING_TIMEOUT_MS,
        scope: CoroutineScope = callScope,
        onTimeout: (String) -> Unit
    ): Job {
        val job = scope.launch {
            delay(timeoutMs)
            val current = _activeCallState.value
            if (current != null && current.callUuid == callUuid && current.phase == CallPhase.RINGING) {
                onTimeout(callUuid)
            }
        }
        synchronized(ringTimeoutLock) {
            ringTimeoutJob?.cancel()
            ringTimeoutJob = job
        }
        return job
    }

    internal fun cancelRingTimeout() {
        synchronized(ringTimeoutLock) {
            ringTimeoutJob?.cancel()
            ringTimeoutJob = null
        }
    }

    internal fun scheduleOngoingTimeout(
        callUuid: String,
        fromPhoneRelay: Boolean,
        isPhoneConnected: StateFlow<Boolean>?,
        hardCapMs: Long = ONGOING_HARD_CAP_MS,
        disconnectGraceMs: Long = RELAY_DISCONNECT_GRACE_MS,
        scope: CoroutineScope = callScope,
        confirmPhoneDisconnected: (suspend () -> Boolean)? = null,
        onTimeout: (String) -> Unit
    ): Job {
        val job = scope.launch {
            val parentJob = coroutineContext[Job]
            val hardCapJob = launch {
                delay(hardCapMs)
                val current = _activeCallState.value
                if (current != null && current.callUuid == callUuid && current.phase == CallPhase.ONGOING) {
                    onTimeout(callUuid)
                    parentJob?.cancel()
                }
            }
            val relayWatchJob = if (fromPhoneRelay && isPhoneConnected != null) {
                launch {
                    isPhoneConnected.collectLatest { connected ->
                        if (!connected) {
                            delay(disconnectGraceMs)
                            val stillDisconnected = confirmPhoneDisconnected?.invoke() ?: !isPhoneConnected.value
                            val current = _activeCallState.value
                            if (stillDisconnected &&
                                current != null &&
                                current.callUuid == callUuid &&
                                current.phase == CallPhase.ONGOING &&
                                current.fromPhoneRelay
                            ) {
                                onTimeout(callUuid)
                                parentJob?.cancel()
                            }
                        }
                    }
                }
            } else {
                null
            }
            hardCapJob.join()
            relayWatchJob?.cancel()
        }
        synchronized(ongoingTimeoutLock) {
            ongoingTimeoutJob?.cancel()
            ongoingTimeoutJob = job
            ongoingTimeoutUuid = callUuid
        }
        return job
    }

    internal fun cancelOngoingTimeout() {
        synchronized(ongoingTimeoutLock) {
            ongoingTimeoutJob?.cancel()
            ongoingTimeoutJob = null
            ongoingTimeoutUuid = null
        }
    }

    internal fun callKindLabel(
        isVideo: Boolean,
        isTelephony: Boolean,
        isGroup: Boolean = false
    ): String = when {
        isTelephony -> "Phone Call"
        isGroup && isVideo -> "Group FaceTime Video"
        isGroup -> "Group FaceTime Audio"
        isVideo -> "FaceTime Video"
        else -> "FaceTime Audio"
    }

    internal fun incomingFallbackNotificationText(
        isVideo: Boolean,
        isTelephony: Boolean,
        isGroup: Boolean = false
    ): String = "Incoming ${callKindLabel(isVideo = isVideo, isTelephony = isTelephony, isGroup = isGroup)}"

    internal fun ongoingNotificationText(
        isTelephony: Boolean,
        muted: Boolean = false,
        isVideo: Boolean = false,
        isGroup: Boolean = false
    ): String {
        val base = callKindLabel(isVideo = isVideo, isTelephony = isTelephony, isGroup = isGroup)
        return if (muted) "$base • Muted" else "$base • Ongoing"
    }

    internal fun wallClockStart(
        startedElapsed: Long,
        nowElapsed: Long = SystemClock.elapsedRealtime(),
        nowWall: Long = System.currentTimeMillis()
    ): Long {
        if (startedElapsed <= 0L) return nowWall
        val elapsedSinceStart = (nowElapsed - startedElapsed).coerceAtLeast(0L)
        return nowWall - elapsedSinceStart
    }

    internal fun elapsedStartFromWall(
        startedAtMs: Long,
        nowElapsed: Long = SystemClock.elapsedRealtime(),
        nowWall: Long = System.currentTimeMillis()
    ): Long {
        if (startedAtMs <= 0L) return nowElapsed
        val ageMs = (nowWall - startedAtMs).coerceAtLeast(0L)
        return (nowElapsed - ageMs).coerceAtLeast(1L)
    }

    fun showIncomingCall(
        context: Context,
        callUuid: String,
        callerName: String,
        callerAddress: String,
        isVideo: Boolean,
        fromPhoneRelay: Boolean,
        isTelephony: Boolean = false,
        isGroup: Boolean = false
    ) {
        if (shouldIgnoreIncomingCall(callUuid)) return
        val appContext = context.applicationContext
        val app = appContext as? WearBubblesApp
        val avatarPath = callerAddress.takeIf { it.isNotBlank() }?.let { addr ->
            app?.phoneRelayClient?.getAvatarFile(addr)?.absolutePath
        }

        val effectiveVideo = isVideo && !isTelephony
        val effectiveGroup = isGroup && !isTelephony
        val kindLabel = callKindLabel(isVideo = effectiveVideo, isTelephony = isTelephony, isGroup = effectiveGroup)
        val state = ActiveCallState(
            callUuid = callUuid,
            callerName = callerName.ifBlank { callerAddress.ifBlank { kindLabel } },
            callerAddress = callerAddress,
            isVideo = effectiveVideo,
            fromPhoneRelay = fromPhoneRelay,
            phase = CallPhase.RINGING,
            avatarPath = avatarPath,
            isTelephony = isTelephony,
            isGroup = effectiveGroup
        )
        val accepted = synchronized(callStateLock) {
            pruneRecentlyEndedLocked(System.currentTimeMillis())
            val current = _activeCallState.value
            if (!shouldAcceptIncomingCall(current, callUuid, recentlyEndedCalls.containsKey(callUuid))) {
                false
            } else {
                callEpoch.incrementAndGet()
                cancelOngoingTimeout()
                _activeCallState.value = state
                true
            }
        }
        if (!accepted) return
        WearCallTonePlayer.startIncomingRing(appContext, callUuid)
        scheduleRingTimeout(callUuid) { timedOutUuid ->
            Log.i(TAG, "Incoming call $timedOutUuid timed out after ${RING_TIMEOUT_MS}ms")
            endCall(appContext, timedOutUuid)
        }

        if (!NotificationHelper.canPostNotifications(appContext)) return
        val manager = appContext.getSystemService(NotificationManager::class.java) ?: return

        val callerPerson = NotificationHelper.buildPerson(
            name = state.callerName,
            address = state.callerAddress,
            avatarPath = state.avatarPath,
            important = true
        )

        val fullScreenPendingIntent = buildCallActivityPendingIntent(appContext, callUuid)
        val answerPendingIntent = buildCallActionPendingIntent(appContext, ACTION_ANSWER_CALL, callUuid, 1)
        val declinePendingIntent = buildCallActionPendingIntent(appContext, ACTION_DECLINE_CALL, callUuid, 2)

        val builder = NotificationCompat.Builder(appContext, NotificationHelper.CHANNEL_CALLS)
            .setSmallIcon(R.drawable.ic_stat_icon)
            .addPerson(callerPerson)
            .setContentIntent(fullScreenPendingIntent)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setOngoing(true)
            .setSilent(true)
            .setAutoCancel(false)

        val canUseFsi = Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE || manager.canUseFullScreenIntent()
        if (canUseFsi) {
            builder
                .setStyle(
                    NotificationCompat.CallStyle.forIncomingCall(
                        callerPerson,
                        declinePendingIntent,
                        answerPendingIntent
                    ).setIsVideo(effectiveVideo)
                )
                .setFullScreenIntent(fullScreenPendingIntent, true)
        } else {
            // Android 14+ forbids CallStyle via notify() without a fullScreenIntent or foreground service.
            builder
                .setContentTitle(state.callerName)
                .setContentText(incomingFallbackNotificationText(isVideo = effectiveVideo, isTelephony = isTelephony))
                .addAction(0, "Decline", declinePendingIntent)
                .addAction(0, "Answer", answerPendingIntent)
        }

        val builtNotification = builder.build().apply {
            flags = applyCallNotificationFlags(flags, CallPhase.RINGING)
        }

        try {
            manager.notify(NotificationHelper.CALL_NOTIFICATION_ID, builtNotification)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to post incoming call notification: ${e.message}")
        }
    }

    internal fun applyCallNotificationFlags(baseFlags: Int, phase: CallPhase): Int = when (phase) {
        CallPhase.RINGING -> baseFlags or Notification.FLAG_INSISTENT
        CallPhase.ONGOING -> baseFlags and Notification.FLAG_INSISTENT.inv()
    }

    internal fun shouldCommitAnsweredCall(
        startEpoch: Long,
        callUuid: String,
        startState: ActiveCallState?,
        currentEpoch: Long = callEpoch.get(),
        latestState: ActiveCallState? = _activeCallState.value
    ): Boolean {
        if (currentEpoch != startEpoch) return false
        if (latestState != null && latestState.callUuid != callUuid) return false
        if (startState != null && latestState == null) return false
        return true
    }

    private fun safeLogWarn(msg: String) {
        try {
            Log.w(TAG, msg)
        } catch (_: Throwable) {
        }
    }

    internal suspend fun answerCallAudio(
        context: Context?,
        callUuid: String,
        relayAnswer: (suspend (ActiveCallState?) -> Boolean)? = null,
        standaloneAnswer: (suspend (String) -> Boolean)? = null,
        nowElapsedMs: Long = -1L
    ): Boolean = withContext(Dispatchers.IO) {
        val appContext = context?.applicationContext
        val (startEpoch, current) = synchronized(callStateLock) {
            callEpoch.get() to _activeCallState.value
        }
        if (current != null && current.callUuid != callUuid) {
            safeLogWarn("Aborting answer for stale call $callUuid (active=${current.callUuid})")
            return@withContext false
        }
        val app = appContext as? WearBubblesApp
        val isTelephony = current?.isTelephony == true
        val fromPhoneRelay = current?.fromPhoneRelay == true

        var answeredViaPhone = false
        val answered = tryAnswerCallAudio(
            callUuid = callUuid,
            isTelephony = isTelephony,
            fromPhoneRelay = fromPhoneRelay,
            relayAnswer = {
                val ok = when {
                    relayAnswer != null -> relayAnswer(current)
                    app != null && (fromPhoneRelay || app.phoneRelayClient.refreshPhoneConnected()) ->
                        app.phoneRelayClient.sendAnswerCallAudioAwait(
                            callUuid = callUuid,
                            callerName = current?.callerName,
                            callerAddress = current?.callerAddress,
                            isTelephony = isTelephony
                        )
                    else -> false
                }
                if (ok) answeredViaPhone = true
                ok
            },
            standaloneAnswer = { uuid ->
                standaloneAnswer?.invoke(uuid)
                    ?: (appContext != null && postStandaloneCallAction(appContext, "answer", uuid))
            }
        )
        val handledByPhone = current?.fromPhoneRelay == true || answeredViaPhone
        if (!answered) {
            safeLogWarn("Answer failed for $callUuid (isTelephony=$isTelephony, handledByPhone=$handledByPhone); staying in current state")
            return@withContext false
        }

        val startedAt = if (nowElapsedMs >= 0L) nowElapsedMs else SystemClock.elapsedRealtime()
        val (wasRinging, updated) = synchronized(callStateLock) {
            val latest = _activeCallState.value
            if (!shouldCommitAnsweredCall(startEpoch, callUuid, current, callEpoch.get(), latest)) {
                return@synchronized null
            }
            cancelRingTimeout()
            val resolvedElapsed = latest?.takeIf {
                it.phase == CallPhase.ONGOING && it.startedAtElapsedMs > 0L
            }?.startedAtElapsedMs ?: startedAt
            val next = (latest ?: ActiveCallState(
                callUuid = callUuid,
                callerName = "FaceTime Call",
                callerAddress = "",
                isVideo = false,
                fromPhoneRelay = handledByPhone,
                phase = CallPhase.ONGOING
            )).copy(phase = CallPhase.ONGOING, startedAtElapsedMs = resolvedElapsed)
            _activeCallState.value = next
            (latest?.phase == CallPhase.RINGING) to next
        } ?: run {
            safeLogWarn("Aborting answer commit for $callUuid; call ended or changed while answer was in flight")
            return@withContext false
        }

        if (appContext != null) {
            scheduleOngoingTimeout(
                callUuid = callUuid,
                fromPhoneRelay = updated.fromPhoneRelay,
                isPhoneConnected = app?.phoneRelayClient?.isPhoneConnected,
                confirmPhoneDisconnected = app?.let { { !it.phoneRelayClient.refreshPhoneConnected(force = true) } }
            ) { timedOutUuid ->
                Log.i(TAG, "Ongoing call $timedOutUuid hit safety timeout; ending call")
                endCall(appContext, timedOutUuid)
            }
            if (wasRinging) {
                WearCallTonePlayer.stopIncomingRing(callUuid)
                appContext.getSystemService(NotificationManager::class.java)
                    ?.cancel(NotificationHelper.CALL_NOTIFICATION_ID)
            }
            postOngoingCallNotification(appContext, updated)
        }
        true
    }

    fun markOngoingFromPhone(
        context: Context?,
        callUuid: String,
        startedAtMs: Long,
        muted: Boolean,
        callerName: String? = null,
        callerAddress: String? = null,
        isVideo: Boolean = false,
        isTelephony: Boolean = false,
        isGroup: Boolean = false,
        nowElapsedMs: Long = SystemClock.elapsedRealtime(),
        nowWallMs: Long = System.currentTimeMillis()
    ) {
        if (callUuid.isBlank() || isRecentlyEnded(callUuid, nowWallMs)) return
        val appContext = context?.applicationContext
        val app = appContext as? WearBubblesApp
        val argAvatarPath = callerAddress?.takeIf { it.isNotBlank() }?.let { addr ->
            app?.phoneRelayClient?.getAvatarFile(addr)?.absolutePath
        }
        val (wasRinging, updated, alreadyOngoingSameRelay) = synchronized(callStateLock) {
            pruneRecentlyEndedLocked(nowWallMs)
            if (recentlyEndedCalls.containsKey(callUuid)) return@synchronized null
            cancelRingTimeout()
            val current = _activeCallState.value
            val matchingCurrent = current?.takeIf { it.callUuid == callUuid }
            val resolvedElapsed = matchingCurrent?.takeIf {
                it.phase == CallPhase.ONGOING && it.startedAtElapsedMs > 0L
            }?.startedAtElapsedMs ?: elapsedStartFromWall(startedAtMs, nowElapsedMs, nowWallMs)

            val resolvedTelephony = isTelephony || (matchingCurrent?.isTelephony == true)
            val resolvedVideo = (isVideo || (matchingCurrent?.isVideo == true)) && !resolvedTelephony
            val resolvedGroup = (isGroup || (matchingCurrent?.isGroup == true)) && !resolvedTelephony
            val resolvedAddress = callerAddress?.takeIf { it.isNotBlank() }
                ?: matchingCurrent?.callerAddress.orEmpty()
            val resolvedKind = callKindLabel(
                isVideo = resolvedVideo,
                isTelephony = resolvedTelephony,
                isGroup = resolvedGroup
            )
            val resolvedName = callerName?.takeIf { it.isNotBlank() }
                ?: matchingCurrent?.callerName?.takeIf {
                    it.isNotBlank() && it != "Active Call" && it != "FaceTime Call"
                }
                ?: resolvedAddress.takeIf { it.isNotBlank() }
                ?: resolvedKind
            val resolvedAvatarPath = matchingCurrent?.avatarPath ?: argAvatarPath

            val next = (matchingCurrent ?: ActiveCallState(
                callUuid = callUuid,
                callerName = resolvedName,
                callerAddress = resolvedAddress,
                isVideo = resolvedVideo,
                fromPhoneRelay = true,
                phase = CallPhase.ONGOING,
                avatarPath = resolvedAvatarPath,
                isTelephony = resolvedTelephony,
                isGroup = resolvedGroup
            )).copy(
                callerName = resolvedName,
                callerAddress = resolvedAddress,
                isVideo = resolvedVideo,
                isTelephony = resolvedTelephony,
                isGroup = resolvedGroup,
                avatarPath = resolvedAvatarPath,
                phase = CallPhase.ONGOING,
                fromPhoneRelay = true,
                startedAtElapsedMs = resolvedElapsed,
                muted = muted
            )
            _activeCallState.value = next
            Triple(
                current?.phase == CallPhase.RINGING,
                next,
                matchingCurrent?.phase == CallPhase.ONGOING && matchingCurrent.fromPhoneRelay
            )
        } ?: return

        if (appContext == null) return
        val needsTimer = !alreadyOngoingSameRelay || synchronized(ongoingTimeoutLock) {
            ongoingTimeoutJob?.isActive != true || ongoingTimeoutUuid != callUuid
        }
        if (needsTimer) {
            scheduleOngoingTimeout(
                callUuid = callUuid,
                fromPhoneRelay = true,
                isPhoneConnected = app?.phoneRelayClient?.isPhoneConnected,
                confirmPhoneDisconnected = app?.let { { !it.phoneRelayClient.refreshPhoneConnected(force = true) } }
            ) { timedOutUuid ->
                Log.i(TAG, "Ongoing relayed call $timedOutUuid hit safety timeout; ending call")
                endCall(appContext, timedOutUuid)
            }
        }
        if (wasRinging) {
            WearCallTonePlayer.stopIncomingRing(callUuid)
            appContext.getSystemService(NotificationManager::class.java)
                ?.cancel(NotificationHelper.CALL_NOTIFICATION_ID)
        }
        postOngoingCallNotification(appContext, updated)
    }

    suspend fun toggleMute(context: Context, callUuid: String): Boolean = withContext(Dispatchers.IO) {
        val appContext = context.applicationContext
        val (current, updated) = synchronized(callStateLock) {
            val curr = _activeCallState.value ?: return@synchronized null
            if (curr.callUuid != callUuid || curr.phase != CallPhase.ONGOING) return@synchronized null

            val targetMuted = !curr.muted
            val upd = curr.copy(muted = targetMuted)
            _activeCallState.value = upd
            curr to upd
        } ?: return@withContext false

        postOngoingCallNotification(appContext, updated)

        val targetMuted = updated.muted
        val app = appContext as? WearBubblesApp
        val sent = if (app != null && (current.fromPhoneRelay || app.phoneRelayClient.refreshPhoneConnected())) {
            app.phoneRelayClient.sendSetCallMutedAwait(callUuid, targetMuted)
        } else {
            false
        }
        if (!sent) {
            Log.w(TAG, "Failed to relay mute=$targetMuted for $callUuid; reverting optimistic state")
            val reverted = synchronized(callStateLock) {
                val latest = _activeCallState.value
                if (latest != null && latest.callUuid == callUuid && latest.muted == targetMuted) {
                    val rev = latest.copy(muted = current.muted)
                    _activeCallState.value = rev
                    rev
                } else {
                    null
                }
            }
            if (reverted != null) {
                postOngoingCallNotification(appContext, reverted)
            }
        }
        sent
    }

    internal fun shouldAcceptIncomingCall(
        current: ActiveCallState?,
        callUuid: String,
        isRecentlyEnded: Boolean
    ): Boolean {
        if (isRecentlyEnded) return false
        if (current != null && current.phase == CallPhase.ONGOING) return false
        return true
    }

    internal suspend fun tryTransferCallToPhone(
        callUuid: String,
        canRelay: Boolean,
        relayTransfer: suspend (String) -> Boolean
    ): Boolean {
        if (callUuid.isBlank() || !canRelay) return false
        return relayTransfer(callUuid)
    }

    suspend fun transferCallToPhone(context: Context, callUuid: String): Boolean = withContext(Dispatchers.IO) {
        val appContext = context.applicationContext
        val current = _activeCallState.value
        val app = appContext as? WearBubblesApp ?: return@withContext false
        val canRelay = current?.fromPhoneRelay == true || app.phoneRelayClient.refreshPhoneConnected()
        val sent = tryTransferCallToPhone(callUuid, canRelay) { uuid ->
            app.phoneRelayClient.sendTransferCallAudioToPhoneAwait(uuid)
        }
        if (!sent) {
            Log.w(TAG, "Failed to relay transfer-to-phone for $callUuid")
        }
        sent
    }

    suspend fun declineOrEndCall(context: Context, callUuid: String) = withContext(Dispatchers.IO) {
        val appContext = context.applicationContext
        val current = _activeCallState.value
        val app = appContext as? WearBubblesApp
        val isTelephony = current?.isTelephony == true

        val handledByPhone = if (app != null && (current?.fromPhoneRelay == true || app.phoneRelayClient.refreshPhoneConnected())) {
            app.phoneRelayClient.sendDeclineCallAwait(callUuid)
        } else {
            false
        }

        if (!handledByPhone && !isTelephony) {
            val endpoint = if (current?.phase == CallPhase.ONGOING) "leave" else "decline"
            postStandaloneCallAction(appContext, endpoint, callUuid)
        }

        endCall(appContext, callUuid)
    }

    internal fun shouldEndCall(
        current: ActiveCallState?,
        callUuid: String?,
        onlyIfRinging: Boolean
    ): Boolean {
        if (callUuid != null && current != null && current.callUuid != callUuid) return false
        if (onlyIfRinging && current?.phase != CallPhase.RINGING) return false
        return true
    }

    fun endCall(context: Context?, callUuid: String? = null, onlyIfRinging: Boolean = false) {
        val ended = synchronized(callStateLock) {
            val current = _activeCallState.value
            if (!shouldEndCall(current, callUuid, onlyIfRinging)) return@synchronized false
            val endedUuid = current?.callUuid ?: callUuid?.takeIf { it.isNotBlank() }
            if (endedUuid != null) {
                val nowMs = System.currentTimeMillis()
                pruneRecentlyEndedLocked(nowMs)
                recentlyEndedCalls[endedUuid] = nowMs
            }
            callEpoch.incrementAndGet()
            cancelRingTimeout()
            cancelOngoingTimeout()
            _activeCallState.value = null
            true
        }
        if (!ended) return
        WearCallTonePlayer.stopIncomingRing(callUuid)
        val appContext = context?.applicationContext ?: return
        CallForegroundService.stop(appContext)
        val manager = appContext.getSystemService(NotificationManager::class.java) ?: return
        manager.cancel(NotificationHelper.CALL_NOTIFICATION_ID)
    }

    internal fun buildFallbackOngoingCallNotification(context: Context): android.app.Notification {
        val state = _activeCallState.value ?: ActiveCallState(
            callUuid = "active",
            callerName = "FaceTime Call",
            callerAddress = "",
            isVideo = false,
            fromPhoneRelay = false,
            phase = CallPhase.ONGOING,
            startedAtElapsedMs = SystemClock.elapsedRealtime()
        )
        return buildOngoingCallNotification(context, state, useCallStyle = false)
    }

    internal fun buildOngoingCallNotification(
        context: Context,
        state: ActiveCallState,
        useCallStyle: Boolean
    ): android.app.Notification {
        val callerPerson = NotificationHelper.buildPerson(
            name = state.callerName,
            address = state.callerAddress,
            avatarPath = state.avatarPath,
            important = true
        )
        val touchIntent = buildCallActivityPendingIntent(context, state.callUuid)
        val endIntent = buildCallActionPendingIntent(context, ACTION_END_CALL, state.callUuid, 3)
        val muteIntent = buildCallActionPendingIntent(context, ACTION_TOGGLE_MUTE, state.callUuid, 4)

        val builder = NotificationCompat.Builder(context, NotificationHelper.CHANNEL_CALLS)
            .setSmallIcon(R.drawable.ic_stat_icon)
            .setContentTitle(state.callerName)
            .setContentText(ongoingNotificationText(state.isTelephony, state.muted, state.isVideo, state.isGroup))
            .addPerson(callerPerson)
            .setContentIntent(touchIntent)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setOngoing(true)
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setUsesChronometer(true)
            .setWhen(wallClockStart(state.startedAtElapsedMs))

        val muteLabel = if (state.muted) "Unmute" else "Mute"
        if (useCallStyle) {
            builder.setStyle(
                NotificationCompat.CallStyle.forOngoingCall(callerPerson, endIntent)
                    .setIsVideo(state.isVideo)
            )
            builder.addAction(0, muteLabel, muteIntent)
        } else {
            builder.addAction(0, muteLabel, muteIntent)
            builder.addAction(0, "End call", endIntent)
        }

        try {
            val status = Status.Builder()
                .addTemplate(if (state.muted) "Muted • #timer#" else "On call • #timer#")
                .addPart("timer", Status.StopwatchPart(state.startedAtElapsedMs))
                .build()
            OngoingActivity.Builder(context, NotificationHelper.CALL_NOTIFICATION_ID, builder)
                .setStaticIcon(R.drawable.ic_stat_icon)
                .setTouchIntent(touchIntent)
                .setStatus(status)
                .build()
                .apply(context)
        } catch (_: Throwable) {
        }

        return builder.build().apply {
            flags = applyCallNotificationFlags(flags, CallPhase.ONGOING)
        }
    }

    private fun postOngoingCallNotification(context: Context, state: ActiveCallState) {
        if (!NotificationHelper.canPostNotifications(context)) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (CallForegroundService.isForegroundStarted) {
            try {
                val notification = buildOngoingCallNotification(context, state, useCallStyle = true)
                manager.notify(NotificationHelper.CALL_NOTIFICATION_ID, notification)
                return
            } catch (e: Exception) {
                Log.w(TAG, "Failed to update foreground call notification, restarting FGS: ${e.message}")
            }
        }
        try {
            CallForegroundService.start(context, state)
        } catch (e: Exception) {
            Log.w(TAG, "Foreground call service start blocked, falling back to non-CallStyle notify: ${e.message}")
            try {
                val fallback = buildOngoingCallNotification(context, state, useCallStyle = false)
                manager.notify(NotificationHelper.CALL_NOTIFICATION_ID, fallback)
            } catch (notifyErr: Exception) {
                Log.w(TAG, "Fallback ongoing call notify failed: ${notifyErr.message}")
            }
        }
    }

    private suspend fun postStandaloneCallAction(context: Context, action: String, callUuid: String): Boolean {
        return try {
            val settings = SettingsDataStore(context)
            val serverUrl = settings.getServerUrl().trim().trimEnd('/')
            val password = settings.getPassword()
            if (serverUrl.isBlank() || password.isBlank()) return false
            ApiClient.configureHeaders(serverUrl, settings.getCustomHeaders())
            val encodedUuid = URLEncoder.encode(callUuid, "UTF-8")
            val encodedPass = URLEncoder.encode(password, "UTF-8")
            val url = "$serverUrl/api/v1/facetime/$action/$encodedUuid?password=$encodedPass"
            val request = Request.Builder()
                .url(url)
                .post("{}".toRequestBody("application/json".toMediaType()))
                .build()
            standaloneCallOkHttpClient.newCall(request).execute().use { it.isSuccessful }
        } catch (e: Exception) {
            Log.w(TAG, "Standalone FaceTime $action failed for $callUuid: ${e.message}")
            false
        }
    }

    private fun buildCallActivityPendingIntent(context: Context, callUuid: String): PendingIntent {
        val intent = Intent(context, IncomingCallActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            data = Uri.parse("wearbubbles://call/${Uri.encode(callUuid)}")
            putExtra(EXTRA_CALL_UUID, callUuid)
        }
        return PendingIntent.getActivity(
            context,
            NotificationHelper.CALL_NOTIFICATION_ID,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun buildCallActionPendingIntent(
        context: Context,
        action: String,
        callUuid: String,
        requestOffset: Int
    ): PendingIntent {
        val intent = Intent(context, CallActionReceiver::class.java).apply {
            this.action = action
            data = Uri.parse("wearbubbles://call/${Uri.encode(callUuid)}/$action")
            putExtra(EXTRA_CALL_UUID, callUuid)
        }
        return PendingIntent.getBroadcast(
            context,
            NotificationHelper.CALL_NOTIFICATION_ID + requestOffset,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }
}
