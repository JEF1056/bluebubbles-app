package com.wearbubbles.notifications

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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.net.URLEncoder

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
    val avatarPath: String? = null
)

object CallNotificationHelper {
    private const val TAG = "CallNotificationHelper"
    const val ACTION_ANSWER_CALL = "com.wearbubbles.ACTION_ANSWER_CALL"
    const val ACTION_DECLINE_CALL = "com.wearbubbles.ACTION_DECLINE_CALL"
    const val ACTION_END_CALL = "com.wearbubbles.ACTION_END_CALL"
    const val EXTRA_CALL_UUID = "extra_call_uuid"

    private val _activeCallState = MutableStateFlow<ActiveCallState?>(null)
    val activeCallState: StateFlow<ActiveCallState?> = _activeCallState.asStateFlow()

    fun showIncomingCall(
        context: Context,
        callUuid: String,
        callerName: String,
        callerAddress: String,
        isVideo: Boolean,
        fromPhoneRelay: Boolean
    ) {
        if (callUuid.isBlank()) return
        val appContext = context.applicationContext
        val app = appContext as? WearBubblesApp
        val avatarPath = callerAddress.takeIf { it.isNotBlank() }?.let { addr ->
            app?.phoneRelayClient?.getAvatarFile(addr)?.absolutePath
        }

        val state = ActiveCallState(
            callUuid = callUuid,
            callerName = callerName.ifBlank { callerAddress.ifBlank { "FaceTime Caller" } },
            callerAddress = callerAddress,
            isVideo = isVideo,
            fromPhoneRelay = fromPhoneRelay,
            phase = CallPhase.RINGING,
            avatarPath = avatarPath
        )
        _activeCallState.value = state

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
            .setAutoCancel(false)

        val canUseFsi = Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE || manager.canUseFullScreenIntent()
        if (canUseFsi) {
            builder
                .setStyle(
                    NotificationCompat.CallStyle.forIncomingCall(
                        callerPerson,
                        declinePendingIntent,
                        answerPendingIntent
                    ).setIsVideo(isVideo)
                )
                .setFullScreenIntent(fullScreenPendingIntent, true)
        } else {
            // Android 14+ forbids CallStyle via notify() without a fullScreenIntent or foreground service.
            builder
                .setContentTitle(state.callerName)
                .setContentText(if (isVideo) "Incoming FaceTime Video" else "Incoming FaceTime Audio")
                .addAction(0, "Decline", declinePendingIntent)
                .addAction(0, "Answer", answerPendingIntent)
        }

        try {
            manager.notify(NotificationHelper.CALL_NOTIFICATION_ID, builder.build())
        } catch (e: Exception) {
            Log.w(TAG, "Failed to post incoming call notification: ${e.message}")
        }
    }

    suspend fun answerCallAudio(context: Context, callUuid: String) = withContext(Dispatchers.IO) {
        val appContext = context.applicationContext
        val current = _activeCallState.value
        val app = appContext as? WearBubblesApp

        val handledByPhone = if (app != null && (current?.fromPhoneRelay == true || app.phoneRelayClient.refreshPhoneConnected())) {
            app.phoneRelayClient.sendAnswerCallAudioAwait(
                callUuid = callUuid,
                callerName = current?.callerName,
                callerAddress = current?.callerAddress
            )
        } else {
            false
        }

        if (!handledByPhone) {
            postStandaloneCallAction(appContext, "answer", callUuid)
        }

        val startedAt = SystemClock.elapsedRealtime()
        val wasRinging = current?.phase == CallPhase.RINGING
        val updated = (current ?: ActiveCallState(
            callUuid = callUuid,
            callerName = "FaceTime Call",
            callerAddress = "",
            isVideo = false,
            fromPhoneRelay = handledByPhone,
            phase = CallPhase.ONGOING
        )).copy(phase = CallPhase.ONGOING, startedAtElapsedMs = startedAt)
        _activeCallState.value = updated

        if (wasRinging) {
            appContext.getSystemService(NotificationManager::class.java)
                ?.cancel(NotificationHelper.CALL_NOTIFICATION_ID)
        }
        postOngoingCallNotification(appContext, updated)
    }

    suspend fun declineOrEndCall(context: Context, callUuid: String) = withContext(Dispatchers.IO) {
        val appContext = context.applicationContext
        val current = _activeCallState.value
        val app = appContext as? WearBubblesApp

        val handledByPhone = if (app != null && (current?.fromPhoneRelay == true || app.phoneRelayClient.refreshPhoneConnected())) {
            app.phoneRelayClient.sendDeclineCallAwait(callUuid)
        } else {
            false
        }

        if (!handledByPhone) {
            val endpoint = if (current?.phase == CallPhase.ONGOING) "leave" else "decline"
            postStandaloneCallAction(appContext, endpoint, callUuid)
        }

        endCall(appContext, callUuid)
    }

    fun endCall(context: Context, callUuid: String? = null) {
        val current = _activeCallState.value
        if (callUuid != null && current != null && current.callUuid != callUuid) return
        _activeCallState.value = null
        CallForegroundService.stop(context.applicationContext)
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
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

    private fun buildOngoingCallNotification(
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

        val builder = NotificationCompat.Builder(context, NotificationHelper.CHANNEL_CALLS)
            .setSmallIcon(R.drawable.ic_stat_icon)
            .setContentTitle(state.callerName)
            .setContentText("FaceTime Audio • Ongoing")
            .addPerson(callerPerson)
            .setContentIntent(touchIntent)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setOngoing(true)
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setUsesChronometer(true)
            .setWhen(System.currentTimeMillis())

        if (useCallStyle) {
            builder.setStyle(
                NotificationCompat.CallStyle.forOngoingCall(callerPerson, endIntent)
                    .setIsVideo(false)
            )
        } else {
            builder.addAction(0, "End call", endIntent)
        }

        try {
            val status = Status.Builder()
                .addTemplate("On call • #timer#")
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

        return builder.build()
    }

    private fun postOngoingCallNotification(context: Context, state: ActiveCallState) {
        if (!NotificationHelper.canPostNotifications(context)) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val callStyleNotification = buildOngoingCallNotification(context, state, useCallStyle = true)
        try {
            CallForegroundService.start(context, callStyleNotification)
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

    private suspend fun postStandaloneCallAction(context: Context, action: String, callUuid: String) {
        try {
            val settings = SettingsDataStore(context)
            val serverUrl = settings.getServerUrl().trim().trimEnd('/')
            val password = settings.getPassword()
            if (serverUrl.isBlank() || password.isBlank()) return
            ApiClient.configureHeaders(serverUrl, settings.getCustomHeaders())
            val encodedUuid = URLEncoder.encode(callUuid, "UTF-8")
            val encodedPass = URLEncoder.encode(password, "UTF-8")
            val url = "$serverUrl/api/v1/facetime/$action/$encodedUuid?password=$encodedPass"
            val request = Request.Builder()
                .url(url)
                .post("{}".toRequestBody("application/json".toMediaType()))
                .build()
            ApiClient.okHttpClient.newCall(request).execute().close()
        } catch (e: Exception) {
            Log.w(TAG, "Standalone FaceTime $action failed for $callUuid: ${e.message}")
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
