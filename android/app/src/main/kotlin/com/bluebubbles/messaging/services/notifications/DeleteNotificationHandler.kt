package com.bluebubbles.messaging.services.notifications

import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.service.notification.StatusBarNotification
import androidx.core.app.NotificationCompat
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import com.bluebubbles.messaging.services.wear.WearSyncManager
import com.bluebubbles.messaging.utils.PersistentLog
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class DeleteNotificationHandler: MethodCallHandlerImpl() {
    companion object {
        const val tag = "delete-notification"

        internal fun resolveDismissedChatGuid(
            notificationChatGuid: String?,
            fallbackChatGuid: String?
        ): String? = com.bluebubbles.messaging.services.notifications.resolveDismissedChatGuid(
            notificationChatGuid,
            fallbackChatGuid
        )

        internal fun computeInboxSummary(
            childLines: List<String>,
            maxLines: Int = 5
        ): Pair<Int, List<String>> =
            com.bluebubbles.messaging.services.notifications.computeInboxSummary(childLines, maxLines)

        internal fun matchesNotification(
            sbnTag: String?,
            sbnId: Int,
            targetId: Int,
            targetTag: String?
        ): Boolean = com.bluebubbles.messaging.services.notifications.matchesNotification(
            sbnTag,
            sbnId,
            targetId,
            targetTag
        )

        // Set on a bubble's notification that was hidden because its chat was read. Its messages are all read, so the
        // next incoming message starts a new style instead of extending this one.
        const val readHiddenExtra = "readHidden"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val notificationId: Int = call.argument("notification_id")!!
        val tag: String? = call.argument("tag")
        val readBefore: Long? = call.argument<Number>("read_before")?.toLong()
        val callUuid: String? = call.argument("call_uuid")
        val keepBubble: Boolean = call.argument("keep_bubble") ?: false
        if (readBefore != null && trimReadMessages(context, notificationId, tag, readBefore)) {
            return result.success(null)
        }
        val success = deleteNotification(context, notificationId, tag, keepBubble = keepBubble, callUuidFallback = callUuid)
        if (success) {
            result.success(null)
        } else {
            result.error("500", "Failed to cancel notification!", null)
        }
    }

    // Drops messages dated at or before [readBefore] from the chat notification and reposts it silently.
    // Returns false when nothing newer is left, so the caller deletes the whole notification.
    private fun trimReadMessages(
        context: Context,
        notificationId: Int,
        tag: String?,
        readBefore: Long
    ): Boolean {
        val notificationManager = context.getSystemService(NotificationManager::class.java)
        val active = notificationManager.activeNotifications.firstOrNull {
            matchesNotification(it.tag, it.id, notificationId, tag)
        } ?: return false
        val style = NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(active.notification)
            ?: return false
        PersistentLog.d(context, Constants.logTag, "Trimming notification $notificationId through $readBefore: ${style.messages.map { it.timestamp }}")
        if (style.messages.none { it.timestamp > readBefore }) return false
        if (style.messages.none { it.timestamp <= readBefore }) return true

        style.messages.removeAll { it.timestamp <= readBefore }
        val remainingCount = style.messages.size.coerceAtLeast(1)
        val notification = NotificationCompat.Builder(context, active.notification)
            .setStyle(style)
            .setNumber(remainingCount)
            .setSilent(true)
            .build()
        notificationManager.notify(active.tag, notificationId, notification)
        if (active.tag == Constants.newMessageNotificationTag) {
            refreshSummaryNotification(
                context = context,
                notificationManager = notificationManager,
                channelTag = active.tag,
                updatedChildId = notificationId,
                updatedChildStyle = style
            )
        }
        return true
    }

    private fun refreshSummaryNotification(
        context: Context,
        notificationManager: NotificationManager,
        channelTag: String,
        excludedId: Int? = null,
        updatedChildId: Int? = null,
        updatedChildStyle: NotificationCompat.MessagingStyle? = null
    ) {
        val active = notificationManager.activeNotifications
        val summarySbn = active.firstOrNull { it.tag == channelTag && it.id == 0 } ?: return
        val remainingChildren = active.filter {
            it.tag == channelTag && it.id != 0 && it.id != excludedId
        }
        if (remainingChildren.isEmpty()) {
            notificationManager.cancel(channelTag, 0)
            return
        }
        val childLines = remainingChildren.mapNotNull { sbn ->
            val childStyle = if (sbn.id == updatedChildId && updatedChildStyle != null) {
                updatedChildStyle
            } else {
                NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(sbn.notification)
            }
            val lastMsg = childStyle?.messages?.lastOrNull() ?: return@mapNotNull null
            val author = lastMsg.person?.name?.toString()?.takeIf { it.isNotBlank() }
            if (author != null) "$author: ${lastMsg.text}" else lastMsg.text.toString()
        }
        val (totalConversations, visibleLines) = computeInboxSummary(childLines)
        if (totalConversations == 0) return

        val inboxStyle = NotificationCompat.InboxStyle()
            .setBigContentTitle("$totalConversations active ${if (totalConversations == 1) "conversation" else "conversations"}")
            .setSummaryText("$totalConversations ${if (totalConversations == 1) "chat" else "chats"}")
        visibleLines.forEach { inboxStyle.addLine(it) }

        val updatedSummary = NotificationCompat.Builder(context, summarySbn.notification)
            .setStyle(inboxStyle)
            .setNumber(totalConversations)
            .setSilent(true)
            .build()
        notificationManager.notify(channelTag, 0, updatedSummary)
    }

    fun deleteNotification(
        context: Context,
        notificationId: Int,
        tag: String?,
        chatGuidFallback: String? = null,
        callUuidFallback: String? = null,
        keepBubble: Boolean = false
    ): Boolean {
        PersistentLog.d(context, Constants.logTag, "Attempting to delete notification with ID, $notificationId from tag, $tag")
        val notificationManager = context.getSystemService(NotificationManager::class.java)

        try {
            // Get the notification by ID (scoped by tag when provided so FaceTime/chat IDs don't collide)
            val notification = notificationManager.activeNotifications.firstOrNull {
                matchesNotification(it.tag, it.id, notificationId, tag)
            }

            if (notification == null) {
                PersistentLog.d(context, Constants.logTag, "Notification with ID $notificationId not found!")
            } else if (keepBubble && hideBubbledNotification(context, notificationManager, notification)) {
                val chatGuid = resolveDismissedChatGuid(
                    notification.notification.extras.getString("chatGuid"),
                    chatGuidFallback
                )
                if (chatGuid != null) {
                    WearSyncManager.notifyDismissed(context, chatGuid)
                }
                // Skip the summary cleanup: an app cancelling a group summary also cancels its bubbled children, which
                // would take this bubble down too. SystemUI hides a summary whose only children are suppressed bubbles.
                PersistentLog.d(context, Constants.logTag, "Hid bubbled notification with ID $notificationId instead of cancelling it")
                return true
            } else {
                PersistentLog.d(context, Constants.logTag, "Cancelling notification with ID, ${notificationId}")
                notificationManager.cancel(notification.tag, notificationId)
            }

            // Android removes swiped notifications from activeNotifications before firing deleteIntent,
            // so fall back to chatGuidFallback from the intent extras to keep watch sync working.
            val chatGuid = resolveDismissedChatGuid(
                notification?.notification?.extras?.getString("chatGuid"),
                chatGuidFallback
            )
            if (chatGuid != null) {
                WearSyncManager.notifyDismissed(context, chatGuid)
            }

            val callUuid = resolveDismissedChatGuid(
                notification?.notification?.extras?.getString("callUuid"),
                callUuidFallback
            )
            if (callUuid != null) {
                WearSyncManager.notifyCallEnded(context, callUuid)
            }

            val channelTag: String? = notification?.tag ?: tag
            PersistentLog.d(context, Constants.logTag, "Using Channel Tag: $channelTag (Notif: ${notification?.tag}; Param: $tag)")
            if (channelTag != null) {
                // Get all notifications of the same tag/channel, excluding the one we just cancelled
                val leftoverNotifications = notificationManager.activeNotifications.filter {
                    it.tag == channelTag && it.id != notificationId
                }

                PersistentLog.d(context, Constants.logTag, "Found ${leftoverNotifications.size} leftover notifications after deleting ID $notificationId")

                // If there are no non-summary notifications left, or only the summary notification (ID = 0) remains,
                // we should cancel the summary notification; otherwise refresh summary InboxStyle & count.
                val nonSummaryNotifications = leftoverNotifications.filter { it.id != 0 }
                if (nonSummaryNotifications.isEmpty()) {
                    PersistentLog.d(context, Constants.logTag, "No non-summary notifications remaining, cancelling notification summary")
                    notificationManager.cancel(channelTag, 0)
                } else if (channelTag == Constants.newMessageNotificationTag) {
                    refreshSummaryNotification(
                        context = context,
                        notificationManager = notificationManager,
                        channelTag = channelTag,
                        excludedId = notificationId
                    )
                }
            }
        } catch (exception: Exception) {
            PersistentLog.e(context, Constants.logTag, "Failed to cancel notification with ID $notificationId!", exception)
            return false
        }
        
        return true
    }

    // Cancelling a bubble's notification removes the bubble, so take it out of the shade instead.
    // Returns false when the notification isn't bubbled or can't be reposted, so the caller cancels it as before.
    private fun hideBubbledNotification(context: Context, notificationManager: NotificationManager, sbn: StatusBarNotification): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        val current = sbn.notification
        val bubble = current.bubbleMetadata ?: return false
        if (current.flags and Notification.FLAG_BUBBLE == 0) return false

        try {
            val shortcutId = bubble.shortcutId
            val intent = bubble.intent
            val icon = bubble.icon
            val builder = when {
                shortcutId != null -> Notification.BubbleMetadata.Builder(shortcutId)
                intent != null && icon != null -> Notification.BubbleMetadata.Builder(intent, icon)
                else -> return false
            }
            if (bubble.desiredHeightResId != 0) builder.setDesiredHeightResId(bubble.desiredHeightResId)
            else builder.setDesiredHeight(bubble.desiredHeight)
            builder.setDeleteIntent(bubble.deleteIntent).setSuppressNotification(true)

            val hidden = Notification.Builder.recoverBuilder(context, current)
                .setBubbleMetadata(builder.build())
                .setOnlyAlertOnce(true)
                .addExtras(Bundle().apply { putBoolean(readHiddenExtra, true) })
                .build()
            notificationManager.notify(sbn.tag, sbn.id, hidden)
            return true
        } catch (exception: Exception) {
            PersistentLog.w(context, Constants.logTag, "Failed to hide bubbled notification ${sbn.id}, cancelling it instead", exception)
            return false
        }
    }
}