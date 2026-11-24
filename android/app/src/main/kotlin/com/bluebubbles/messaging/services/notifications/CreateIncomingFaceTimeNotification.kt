package com.bluebubbles.messaging.services.notifications

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.media.AudioManager
import android.media.RingtoneManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.content.ContextCompat
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.MainActivity
import com.bluebubbles.messaging.R
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import com.bluebubbles.messaging.services.intents.InternalIntentReceiver
import com.bluebubbles.messaging.services.system.PushShareTargetsHandler
import com.bluebubbles.messaging.services.telecom.BoundedUuidSet
import com.bluebubbles.messaging.services.telecom.CallTonePlayer
import com.bluebubbles.messaging.services.telecom.FaceTimeConnectionService
import com.bluebubbles.messaging.services.telecom.FaceTimeRoutingPolicy
import com.bluebubbles.messaging.services.telecom.IncomingFaceTimeRoute
import com.bluebubbles.messaging.services.telecom.cancelIncomingCallNotifications
import com.bluebubbles.messaging.services.wear.WearSyncManager
import com.bluebubbles.messaging.utils.PersistentLog
import com.bluebubbles.messaging.utils.Utils
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class CreateIncomingFaceTimeNotification: MethodCallHandlerImpl() {
    internal enum class IncomingDartDedupeAction {
        SHOW_FULL,
        UPDATE_NOTIFICATION_SILENTLY,
        DROP_TELECOM_ACTIVE,
        DROP_ENDED
    }

    internal enum class IncomingRingOwnership {
        NONE,
        APP_TELECOM,
        SYSTEM_NOTIFICATION
    }

    companion object {
        const val tag = "create-incoming-facetime-notification"
        internal const val INCOMING_CALL_TIMEOUT_MS = 60_000L
        internal const val DIALER_PRIMARY_COLOR = 0xFF0B57D0.toInt()
        internal const val DIALER_ANSWER_COLOR = 0xFF34A853.toInt()
        internal const val DIALER_DECLINE_COLOR = 0xFFD93025.toInt()
        internal const val ANSWER_ACTION_SHOWS_USER_INTERFACE = true
        internal const val AUDIO_ANSWER_ACTION_SHOWS_USER_INTERFACE = true
        private val seenIncomingCallUuids = BoundedUuidSet(64)

        internal fun applyAnswerIntentExtras(
            notificationId: Int,
            isVideo: Boolean,
            isTelephony: Boolean,
            callerName: String,
            isOngoing: Boolean,
            putInt: (String, Int) -> Unit,
            putBoolean: (String, Boolean) -> Unit,
            putString: (String, String) -> Unit,
            setType: (String) -> Unit
        ) {
            putInt("notificationId", notificationId)
            putBoolean("answer", true)
            putBoolean("isVideo", isVideo)
            putBoolean("audioOnly", !isVideo)
            putBoolean("isTelephony", isTelephony)
            putString("caller", callerName)
            putBoolean(MainActivity.EXTRA_INCOMING_FACETIME, !isOngoing)
            setType("AnswerFaceTime")
        }

        internal fun resolveWearCallUuid(callUuid: String?, callerName: String): String =
            callUuid?.takeIf { it.isNotBlank() } ?: "ft_${callerName.hashCode()}"

        internal fun resolveNotificationTimeoutMs(isOngoing: Boolean): Long? =
            if (!isOngoing) INCOMING_CALL_TIMEOUT_MS else null

        internal fun resolveIncomingRingOwnership(
            isOngoing: Boolean,
            hasTelecomConnection: Boolean,
            hasOtherActiveCall: Boolean
        ): IncomingRingOwnership = when {
            isOngoing -> IncomingRingOwnership.NONE
            hasTelecomConnection || hasOtherActiveCall -> IncomingRingOwnership.APP_TELECOM
            else -> IncomingRingOwnership.SYSTEM_NOTIFICATION
        }

        internal fun shouldUseCallStyle(
            sdkInt: Int,
            isOngoing: Boolean,
            route: IncomingFaceTimeRoute,
            canUseFsi: Boolean = true
        ): Boolean = sdkInt >= Build.VERSION_CODES.S &&
            !isOngoing &&
            route != IncomingFaceTimeRoute.NOTIFICATION_ENABLE_ACCOUNT &&
            canUseFsi

        internal fun computeFaceTimeNotificationId(callUuid: String): Int {
            val numeric = callUuid.filter { it.isDigit() }
            if (numeric.isNotEmpty()) {
                numeric.take(8).toIntOrNull()?.let { return it }
            }
            return callUuid.hashCode() and 0x7fffffff
        }

        internal fun markIncomingCallSeen(callUuid: String): Boolean {
            if (callUuid.isBlank()) return true
            synchronized(seenIncomingCallUuids) {
                if (seenIncomingCallUuids.contains(callUuid)) return false
                seenIncomingCallUuids.add(callUuid)
                return true
            }
        }

        internal fun clearSeenIncomingCallsForTest() {
            seenIncomingCallUuids.clear()
        }

        internal fun resolveIsVideo(
            isVideoFlag: Boolean?,
            isAudioFlag: Boolean?,
            isTelephony: Boolean
        ): Boolean {
            if (isTelephony) return false
            if (isVideoFlag != null) return isVideoFlag
            if (isAudioFlag != null) return !isAudioFlag
            return true
        }

        private fun JSONObject.optNullableBoolean(key: String): Boolean? =
            if (has(key) && !isNull(key)) optBoolean(key) else null

        fun cancelIncomingCallNotification(context: Context, callUuid: String?) {
            if (callUuid.isNullOrBlank()) return
            cancelIncomingCallNotifications(context, callUuid, null)
        }

        @JvmStatic
        fun handlePushCallStatusChanged(context: Context, rawData: Any?) {
            val json = when (rawData) {
                is String -> runCatching { JSONObject(rawData) }.getOrNull()
                is Map<*, *> -> runCatching { JSONObject(rawData) }.getOrNull()
                else -> null
            } ?: return

            val statusId = when {
                json.has("status_id") && !json.isNull("status_id") -> json.optInt("status_id", -1)
                json.has("call_status") && !json.isNull("call_status") -> json.optInt("call_status", -1)
                else -> when (json.optString("status", "").lowercase()) {
                    "incoming" -> 4
                    "answered" -> 1
                    "disconnected" -> 6
                    else -> -1
                }
            }
            val callUuid = json.optString("uuid", "").ifBlank {
                json.optString("call_uuid", "").ifBlank { json.optString("session_uuid", "") }
            }.takeIf { it.isNotBlank() } ?: return
            val isOutgoing = json.optBoolean("is_outgoing", false)

            val appContext = context.applicationContext ?: context
            Handler(Looper.getMainLooper()).post {
                when (statusId) {
                    4 -> {
                        if (isOutgoing) return@post
                        if (FaceTimeConnectionService.isCallPendingEnded(callUuid)) return@post
                        if (!markIncomingCallSeen(callUuid)) return@post

                        val isTelephony = json.optBoolean("is_telephony", false)
                        val isVideo = resolveIsVideo(
                            isVideoFlag = json.optNullableBoolean("is_video"),
                            isAudioFlag = json.optNullableBoolean("is_audio"),
                            isTelephony = isTelephony
                        )
                        val callerAddress = json.optJSONObject("handle")?.optString("address")?.takeIf { it.isNotBlank() }
                            ?: json.optString("address", "").takeIf { it.isNotBlank() }
                        val callerName = json.optString("display_name", "").takeIf { it.isNotBlank() }
                            ?: json.optString("caller", "").takeIf { it.isNotBlank() }
                            ?: callerAddress
                            ?: if (isTelephony) "iPhone Call" else "Unknown Number"
                        val title = callerName
                        val body = if (isTelephony) {
                            "Incoming iPhone Call"
                        } else {
                            "Answer FaceTime ${if (isVideo) "Video" else "Audio"} Call"
                        }
                        val notificationId = computeFaceTimeNotificationId(callUuid)
                        showIncomingCall(
                            context = appContext,
                            channelId = NotificationChannelHandler.FACETIME_CHANNEL_ID,
                            notificationId = notificationId,
                            callUuid = callUuid,
                            title = title,
                            body = body,
                            isVideo = isVideo,
                            isTelephony = isTelephony,
                            isOngoing = false,
                            callerAddress = callerAddress,
                            callerName = callerName,
                            callerIcon = null
                        )
                    }
                    1 -> {
                        if (!FaceTimeConnectionService.markCallActive(callUuid, recordIfPending = isOutgoing)) {
                            FaceTimeConnectionService.endCall(callUuid, onlyIfRinging = true)
                            cancelIncomingCallNotification(appContext, callUuid)
                            if (!FaceTimeConnectionService.isCallActive(callUuid)) {
                                WearSyncManager.notifyCallEndedIfNotWatchAnswered(appContext, callUuid)
                            }
                        }
                    }
                    6 -> {
                        markIncomingCallSeen(callUuid)
                        FaceTimeConnectionService.endCall(callUuid, onlyIfRinging = false, recordIfPending = true)
                        cancelIncomingCallNotification(appContext, callUuid)
                        WearSyncManager.notifyCallEnded(appContext, callUuid)
                        if (!FaceTimeConnectionService.hasActiveCall()) {
                            MainActivity.clearCallLockScreenFlags()
                        }
                    }
                }
            }
        }

        internal fun resolveIncomingDartDedupeAction(
            isOngoing: Boolean,
            callUuid: String?,
            isPendingEnded: Boolean,
            hasActiveConnection: Boolean,
            isNewlySeen: Boolean
        ): IncomingDartDedupeAction {
            if (isOngoing || callUuid.isNullOrBlank()) return IncomingDartDedupeAction.SHOW_FULL
            if (isPendingEnded) return IncomingDartDedupeAction.DROP_ENDED
            if (isNewlySeen) return IncomingDartDedupeAction.SHOW_FULL
            if (hasActiveConnection) return IncomingDartDedupeAction.DROP_TELECOM_ACTIVE
            return IncomingDartDedupeAction.UPDATE_NOTIFICATION_SILENTLY
        }

        internal fun showIncomingCall(
            context: Context,
            channelId: String,
            notificationId: Int,
            callUuid: String?,
            title: String,
            body: String,
            isVideo: Boolean,
            isTelephony: Boolean,
            isOngoing: Boolean,
            callerAddress: String?,
            callerName: String,
            callerIcon: ByteArray?,
            silentUpdateOnly: Boolean = false,
            skipTelecomDirect: Boolean = false
        ): Boolean {
            if (!isOngoing && !silentUpdateOnly && !skipTelecomDirect) {
                WearSyncManager.notifyIncomingCall(
                    context = context,
                    callUuid = resolveWearCallUuid(callUuid, callerName),
                    callerName = callerName,
                    callerAddress = callerAddress,
                    isVideo = isVideo,
                    isTelephony = isTelephony
                )
            }

            val phoneAccountEnabled = if (!isOngoing) FaceTimeConnectionService.isPhoneAccountEnabled(context) else false
            val inCar = if (!isOngoing) isCarMode(context) else false
            val route = if (!isOngoing) {
                FaceTimeRoutingPolicy.resolveIncomingRoute(
                    isVideo = isVideo,
                    callUuid = callUuid,
                    phoneAccountEnabled = phoneAccountEnabled,
                    isTelephony = isTelephony,
                    inCar = inCar
                )
            } else {
                IncomingFaceTimeRoute.NOTIFICATION
            }

            if (!skipTelecomDirect && !isOngoing && !silentUpdateOnly && route == IncomingFaceTimeRoute.TELECOM_DIRECT && callUuid != null) {
                val added = FaceTimeConnectionService.addIncomingCall(
                    context = context,
                    callUuid = callUuid,
                    callerName = callerName,
                    address = callerAddress,
                    isTelephony = isTelephony,
                    isVideo = isVideo && !inCar
                )
                if (added) {
                    return true
                }
            }

            val toneUuid = callUuid ?: resolveWearCallUuid(null, callerName)
            val hasOtherActiveCall = !isOngoing && FaceTimeConnectionService.hasActiveNonRingingCall(toneUuid)
            val hasTelecomConnection = !isOngoing && (
                skipTelecomDirect ||
                    (callUuid != null && FaceTimeConnectionService.isConnectionRegistered(callUuid))
                )
            val ringOwnership = resolveIncomingRingOwnership(
                isOngoing = isOngoing,
                hasTelecomConnection = hasTelecomConnection,
                hasOtherActiveCall = hasOtherActiveCall
            )

            // Only play app-owned CallTonePlayer while a Telecom FaceTimeConnection keeps the process bound.
            // Callers via skipTelecomDirect already started ringing in FaceTimeConnectionService.onCreateIncomingConnection.
            if (ringOwnership == IncomingRingOwnership.APP_TELECOM && !silentUpdateOnly && !skipTelecomDirect) {
                CallTonePlayer.startIncomingRing(
                    context = context,
                    callUuid = toneUuid,
                    isCallInProgress = hasOtherActiveCall
                )
            }

            val callerBitmap = if ((callerIcon?.size ?: 0) == 0) null else BitmapFactory.decodeByteArray(callerIcon!!, 0, callerIcon.size)
            val callerIconCompat = if ((callerIcon?.size ?: 0) == 0) null else Utils.getAdaptiveIconFromByteArray(callerIcon!!)
            val resolvedCallerUri = PushShareTargetsHandler.resolveContactLookupUri(
                context = context,
                nativeContactId = null,
                fallbackUri = formatCallerUri(callerAddress)
            )

            // build the caller object
            val callerBuilder = Person.Builder()
                .setName(callerName)
                .setIcon(callerIconCompat)
                .setImportant(true)
            if (!resolvedCallerUri.isNullOrBlank()) {
                callerBuilder.setUri(resolvedCallerUri)
            }
            if (!callerAddress.isNullOrBlank()) {
                callerBuilder.setKey(callerAddress)
            }
            val caller = callerBuilder.build()

            // create a bundle for extra info
            val extras = Bundle()
            extras.putString("callUuid", callUuid)

            val piFlags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE

            // intent to open the app
            val openSummaryIntent = PendingIntent.getActivity(
                context,
                notificationId,
                Intent(context, MainActivity::class.java)
                    .putExtras(extras)
                    .putExtra("answer", false)
                    .putExtra("audioOnly", !isVideo)
                    .putExtra("isTelephony", isTelephony)
                    .putExtra("caller", callerName)
                    .putExtra(MainActivity.EXTRA_INCOMING_FACETIME, !isOngoing)
                    .setType("OpenSummary"),
                piFlags
            )

            // Create intent for answering via FaceTime link (video, or audio fallback when PhoneAccount is disabled)
            val answerIntent = PendingIntent.getActivity(
                context,
                notificationId + Constants.pendingIntentAnswerFaceTimeOffset,
                Intent(context, MainActivity::class.java).apply {
                    putExtras(extras)
                    applyAnswerIntentExtras(
                        notificationId = notificationId,
                        isVideo = isVideo,
                        isTelephony = isTelephony,
                        callerName = callerName,
                        isOngoing = isOngoing,
                        putInt = ::putExtra,
                        putBoolean = ::putExtra,
                        putString = ::putExtra,
                        setType = ::setType
                    )
                },
                piFlags
            )
            val answerAction = NotificationCompat.Action.Builder(0, if (isVideo) "Answer Video" else "Answer", answerIntent)
                .setShowsUserInterface(ANSWER_ACTION_SHOWS_USER_INTERFACE)
                .build()

            // Create intent to open Calling Accounts settings when Telecom PhoneAccount is disabled
            val enableCallingIntent = PendingIntent.getActivity(
                context,
                notificationId + Constants.pendingIntentOpenCallingAccountsOffset,
                FaceTimeConnectionService.callingAccountsIntent(context),
                piFlags
            )
            val enableCallingAction = NotificationCompat.Action.Builder(0, "Enable calling", enableCallingIntent)
                .setShowsUserInterface(true)
                .build()

            // Audio-answer action opens MainActivity directly (isVideo=false) to avoid broadcast trampoline
            val audioAnswerIntent = if (!isOngoing && !callUuid.isNullOrBlank()) {
                PendingIntent.getActivity(
                    context,
                    notificationId + Constants.pendingIntentAnswerFaceTimeAudioOffset,
                    Intent(context, MainActivity::class.java).apply {
                        putExtras(extras)
                        applyAnswerIntentExtras(
                            notificationId = notificationId,
                            isVideo = false,
                            isTelephony = isTelephony,
                            callerName = callerName,
                            isOngoing = isOngoing,
                            putInt = ::putExtra,
                            putBoolean = ::putExtra,
                            putString = ::putExtra,
                            setType = ::setType
                        )
                    },
                    piFlags
                )
            } else {
                null
            }
            val audioAnswerAction = audioAnswerIntent?.let {
                NotificationCompat.Action.Builder(0, "Audio", it)
                    .setShowsUserInterface(AUDIO_ANSWER_ACTION_SHOWS_USER_INTERFACE)
                    .build()
            }

            // Create intent for declining or hanging up the facetime call
            val declineIntent = PendingIntent.getBroadcast(
                context,
                notificationId + Constants.pendingIntentDeclineFaceTimeOffset,
                Intent(context, InternalIntentReceiver::class.java)
                    .putExtra("notificationId", notificationId)
                    .putExtra("tag", Constants.newFaceTimeNotificationTag)
                    .putExtra("callUuid", callUuid)
                    .setType("DeclineFaceTime"),
                piFlags
            )
            val declineAction = NotificationCompat.Action.Builder(0, if (isOngoing) "Hang Up" else "Decline", declineIntent)
                .setShowsUserInterface(false)
                .build()

            val useSystemRingNotification = ringOwnership == IncomingRingOwnership.SYSTEM_NOTIFICATION
            val notificationManager = context.getSystemService(NotificationManager::class.java)
            val resolvedChannelId = if (
                channelId == NotificationChannelHandler.FACETIME_CHANNEL_ID ||
                channelId == NotificationChannelHandler.LEGACY_FACETIME_CHANNEL_ID
            ) {
                if (useSystemRingNotification) {
                    NotificationChannelHandler.ensureFaceTimeRingChannel(context)
                } else {
                    NotificationChannelHandler.ensureFaceTimeChannel(context)
                }
            } else {
                channelId
            }
            val notificationBuilder = NotificationCompat.Builder(context, resolvedChannelId)
                .setSmallIcon(R.mipmap.ic_stat_icon)
                .setAutoCancel(!isOngoing)
                .setOngoing(true)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setContentTitle(title)
                .setContentText(body)
                .addExtras(extras)
                .addPerson(caller)
                .setColor(DIALER_PRIMARY_COLOR)
            if (!useSystemRingNotification) {
                notificationBuilder.setSilent(true)
            } else if (!silentUpdateOnly) {
                val ringtoneUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                    ?: Settings.System.DEFAULT_RINGTONE_URI
                notificationBuilder
                    .setSound(ringtoneUri, AudioManager.STREAM_RING)
                    .setVibrate(longArrayOf(0, 1000, 1000))
            }
            if (isOngoing) {
                notificationBuilder
                    .setUsesChronometer(true)
                    .setOnlyAlertOnce(true)
            } else if (silentUpdateOnly) {
                notificationBuilder.setOnlyAlertOnce(true)
            }
            val canUseFsi = Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE ||
                notificationManager.canUseFullScreenIntent()
            val useCallStyle = shouldUseCallStyle(Build.VERSION.SDK_INT, isOngoing, route, canUseFsi) && canUseFsi
            if (useCallStyle) {
                val callStyle = NotificationCompat.CallStyle.forIncomingCall(caller, declineIntent, answerIntent)
                    .setIsVideo(isVideo)
                    .setAnswerButtonColorHint(DIALER_ANSWER_COLOR)
                    .setDeclineButtonColorHint(DIALER_DECLINE_COLOR)
                notificationBuilder.setStyle(callStyle)
                if (canUseFsi) {
                    notificationBuilder.setFullScreenIntent(openSummaryIntent, true)
                }
                if (isVideo && audioAnswerAction != null) {
                    notificationBuilder.addAction(audioAnswerAction)
                } else if (!isVideo && !isTelephony && !phoneAccountEnabled) {
                    notificationBuilder.addAction(enableCallingAction)
                }
            } else {
                if (callerName.isNotBlank()) {
                    notificationBuilder.setContentTitle(callerName)
                }
                if (!isOngoing && route == IncomingFaceTimeRoute.NOTIFICATION_ENABLE_ACCOUNT && canUseFsi) {
                    notificationBuilder.setFullScreenIntent(openSummaryIntent, true)
                }
                if (!isOngoing) {
                    if (route == IncomingFaceTimeRoute.NOTIFICATION_ENABLE_ACCOUNT) {
                        notificationBuilder.addAction(enableCallingAction)
                    } else {
                        if (!isVideo && !phoneAccountEnabled) {
                            notificationBuilder.addAction(enableCallingAction)
                        }
                        notificationBuilder.addAction(answerAction)
                        if (isVideo && audioAnswerAction != null) {
                            notificationBuilder.addAction(audioAnswerAction)
                        }
                    }
                }
                notificationBuilder
                    .addAction(declineAction)
                    .extend(NotificationCompat.WearableExtender().apply {
                        if (!isOngoing) {
                            if (route == IncomingFaceTimeRoute.NOTIFICATION_ENABLE_ACCOUNT) {
                                addAction(enableCallingAction)
                            } else {
                                if (!isVideo && !phoneAccountEnabled) addAction(enableCallingAction)
                                addAction(answerAction)
                                if (isVideo && audioAnswerAction != null) addAction(audioAnswerAction)
                            }
                        }
                        addAction(declineAction)
                    })
            }
            if (callerBitmap != null) {
                notificationBuilder.setLargeIcon(callerBitmap)
            }
            if (callUuid != null) {
                notificationBuilder.setContentIntent(openSummaryIntent)
            }
            resolveNotificationTimeoutMs(isOngoing)?.let { timeoutMs ->
                notificationBuilder.setTimeoutAfter(timeoutMs)
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
            ) {
                PersistentLog.w(context, Constants.logTag, "POST_NOTIFICATIONS permission not granted; skipping FaceTime notification")
                return false
            }

            val builtNotification = notificationBuilder.build().apply {
                if (useSystemRingNotification) {
                    flags = flags or Notification.FLAG_INSISTENT
                }
            }
            notificationManager.notify(Constants.newFaceTimeNotificationTag, notificationId, builtNotification)
            return false
        }

        internal fun formatCallerUri(callerAddress: String?): String? {
            val trimmed = callerAddress?.trim()?.takeIf { it.isNotEmpty() } ?: return null
            return when {
                trimmed.startsWith("tel:") || trimmed.startsWith("mailto:") -> trimmed
                trimmed.contains("@") -> "mailto:$trimmed"
                else -> "tel:$trimmed"
            }
        }
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        // channel details
        val channelId: String = call.argument("channel_id")!!
        val notificationId: Int = call.argument("notification_id")!!
        // call details
        val callUuid: String? = call.argument("call_uuid")
        val title: String = call.argument("title")!!
        val body: String = call.argument("body")!!
        val isVideo: Boolean = call.argument("is_video") ?: true
        val isTelephony: Boolean = call.argument("is_telephony") ?: false
        val isOngoing: Boolean = call.argument("is_ongoing") ?: false
        val callerAddress: String? = call.argument("caller_address")
        // contact details
        val callerName: String = call.argument("caller")!!
        val callerIcon: ByteArray? = call.argument("caller_avatar")

        val isPendingEnded = !callUuid.isNullOrBlank() && FaceTimeConnectionService.isCallPendingEnded(callUuid)
        val hasActiveConnection = !callUuid.isNullOrBlank() && FaceTimeConnectionService.hasActiveConnection(callUuid)
        val isNewlySeen = isOngoing || callUuid.isNullOrBlank() || (!isPendingEnded && markIncomingCallSeen(callUuid))
        val action = resolveIncomingDartDedupeAction(
            isOngoing = isOngoing,
            callUuid = callUuid,
            isPendingEnded = isPendingEnded,
            hasActiveConnection = hasActiveConnection,
            isNewlySeen = isNewlySeen
        )
        when (action) {
            IncomingDartDedupeAction.DROP_ENDED -> {
                result.success(false)
                return
            }
            IncomingDartDedupeAction.DROP_TELECOM_ACTIVE -> {
                result.success(true)
                return
            }
            IncomingDartDedupeAction.UPDATE_NOTIFICATION_SILENTLY,
            IncomingDartDedupeAction.SHOW_FULL -> {
                val handledByTelecom = showIncomingCall(
                    context = context,
                    channelId = channelId,
                    notificationId = notificationId,
                    callUuid = callUuid,
                    title = title,
                    body = body,
                    isVideo = isVideo,
                    isTelephony = isTelephony,
                    isOngoing = isOngoing,
                    callerAddress = callerAddress,
                    callerName = callerName,
                    callerIcon = callerIcon,
                    silentUpdateOnly = (action == IncomingDartDedupeAction.UPDATE_NOTIFICATION_SILENTLY)
                )
                result.success(handledByTelecom)
            }
        }
    }
}