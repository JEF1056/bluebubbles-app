package com.bluebubbles.messaging.services.notifications

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.content.ContextCompat
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.MainActivity
import com.bluebubbles.messaging.R
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import com.bluebubbles.messaging.services.intents.InternalIntentReceiver
import com.bluebubbles.messaging.services.system.PushShareTargetsHandler
import com.bluebubbles.messaging.services.telecom.FaceTimeConnectionService
import com.bluebubbles.messaging.services.telecom.FaceTimeRoutingPolicy
import com.bluebubbles.messaging.services.telecom.IncomingFaceTimeRoute
import com.bluebubbles.messaging.services.wear.WearSyncManager
import com.bluebubbles.messaging.utils.PersistentLog
import com.bluebubbles.messaging.utils.Utils
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class CreateIncomingFaceTimeNotification: MethodCallHandlerImpl() {
    companion object {
        const val tag = "create-incoming-facetime-notification"

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
        val isOngoing: Boolean = call.argument("is_ongoing") ?: false
        val callerAddress: String? = call.argument("caller_address")
        // contact details
        val callerName: String = call.argument("caller")!!
        val callerIcon: ByteArray? = call.argument("caller_avatar")

        if (!isOngoing && !callUuid.isNullOrBlank()) {
            WearSyncManager.notifyIncomingCall(
                context = context,
                callUuid = callUuid,
                callerName = callerName,
                callerAddress = callerAddress,
                isVideo = isVideo
            )
        }

        if (!isOngoing) {
            val route = FaceTimeRoutingPolicy.resolveIncomingRoute(
                isVideo = isVideo,
                callUuid = callUuid,
                phoneAccountEnabled = FaceTimeConnectionService.isPhoneAccountEnabled(context)
            )
            if (route == IncomingFaceTimeRoute.TELECOM_DIRECT && callUuid != null) {
                val added = FaceTimeConnectionService.addIncomingCall(
                    context = context,
                    callUuid = callUuid,
                    callerName = callerName,
                    address = callerAddress
                )
                if (added) {
                    result.success(true)
                    return
                }
            }
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
                .putExtra("caller", callerName)
                .setType("OpenSummary"),
            piFlags
        )

        // Create intent for answering video and opening the facetime link
        val answerIntent = PendingIntent.getActivity(
            context,
            notificationId + Constants.pendingIntentAnswerFaceTimeOffset,
            Intent(context, MainActivity::class.java)
                .putExtras(extras)
                .putExtra("answer", true)
                .putExtra("caller", callerName)
                .setType("AnswerFaceTime"),
            piFlags
        )
        val answerAction = NotificationCompat.Action.Builder(0, "Answer Video", answerIntent)
            .setShowsUserInterface(false)
            .build()

        // Create intent for handing off video call to Telecom audio-only (autoAnswer=true)
        val audioAnswerIntent = if (!isOngoing && !callUuid.isNullOrBlank()) {
            PendingIntent.getBroadcast(
                context,
                notificationId + Constants.pendingIntentAnswerFaceTimeAudioOffset,
                Intent(context, InternalIntentReceiver::class.java)
                    .putExtra("notificationId", notificationId)
                    .putExtra("tag", Constants.newFaceTimeNotificationTag)
                    .putExtra("callUuid", callUuid)
                    .putExtra("callerName", callerName)
                    .putExtra("callerAddress", callerAddress)
                    .setType("AnswerFaceTimeAudio"),
                piFlags
            )
        } else {
            null
        }
        val audioAnswerAction = audioAnswerIntent?.let {
            NotificationCompat.Action.Builder(0, "Audio", it)
                .setShowsUserInterface(false)
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

        val notificationManager = context.getSystemService(NotificationManager::class.java)
        val notificationBuilder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.mipmap.ic_stat_icon)
            .setAutoCancel(!isOngoing)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setContentTitle(title)
            .setContentText(body)
            .addExtras(extras)
            .addPerson(caller)
            .setColor(4888294)
        if (isOngoing) {
            notificationBuilder
                .setUsesChronometer(true)
                .setOnlyAlertOnce(true)
                .setSilent(true)
        }
        val canUseFsi = Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE ||
            notificationManager.canUseFullScreenIntent()
        // CallStyle on Android 14+ requires an FGS, user-initiated job, or fullScreenIntent;
        // ongoing updates from Dart/MethodChannel use notify() without an FGS, so fall back to standard actions.
        val useCallStyle = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && !isOngoing && canUseFsi
        if (useCallStyle) {
            val callStyle = NotificationCompat.CallStyle.forIncomingCall(caller, declineIntent, answerIntent)
                .setIsVideo(isVideo)
            notificationBuilder
                .setStyle(callStyle)
                .setFullScreenIntent(openSummaryIntent, true)
            if (isVideo && audioAnswerAction != null) {
                notificationBuilder.addAction(audioAnswerAction)
            }
        } else {
            if (callerName.isNotBlank()) {
                notificationBuilder.setContentTitle(callerName)
            }
            if (!isOngoing) {
                notificationBuilder.addAction(answerAction)
                if (isVideo && audioAnswerAction != null) {
                    notificationBuilder.addAction(audioAnswerAction)
                }
            }
            notificationBuilder
                .addAction(declineAction)
                .extend(NotificationCompat.WearableExtender().apply {
                    if (!isOngoing) {
                        addAction(answerAction)
                        if (isVideo && audioAnswerAction != null) addAction(audioAnswerAction)
                    }
                    addAction(declineAction)
                })
        }
        if (callerBitmap != null) {
            notificationBuilder.setLargeIcon(callerBitmap)
        }
        if (callUuid != null) {
            notificationBuilder.setContentIntent(openSummaryIntent)
            if (!isOngoing) {
                // clear after 30 seconds in case we didn't get an event from the server
                notificationBuilder.setTimeoutAfter(30000)
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            PersistentLog.w(context, Constants.logTag, "POST_NOTIFICATIONS permission not granted; skipping FaceTime notification")
            result.success(false)
            return
        }

        val builtNotification = notificationBuilder.build().apply {
            if (!isOngoing) {
                flags = flags or Notification.FLAG_INSISTENT
            }
        }
        notificationManager.notify(Constants.newFaceTimeNotificationTag, notificationId, builtNotification)
        result.success(false)
    }
}