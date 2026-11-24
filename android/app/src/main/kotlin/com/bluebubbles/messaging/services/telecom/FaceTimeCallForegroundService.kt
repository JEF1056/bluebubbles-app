package com.bluebubbles.messaging.services.telecom

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.content.ContextCompat
import androidx.core.graphics.drawable.IconCompat
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.MainActivity
import com.bluebubbles.messaging.R
import com.bluebubbles.messaging.services.intents.InternalIntentReceiver
import com.bluebubbles.messaging.services.notifications.CreateIncomingFaceTimeNotification
import com.bluebubbles.messaging.services.notifications.NotificationChannelHandler
import com.bluebubbles.messaging.utils.PersistentLog

/**
 * Foreground service hosting ongoing CallStyle live-activity notifications for active calls.
 */
class FaceTimeCallForegroundService : Service() {

    internal enum class UpdateAction {
        START_FOREGROUND_SERVICE,
        NOTIFY_EXISTING
    }

    internal enum class StopAction {
        REFRESH_REMAINING_CALL,
        STOP_SERVICE_NOW,
        DEFER_STOP_UNTIL_STARTED,
        CANCEL_NOTIFICATION_ONLY
    }

    companion object {
        private const val TAG = "FaceTimeCallFGS"
        private const val FALLBACK_NOTIFICATION_ID = 9401
        private const val EXTRA_CALL_UUID = "extra_call_uuid"
        private const val EXTRA_CALLER_NAME = "extra_caller_name"
        private const val EXTRA_CALLER_ADDRESS = "extra_caller_address"
        private const val EXTRA_AVATAR = "extra_avatar"
        private const val EXTRA_IS_VIDEO = "extra_is_video"
        private const val EXTRA_IS_TELEPHONY = "extra_is_telephony"
        private const val EXTRA_IS_GROUP = "extra_is_group"
        private const val EXTRA_STARTED_AT_MS = "extra_started_at_ms"
        private const val EXTRA_MUTED = "extra_muted"
        private const val EXTRA_SPEAKER = "extra_speaker"
        private const val PI_OFFSET_CONTENT = 1
        private const val PI_OFFSET_MUTE = 2
        private const val PI_OFFSET_SPEAKER = 3

        internal const val EXTRA_REQUEST_PROMOTED_ONGOING = "android.requestPromotedOngoing"

        private val stateLock = Any()

        @Volatile
        internal var started: Boolean = false

        @Volatile
        private var startPending: Boolean = false

        @Volatile
        private var pendingStopAll: Boolean = false

        @Volatile
        private var foregroundNotificationId: Int = 0

        @Volatile
        private var pendingCancelNotificationId: Int = 0

        internal fun resolveUpdateAction(
            isStarted: Boolean,
            currentForegroundNotificationId: Int,
            targetNotificationId: Int
        ): UpdateAction = if (isStarted && currentForegroundNotificationId == targetNotificationId) {
            UpdateAction.NOTIFY_EXISTING
        } else {
            UpdateAction.START_FOREGROUND_SERVICE
        }

        internal fun resolveStopAction(
            hasRemainingOngoingCall: Boolean,
            isStarted: Boolean,
            isStartPending: Boolean
        ): StopAction = when {
            hasRemainingOngoingCall -> StopAction.REFRESH_REMAINING_CALL
            isStarted -> StopAction.STOP_SERVICE_NOW
            isStartPending -> StopAction.DEFER_STOP_UNTIL_STARTED
            else -> StopAction.CANCEL_NOTIFICATION_ONLY
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

        internal fun ongoingActionLabels(muted: Boolean, speaker: Boolean): Pair<String, String> {
            val muteLabel = if (muted) "Unmute" else "Mute"
            val speakerLabel = if (speaker) "Speaker off" else "Speaker on"
            return muteLabel to speakerLabel
        }

        internal fun buildPromotionExtras(): Bundle = Bundle().apply {
            putBoolean(EXTRA_REQUEST_PROMOTED_ONGOING, true)
        }

        internal fun applyOngoingContentIntentExtras(
            callUuid: String,
            effectiveVideo: Boolean,
            isTelephony: Boolean,
            displayName: String,
            putString: (String, String) -> Unit,
            putBoolean: (String, Boolean) -> Unit,
            setType: (String) -> Unit
        ) {
            putString("callUuid", callUuid)
            putBoolean("openCall", true)
            putBoolean("audioOnly", !effectiveVideo)
            putBoolean("isTelephony", isTelephony)
            putString("caller", displayName)
            setType("OpenCall")
        }

        private fun notificationIdFor(callUuid: String?): Int {
            if (callUuid.isNullOrBlank()) return FALLBACK_NOTIFICATION_ID
            val id = CreateIncomingFaceTimeNotification.computeFaceTimeNotificationId(callUuid)
            return if (id == 0) FALLBACK_NOTIFICATION_ID else id
        }

        fun start(
            context: Context,
            callUuid: String,
            callerName: String,
            isVideo: Boolean,
            startedAtMs: Long,
            muted: Boolean,
            speaker: Boolean,
            isTelephony: Boolean = false,
            isGroup: Boolean = false,
            callerAddress: String? = null,
            callerAvatar: ByteArray? = null
        ) {
            startOrUpdate(
                context, callUuid, callerName, isVideo, startedAtMs, muted, speaker,
                isTelephony, isGroup, callerAddress, callerAvatar
            )
        }

        fun update(
            context: Context,
            callUuid: String,
            callerName: String,
            isVideo: Boolean,
            startedAtMs: Long,
            muted: Boolean,
            speaker: Boolean,
            isTelephony: Boolean = false,
            isGroup: Boolean = false,
            callerAddress: String? = null,
            callerAvatar: ByteArray? = null
        ) {
            startOrUpdate(
                context, callUuid, callerName, isVideo, startedAtMs, muted, speaker,
                isTelephony, isGroup, callerAddress, callerAvatar
            )
        }

        private fun startOrUpdate(
            context: Context,
            callUuid: String,
            callerName: String,
            isVideo: Boolean,
            startedAtMs: Long,
            muted: Boolean,
            speaker: Boolean,
            isTelephony: Boolean = false,
            isGroup: Boolean = false,
            callerAddress: String? = null,
            callerAvatar: ByteArray? = null
        ) {
            val appContext = context.applicationContext
            val notifId = notificationIdFor(callUuid)
            val action = synchronized(stateLock) {
                pendingStopAll = false
                val resolved = resolveUpdateAction(started, foregroundNotificationId, notifId)
                if (resolved == UpdateAction.START_FOREGROUND_SERVICE) {
                    startPending = true
                }
                resolved
            }

            if (action == UpdateAction.NOTIFY_EXISTING) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                    ContextCompat.checkSelfPermission(appContext, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                ) {
                    return
                }
                val nm = appContext.getSystemService(NotificationManager::class.java) ?: return
                try {
                    val notification = buildOngoingNotification(
                        context = appContext,
                        notificationId = notifId,
                        callUuid = callUuid,
                        callerName = callerName,
                        isVideo = isVideo,
                        startedAtMs = startedAtMs,
                        muted = muted,
                        speaker = speaker,
                        useCallStyle = true,
                        isTelephony = isTelephony,
                        isGroup = isGroup,
                        callerAddress = callerAddress,
                        callerAvatar = callerAvatar
                    )
                    nm.notify(notifId, notification)
                } catch (e: Exception) {
                    PersistentLog.w(appContext, TAG, "In-place CallStyle notify failed (${e.message}); falling back to non-CallStyle notify")
                    try {
                        val fallback = buildOngoingNotification(
                            context = appContext,
                            notificationId = notifId,
                            callUuid = callUuid,
                            callerName = callerName,
                            isVideo = isVideo,
                            startedAtMs = startedAtMs,
                            muted = muted,
                            speaker = speaker,
                            useCallStyle = false,
                            isTelephony = isTelephony,
                            isGroup = isGroup,
                            callerAddress = callerAddress,
                            callerAvatar = callerAvatar
                        )
                        nm.notify(notifId, fallback)
                    } catch (ne: Exception) {
                        PersistentLog.w(appContext, TAG, "Fallback ongoing call notify failed: ${ne.message}")
                    }
                }
                return
            }

            val intent = Intent(appContext, FaceTimeCallForegroundService::class.java).apply {
                putExtra(EXTRA_CALL_UUID, callUuid)
                putExtra(EXTRA_CALLER_NAME, callerName)
                putExtra(EXTRA_CALLER_ADDRESS, callerAddress)
                if (callerAvatar != null && callerAvatar.size <= 256 * 1024) {
                    putExtra(EXTRA_AVATAR, callerAvatar)
                }
                putExtra(EXTRA_IS_VIDEO, isVideo)
                putExtra(EXTRA_IS_TELEPHONY, isTelephony)
                putExtra(EXTRA_IS_GROUP, isGroup)
                putExtra(EXTRA_STARTED_AT_MS, startedAtMs)
                putExtra(EXTRA_MUTED, muted)
                putExtra(EXTRA_SPEAKER, speaker)
            }
            try {
                ContextCompat.startForegroundService(appContext, intent)
            } catch (e: Exception) {
                synchronized(stateLock) {
                    startPending = false
                }
                PersistentLog.w(appContext, TAG, "FGS start blocked (${e.message}); falling back to non-CallStyle notify")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                    ContextCompat.checkSelfPermission(appContext, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                ) {
                    return
                }
                try {
                    val fallback = buildOngoingNotification(
                        context = appContext,
                        notificationId = notifId,
                        callUuid = callUuid,
                        callerName = callerName,
                        isVideo = isVideo,
                        startedAtMs = startedAtMs,
                        muted = muted,
                        speaker = speaker,
                        useCallStyle = false,
                        isTelephony = isTelephony,
                        isGroup = isGroup,
                        callerAddress = callerAddress,
                        callerAvatar = callerAvatar
                    )
                    appContext.getSystemService(NotificationManager::class.java)?.notify(notifId, fallback)
                } catch (ne: Exception) {
                    PersistentLog.w(appContext, TAG, "Fallback ongoing call notify failed: ${ne.message}")
                }
            }
        }

        fun stop(context: Context, callUuid: String? = null) {
            val appContext = context.applicationContext
            val remaining = FaceTimeConnectionService.findRemainingOngoingConnection(callUuid)
            val endedNotifId = if (!callUuid.isNullOrBlank()) notificationIdFor(callUuid) else 0
            val cancelImmediately: Boolean
            val action = synchronized(stateLock) {
                val resolved = resolveStopAction(
                    hasRemainingOngoingCall = remaining != null,
                    isStarted = started,
                    isStartPending = startPending
                )
                when (resolved) {
                    StopAction.REFRESH_REMAINING_CALL -> {
                        if (endedNotifId != 0 && endedNotifId == foregroundNotificationId) {
                            pendingCancelNotificationId = endedNotifId
                            cancelImmediately = false
                        } else {
                            cancelImmediately = endedNotifId != 0
                        }
                    }
                    StopAction.STOP_SERVICE_NOW -> {
                        started = false
                        startPending = false
                        pendingStopAll = false
                        foregroundNotificationId = 0
                        pendingCancelNotificationId = 0
                        cancelImmediately = endedNotifId != 0
                    }
                    StopAction.DEFER_STOP_UNTIL_STARTED -> {
                        pendingStopAll = true
                        pendingCancelNotificationId = 0
                        cancelImmediately = endedNotifId != 0
                    }
                    StopAction.CANCEL_NOTIFICATION_ONLY -> {
                        cancelImmediately = endedNotifId != 0
                    }
                }
                resolved
            }

            if (action == StopAction.REFRESH_REMAINING_CALL && remaining != null) {
                remaining.startOrUpdateOngoingNotification(isStart = !started)
            } else if (action == StopAction.STOP_SERVICE_NOW) {
                appContext.stopService(Intent(appContext, FaceTimeCallForegroundService::class.java))
            }

            if (cancelImmediately) {
                appContext.getSystemService(NotificationManager::class.java)?.cancel(endedNotifId)
            }
        }

        internal fun buildOngoingNotification(
            context: Context,
            notificationId: Int,
            callUuid: String,
            callerName: String,
            isVideo: Boolean,
            startedAtMs: Long,
            muted: Boolean,
            speaker: Boolean,
            useCallStyle: Boolean,
            isTelephony: Boolean = false,
            isGroup: Boolean = false,
            callerAddress: String? = null,
            callerAvatar: ByteArray? = null
        ): Notification {
            val effectiveVideo = isVideo && !isTelephony
            val kindLabel = callKindLabel(isVideo = effectiveVideo, isTelephony = isTelephony, isGroup = isGroup)
            val displayName = callerName.takeIf { it.isNotBlank() }
                ?: callerAddress?.takeIf { it.isNotBlank() }
                ?: kindLabel
            val avatarIcon = callerAvatar?.takeIf { it.isNotEmpty() }?.let { bytes ->
                try {
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.let { IconCompat.createWithBitmap(it) }
                } catch (_: Throwable) {
                    null
                }
            }
            val personBuilder = Person.Builder()
                .setName(displayName)
                .setImportant(true)
            callerAddress?.takeIf { it.isNotBlank() }?.let { personBuilder.setKey(it) }
            avatarIcon?.let { personBuilder.setIcon(it) }
            val person = personBuilder.build()

            val piFlags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE

            val contentIntent = PendingIntent.getActivity(
                context,
                notificationId + PI_OFFSET_CONTENT,
                Intent(context, MainActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    applyOngoingContentIntentExtras(
                        callUuid = callUuid,
                        effectiveVideo = effectiveVideo,
                        isTelephony = isTelephony,
                        displayName = displayName,
                        putString = ::putExtra,
                        putBoolean = ::putExtra,
                        setType = ::setType
                    )
                },
                piFlags
            )

            val hangUpIntent = PendingIntent.getBroadcast(
                context,
                notificationId + Constants.pendingIntentDeclineFaceTimeOffset,
                Intent(context, InternalIntentReceiver::class.java)
                    .putExtra("notificationId", notificationId)
                    .putExtra("tag", Constants.newFaceTimeNotificationTag)
                    .putExtra("callUuid", callUuid)
                    .setType("HangUpFaceTime"),
                piFlags
            )

            val (muteLabel, speakerLabel) = ongoingActionLabels(muted, speaker)

            val muteIntent = PendingIntent.getBroadcast(
                context,
                notificationId + PI_OFFSET_MUTE,
                Intent(context, InternalIntentReceiver::class.java)
                    .putExtra("callUuid", callUuid)
                    .setType("ToggleFaceTimeMute"),
                piFlags
            )
            val muteAction = NotificationCompat.Action.Builder(0, muteLabel, muteIntent)
                .setShowsUserInterface(false)
                .build()

            val speakerIntent = PendingIntent.getBroadcast(
                context,
                notificationId + PI_OFFSET_SPEAKER,
                Intent(context, InternalIntentReceiver::class.java)
                    .putExtra("callUuid", callUuid)
                    .setType("ToggleFaceTimeSpeaker"),
                piFlags
            )
            val speakerAction = NotificationCompat.Action.Builder(0, speakerLabel, speakerIntent)
                .setShowsUserInterface(false)
                .build()

            NotificationChannelHandler.ensureFaceTimeChannel(context)
            val builder = NotificationCompat.Builder(context, NotificationChannelHandler.FACETIME_CHANNEL_ID)
                .setSmallIcon(R.mipmap.ic_stat_icon)
                .setContentTitle(displayName)
                .setContentText(kindLabel)
                .setContentIntent(contentIntent)
                .addPerson(person)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setOngoing(true)
                .setUsesChronometer(true)
                .setWhen(startedAtMs)
                .setSilent(true)
                .setOnlyAlertOnce(true)
                .addExtras(buildPromotionExtras())

            if (useCallStyle) {
                builder.setStyle(
                    NotificationCompat.CallStyle.forOngoingCall(person, hangUpIntent)
                        .setIsVideo(effectiveVideo)
                )
            } else {
                builder.addAction(0, "Hang Up", hangUpIntent)
            }
            builder.addAction(muteAction)
            builder.addAction(speakerAction)

            return builder.build()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val callUuid = intent?.getStringExtra(EXTRA_CALL_UUID)?.takeIf { it.isNotBlank() }
        val notifId = notificationIdFor(callUuid)
        val callerName = intent?.getStringExtra(EXTRA_CALLER_NAME) ?: ""
        val callerAddress = intent?.getStringExtra(EXTRA_CALLER_ADDRESS)
        val callerAvatar = intent?.getByteArrayExtra(EXTRA_AVATAR)
        val isVideo = intent?.getBooleanExtra(EXTRA_IS_VIDEO, false) ?: false
        val isTelephony = intent?.getBooleanExtra(EXTRA_IS_TELEPHONY, false) ?: false
        val isGroup = intent?.getBooleanExtra(EXTRA_IS_GROUP, false) ?: false
        val startedAtMs = intent?.getLongExtra(EXTRA_STARTED_AT_MS, System.currentTimeMillis()) ?: System.currentTimeMillis()
        val muted = intent?.getBooleanExtra(EXTRA_MUTED, false) ?: false
        val speaker = intent?.getBooleanExtra(EXTRA_SPEAKER, false) ?: false
        val notification = if (callUuid != null) {
            buildOngoingNotification(
                context = this,
                notificationId = notifId,
                callUuid = callUuid,
                callerName = callerName,
                isVideo = isVideo,
                startedAtMs = startedAtMs,
                muted = muted,
                speaker = speaker,
                useCallStyle = true,
                isTelephony = isTelephony,
                isGroup = isGroup,
                callerAddress = callerAddress,
                callerAvatar = callerAvatar
            )
        } else {
            buildOngoingNotification(
                context = this,
                notificationId = notifId,
                callUuid = "",
                callerName = "",
                isVideo = false,
                startedAtMs = System.currentTimeMillis(),
                muted = false,
                speaker = false,
                useCallStyle = false
            )
        }

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                var fgType = ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
                if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                    fgType = fgType or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                }
                if (isVideo && ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                    fgType = fgType or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
                }
                try {
                    startForeground(notifId, notification, fgType)
                } catch (e: Exception) {
                    if (fgType != ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL) {
                        PersistentLog.w(this, TAG, "startForeground with microphone/camera failed (${e.message}); retrying with PHONE_CALL only")
                        startForeground(notifId, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL)
                    } else {
                        throw e
                    }
                }
            } else {
                startForeground(notifId, notification)
            }
        } catch (e: Exception) {
            val skipFallback = synchronized(stateLock) {
                startPending = false
                started = false
                foregroundNotificationId = 0
                val wasPendingStop = pendingStopAll
                pendingStopAll = false
                pendingCancelNotificationId = 0
                wasPendingStop
            }
            PersistentLog.w(this, TAG, "startForeground failed (${e.message}); falling back to non-CallStyle notify")
            if (!skipFallback && callUuid != null &&
                (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                    ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)
            ) {
                try {
                    val fallback = buildOngoingNotification(
                        context = this,
                        notificationId = notifId,
                        callUuid = callUuid,
                        callerName = callerName,
                        isVideo = isVideo,
                        startedAtMs = startedAtMs,
                        muted = muted,
                        speaker = speaker,
                        useCallStyle = false,
                        isTelephony = isTelephony,
                        isGroup = isGroup,
                        callerAddress = callerAddress,
                        callerAvatar = callerAvatar
                    )
                    getSystemService(NotificationManager::class.java)?.notify(notifId, fallback)
                } catch (ne: Exception) {
                    PersistentLog.w(this, TAG, "Fallback ongoing call notify failed: ${ne.message}")
                }
            }
            stopSelf()
            return START_NOT_STICKY
        }

        val (shouldStopNow, previousNotifToCancel) = synchronized(stateLock) {
            startPending = false
            started = true
            val prevFg = foregroundNotificationId
            val pendingCancel = pendingCancelNotificationId
            pendingCancelNotificationId = 0
            foregroundNotificationId = notifId
            val stopNow = (callUuid == null || pendingStopAll)
            if (stopNow) {
                pendingStopAll = false
                started = false
                foregroundNotificationId = 0
            }
            val cancelId = when {
                prevFg != 0 && prevFg != notifId -> prevFg
                pendingCancel != 0 && pendingCancel != notifId -> pendingCancel
                else -> 0
            }
            stopNow to cancelId
        }
        if (previousNotifToCancel != 0) {
            getSystemService(NotificationManager::class.java)?.cancel(previousNotifToCancel)
        }
        if (shouldStopNow) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        synchronized(stateLock) {
            started = false
            startPending = false
            pendingStopAll = false
            foregroundNotificationId = 0
            pendingCancelNotificationId = 0
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
