package com.bluebubbles.messaging.services.notifications

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.app.RemoteInput
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.core.content.LocusIdCompat
import androidx.core.graphics.drawable.IconCompat
import com.bluebubbles.messaging.BubbleActivity
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.MainActivity
import com.bluebubbles.messaging.R
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import com.bluebubbles.messaging.services.intents.InternalIntentReceiver
import com.bluebubbles.messaging.services.system.PushShareTargetsHandler
import com.bluebubbles.messaging.services.wear.WearSyncManager
import com.bluebubbles.messaging.utils.PersistentLog
import com.bluebubbles.messaging.utils.Utils
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class CreateIncomingMessageNotification: MethodCallHandlerImpl() {
    companion object {
        const val tag = "create-incoming-message-notification"
        const val PENDING_INTENT_LIKE_OFFSET = 400000
        const val PENDING_INTENT_MUTE_OFFSET = 500000
        private val QUICK_REPLY_CHOICES = arrayOf("Yes", "No", "On my way", "Sounds good", "Thanks!")
        private val notificationLock = Any()

        internal fun resolveTargetChannelId(
            baseChannelId: String,
            convChannelId: String?,
            convId: String?,
            chatGuid: String
        ): String = com.bluebubbles.messaging.services.notifications.resolveTargetChannelId(
            baseChannelId,
            convChannelId,
            convId,
            chatGuid
        )

        internal fun buildSummaryLines(
            existingLines: List<String>,
            newLine: String,
            maxLines: Int = 5
        ): List<String> = com.bluebubbles.messaging.services.notifications.buildSummaryLines(
            existingLines,
            newLine,
            maxLines
        )

        internal fun shouldOnlyAlertOnce(
            messageIsFromMe: Boolean,
            isReaction: Boolean,
            isEdit: Boolean,
            explicitOnlyAlertOnce: Boolean
        ): Boolean = com.bluebubbles.messaging.services.notifications.shouldOnlyAlertOnce(
            messageIsFromMe,
            isReaction,
            isEdit,
            explicitOnlyAlertOnce
        )

        internal fun sortKeyForTimestamp(timestampMs: Long): String =
            com.bluebubbles.messaging.services.notifications.sortKeyForTimestamp(timestampMs)

        internal fun shouldShowPhoneMuteAction(showReactionAction: Boolean): Boolean =
            com.bluebubbles.messaging.services.notifications.shouldShowPhoneMuteAction(showReactionAction)

        internal fun resolveNotificationId(chatId: Int?, chatGuid: String): Int =
            com.bluebubbles.messaging.services.notifications.resolveNotificationId(chatId, chatGuid)
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        // channel details
        val channelId: String = call.argument<String>("channel_id")?.takeIf { it.isNotBlank() } ?: run {
            PersistentLog.w(context, Constants.logTag, "Missing channel_id for incoming message notification")
            return result.success(null)
        }
        // chat details
        val chatGuid: String = call.argument<String>("chat_guid")?.takeIf { it.isNotBlank() } ?: run {
            PersistentLog.w(context, Constants.logTag, "Missing chat_guid for incoming message notification")
            return result.success(null)
        }
        val chatTitle: String = call.argument<String>("chat_title") ?: chatGuid
        val chatIsGroup: Boolean = call.argument<Boolean>("chat_is_group") ?: false
        val chatIcon: ByteArray? = call.argument("chat_icon")
        // message details
        val messageText: String = call.argument<String>("message_text") ?: ""
        val messageGuid: String = call.argument<String>("message_guid")?.takeIf { it.isNotBlank() } ?: run {
            PersistentLog.w(context, Constants.logTag, "Missing message_guid for incoming message notification")
            return result.success(null)
        }
        val messageDate: Long = call.argument<Number>("message_date")?.toLong() ?: System.currentTimeMillis()
        val messageIsFromMe: Boolean = call.argument<Boolean>("message_is_from_me") ?: false
        // contact details
        val contactName: String = call.argument<String>("contact_name") ?: chatTitle
        val contactIcon: ByteArray? = call.argument("contact_avatar")
        val contactBitmap = if ((contactIcon?.size ?: 0) == 0) null else Utils.getAdaptiveIconFromByteArray(contactIcon!!)
        // Reuse contactBitmap on 1:1 chats to avoid decoding the same avatar bytes twice.
        val chatBitmap = if (!chatIsGroup && (chatIcon == null || chatIcon.isEmpty() || (contactIcon != null && chatIcon.contentEquals(contactIcon)))) {
            contactBitmap
        } else if ((chatIcon?.size ?: 0) == 0) {
            null
        } else {
            Utils.getAdaptiveIconFromByteArray(chatIcon!!)
        }
        val contactKey: String? = call.argument("contact_key")
        val contactUri: String? = call.argument("contact_uri")
        val nativeContactId: String? = call.argument("native_contact_id")
        val youName: String = call.argument("you_name") ?: "You"
        val youKey: String = call.argument("you_key") ?: "me"
        val rawParticipants: List<Map<String, Any?>>? = call.argument("participants")
        // rich media attachment details
        val attachmentPath: String? = call.argument("attachment_path")
        val attachmentMime: String? = call.argument("attachment_mime")
        // reaction / update settings
        val showReactionAction: Boolean = call.argument("show_reaction_action") ?: false
        val reactionType: String = call.argument("reaction_type") ?: "like"
        val isReaction: Boolean = call.argument("is_reaction") ?: false
        val isEdit: Boolean = call.argument("is_edit") ?: false
        val explicitOnlyAlertOnce: Boolean = call.argument("only_alert_once") ?: false
        val rawHistoricMessages: List<Map<String, Any?>>? = call.argument("historic_messages")

        // calculate a notification ID based on the chat database ID (0 is reserved for the group summary)
        val notificationId: Int = resolveNotificationId(call.argument<Number>("chat_id")?.toInt(), chatGuid)

        val notificationManager = context.getSystemService(NotificationManager::class.java)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            PersistentLog.w(context, Constants.logTag, "POST_NOTIFICATIONS permission not granted; skipping message notification")
            return result.success(null)
        }
        // this is used to copy the style, since the notification already exists
        // (a bubble's notification hidden on read holds only read messages, so it isn't copied)
        val chatNotification = notificationManager.activeNotifications.lastOrNull {
            it.notification.extras.getString("chatGuid") == chatGuid &&
                it.notification.extras.getString("channelId") == channelId &&
                !it.notification.extras.getBoolean(DeleteNotificationHandler.readHiddenExtra)
        }

        // Route to conversation-specific channel on Android 11+ when present
        val targetChannelId = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val convChannel = notificationManager.getNotificationChannel(channelId, chatGuid)
            resolveTargetChannelId(channelId, convChannel?.id, convChannel?.conversationId, chatGuid)
        } else {
            channelId
        }

        // build the sender and "You" Person objects for DND contact breakthrough; shortcut refresh is cached/async.
        val resolvedSenderUri = PushShareTargetsHandler.resolveContactLookupUri(context, nativeContactId, contactUri)
        val sender = buildPerson(contactName, contactBitmap, resolvedSenderUri, contactKey, true)
        val youPerson = buildPerson(youName, null, null, youKey, false)

        PushShareTargetsHandler().ensureShareTargetForNotification(
            context = context,
            name = chatTitle,
            guid = chatGuid,
            icon = chatIcon ?: contactIcon,
            predecodedIcon = chatBitmap,
            resolvedSenderUri = resolvedSenderUri,
            contactKey = contactKey,
            contactBitmap = contactBitmap,
            rawParticipants = rawParticipants
        )

        // Hold notificationLock across activeNotifications snapshot, MessagingStyle merge, and notify()
        // so concurrent messages for the same chat cannot overwrite each other's style.
        synchronized(notificationLock) {
            val activeNotifications = notificationManager.activeNotifications
            val notificationPostedAlready = activeNotifications.firstOrNull {
                it.notification.extras.getString("chatGuid") == chatGuid &&
                    it.notification.extras.getString("messageGuid") == messageGuid
            } != null
            if (notificationPostedAlready) {
                result.success(null)
                return
            }

            // this is used to copy the style, since the notification already exists
            val chatNotification = activeNotifications.lastOrNull {
                it.notification.extras.getString("chatGuid") == chatGuid &&
                    it.notification.extras.getString("channelId") == channelId
            }

            // get or create a messaging style
            val extractedStyle = chatNotification?.let {
                NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(it.notification)
            }
            val style = extractedStyle ?: run {
                val newStyle = NotificationCompat.MessagingStyle(youPerson)
                rawHistoricMessages?.forEach { h ->
                    val hText = h["text"] as? String ?: return@forEach
                    val hDate = (h["date"] as? Number)?.toLong() ?: return@forEach
                    val hFromMe = h["is_from_me"] as? Boolean ?: false
                    val hSender = if (hFromMe) {
                        youPerson
                    } else {
                        val hName = (h["sender_name"] as? String)?.takeIf { it.isNotBlank() } ?: contactName
                        val hKey = h["sender_key"] as? String ?: contactKey
                        val hUri = h["sender_uri"] as? String ?: resolvedSenderUri
                        buildPerson(hName, null, hUri, hKey, true)
                    }
                    newStyle.addHistoricMessage(NotificationCompat.MessagingStyle.Message(hText, hDate, hSender))
                }
                newStyle
            }
            if (chatIsGroup) {
                style.isGroupConversation = true
                style.conversationTitle = chatTitle
            }
            // add the new message (with optional image/sticker FileProvider URI) to the style
            val styleMessage = NotificationCompat.MessagingStyle.Message(
                messageText,
                messageDate,
                sender
            )
            if (!attachmentPath.isNullOrEmpty() && !attachmentMime.isNullOrEmpty()) {
                try {
                    val attachmentFile = File(attachmentPath)
                    if (attachmentFile.exists()) {
                        val contentUri = FileProvider.getUriForFile(
                            context,
                            context.getString(R.string.file_provider),
                            attachmentFile
                        )
                        context.grantUriPermission(
                            "com.android.systemui",
                            contentUri,
                            Intent.FLAG_GRANT_READ_URI_PERMISSION
                        )
                        styleMessage.setData(attachmentMime, contentUri)
                    }
                } catch (e: Exception) {
                    PersistentLog.w(context, Constants.logTag, "Failed to attach media URI to notification: ${e.message}")
                }
            }
            style.addMessage(styleMessage)

            // create a bundle for extra info
            val extras = Bundle()
            extras.putString("chatGuid", chatGuid)
            extras.putString("messageGuid", messageGuid)
            extras.putString("channelId", channelId)
            extras.putString("tag", Constants.newMessageNotificationTag)
            extras.putBoolean("reactionSent", false) // Track if reaction has been sent

            // intent to open the conversation in-app
            val openConversationIntent = PendingIntent.getActivity(
                context,
                notificationId + Constants.pendingIntentOpenChatOffset,
                Intent(context, MainActivity::class.java)
                    .putExtras(extras)
                    .putExtra("notificationId", notificationId)
                    .putExtra("bubble", false)
                    .setType("OpenChat"),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )

            // intent to swipe away the notification
            val deleteNotificationIntent = PendingIntent.getBroadcast(
                context,
                notificationId + Constants.pendingIntentDeleteNotificationOffset,
                Intent(context, InternalIntentReceiver::class.java)
                    .putExtras(extras)
                    .putExtra("notificationId", notificationId)
                    .setType("DeleteNotification"),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )

            // intent and action for 'mark as read'
            val markAsReadIntent = PendingIntent.getBroadcast(
                context,
                notificationId + Constants.pendingIntentMarkReadOffset,
                Intent(context, InternalIntentReceiver::class.java)
                    .putExtras(extras)
                    .putExtra("notificationId", notificationId)
                    .setType("MarkChatRead"),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val markAsReadAction = NotificationCompat.Action.Builder(0, "Mark As Read", markAsReadIntent)
                .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_MARK_AS_READ)
                .setShowsUserInterface(false)
                .build()

            // intent and action for quick reply
            val replyIntent = PendingIntent.getBroadcast(
                context,
                notificationId,
                Intent(context, InternalIntentReceiver::class.java)
                    .putExtras(extras)
                    .putExtra("notificationId", notificationId)
                    .setType("ReplyChat"),
                PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val replyAction = NotificationCompat.Action.Builder(0, "Reply", replyIntent)
                .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_REPLY)
                .setShowsUserInterface(false)
                .setAllowGeneratedReplies(true)
                .extend(NotificationCompat.Action.WearableExtender().setHintDisplayActionInline(true))
                .addRemoteInput(
                    RemoteInput.Builder("text_reply")
                        .setLabel("Reply")
                        .setChoices(QUICK_REPLY_CHOICES)
                        .setAllowDataType("image/*", true)
                        .build()
                )
                .build()

            // intent and action for 'like'
            val likeIntent = PendingIntent.getBroadcast(
                context,
                notificationId + PENDING_INTENT_LIKE_OFFSET,
                Intent(context, InternalIntentReceiver::class.java)
                    .putExtras(extras)
                    .putExtra("notificationId", notificationId)
                    .putExtra("messageText", messageText)
                    .putExtra("reactionType", reactionType)
                    .setType("LikeMessage"),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val likeActionTitle = if (reactionType == "love") "Love" else "Like"
            val likeAction = NotificationCompat.Action.Builder(0, likeActionTitle, likeIntent)
                .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_THUMBS_UP)
                .setShowsUserInterface(false)
                .build()

            // intent and action for 'mute'
            val muteIntent = PendingIntent.getBroadcast(
                context,
                notificationId + PENDING_INTENT_MUTE_OFFSET,
                Intent(context, InternalIntentReceiver::class.java)
                    .putExtras(extras)
                    .putExtra("notificationId", notificationId)
                    .setType("MuteChat"),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val muteAction = NotificationCompat.Action.Builder(0, "Mute", muteIntent)
                .setSemanticAction(NotificationCompat.Action.SEMANTIC_ACTION_MUTE)
                .setShowsUserInterface(false)
                .build()

            // intent for bubbling on API 29 fallback
            val bubbleIntent = PendingIntent.getActivity(
                context,
                notificationId + Constants.pendingIntentOpenBubbleOffset,
                Intent(context, BubbleActivity::class.java)
                    .putExtras(extras)
                    .putExtra("notificationId", notificationId)
                    .putExtra("bubble", true)
                    .setType("OpenChat"),
                PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )

            val onlyAlertOnce = shouldOnlyAlertOnce(messageIsFromMe, isReaction, isEdit, explicitOnlyAlertOnce)
            val unreadMessageCount = style.messages.size.coerceAtLeast(1)
            val publicNotification = NotificationCompat.Builder(context, targetChannelId)
                .setSmallIcon(R.mipmap.ic_stat_icon)
                .setContentTitle(context.getString(R.string.app_name_en))
                .setContentText("New message")
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setColor(4888294)
                .setNumber(unreadMessageCount)
                .build()

            // Build the notification
            // Keep bridged to Wear OS when paired (localOnly=false); Wear's MessageListenerService
            // only posts standalone notifications when disconnected from the phone.
            val notificationBuilder = NotificationCompat.Builder(context, targetChannelId)
                .setSmallIcon(R.mipmap.ic_stat_icon)
                .setGroup(Constants.notificationGroupKey)
                .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
                .setOnlyAlertOnce(onlyAlertOnce)
                .setAutoCancel(true)
                .setWhen(messageDate)
                .setShowWhen(true)
                .setSortKey(sortKeyForTimestamp(messageDate))
                .setNumber(unreadMessageCount)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setPublicVersion(publicNotification)
                .setContentIntent(openConversationIntent)
                .setDeleteIntent(deleteNotificationIntent)
                .setStyle(style)
                .setAllowSystemGeneratedContextualActions(true)
                .setColor(4888294)
                .addAction(markAsReadAction)
                .addAction(replyAction)
                .addExtras(extras)

            notificationBuilder.addPerson(sender)
            rawParticipants?.forEach { p ->
                val pName = p["name"] as? String ?: return@forEach
                val pKey = p["key"] as? String
                if (pKey != null && pKey == sender.key) return@forEach
                val pUri = PushShareTargetsHandler.resolveContactLookupUriIfCached(
                    p["native_contact_id"] as? String,
                    p["uri"] as? String
                ) ?: (p["uri"] as? String)
                notificationBuilder.addPerson(buildPerson(pName, null, pUri, pKey, true))
            }

            val existingHistory = chatNotification?.notification?.extras?.getCharSequenceArray(Notification.EXTRA_REMOTE_INPUT_HISTORY)
            if (!existingHistory.isNullOrEmpty()) {
                notificationBuilder.setRemoteInputHistory(existingHistory)
            }

            // Keep 3 phone actions: Like when reactions enabled, Mute as 3rd phone action only when reactions disabled.
            if (showReactionAction) {
                notificationBuilder.addAction(likeAction)
            } else if (shouldShowPhoneMuteAction(showReactionAction)) {
                notificationBuilder.addAction(muteAction)
            }

            // Build wearable extender (Mute always available on watch)
            val wearableExtender = NotificationCompat.WearableExtender()
                .setBridgeTag(chatGuid)
                .setDismissalId(chatGuid)
                .addAction(markAsReadAction)
                .addAction(replyAction)
            if (showReactionAction) {
                wearableExtender.addAction(likeAction)
            }
            wearableExtender.addAction(muteAction)
            notificationBuilder.extend(wearableExtender)

            // Set shortcut-backed BubbleMetadata on API 30+, falling back to API 29 intent+icon constructor.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                val bubbleMetadata = NotificationCompat.BubbleMetadata.Builder(chatGuid)
                    .setDesiredHeight(600)
                    .setDeleteIntent(deleteNotificationIntent)
                    .build()
                notificationBuilder.setBubbleMetadata(bubbleMetadata)
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val bubbleMetadata = NotificationCompat.BubbleMetadata.Builder(
                    bubbleIntent,
                    chatBitmap ?: IconCompat.createWithResource(context, R.mipmap.ic_stat_icon)
                )
                    .setDesiredHeight(600)
                    .setDeleteIntent(deleteNotificationIntent)
                    .build()
                notificationBuilder.setBubbleMetadata(bubbleMetadata)
            }

            // Set shortcut ID and LocusId on API 29+ for Conversations & Bubbles
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                notificationBuilder.setShortcutId(chatGuid)
                notificationBuilder.setLocusId(LocusIdCompat(chatGuid))
            }

            // intent to open the main app
            val openSummaryIntent = PendingIntent.getActivity(
                context,
                0,
                Intent(context, MainActivity::class.java)
                    .putExtra("chatGuid", "-1")
                    .putExtra("notificationId", 0)
                    .putExtra("bubble", false)
                    .setType("OpenSummary"),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )

            val activeChildren = activeNotifications.filter {
                it.tag == Constants.newMessageNotificationTag && it.id != 0 && it.id != notificationId
            }
            val existingLines = activeChildren.mapNotNull { sbn ->
                val childStyle = NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(sbn.notification)
                val lastMsg = childStyle?.messages?.lastOrNull()
                if (lastMsg != null) {
                    val author = lastMsg.person?.name?.toString()?.takeIf { it.isNotBlank() }
                    if (author != null) "$author: ${lastMsg.text}" else lastMsg.text.toString()
                } else {
                    null
                }
            }
            val newSummaryLine = if (chatIsGroup) "$chatTitle ($contactName): $messageText" else "$contactName: $messageText"
            val summaryLines = buildSummaryLines(existingLines, newSummaryLine)
            val totalConversations = activeChildren.size + 1
            val inboxStyle = NotificationCompat.InboxStyle()
                .setBigContentTitle("$totalConversations active ${if (totalConversations == 1) "conversation" else "conversations"}")
                .setSummaryText("$totalConversations ${if (totalConversations == 1) "chat" else "chats"}")
            summaryLines.forEach { inboxStyle.addLine(it) }

            val publicSummaryNotification = NotificationCompat.Builder(context, channelId)
                .setSmallIcon(R.mipmap.ic_stat_icon)
                .setContentTitle(context.getString(R.string.app_name_en))
                .setContentText("$totalConversations new ${if (totalConversations == 1) "message" else "messages"}")
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setColor(4888294)
                .setNumber(totalConversations)
                .build()

            val summaryNotificationBuilder = NotificationCompat.Builder(context, channelId)
                .setSmallIcon(R.mipmap.ic_stat_icon)
                .setGroup(Constants.notificationGroupKey)
                .setGroupSummary(true)
                .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
                .setOnlyAlertOnce(true)
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setPublicVersion(publicSummaryNotification)
                .setContentIntent(openSummaryIntent)
                .setStyle(inboxStyle)
                .setNumber(totalConversations)
                .setColor(4888294)

            // Post child notification first so heads-up and Wear OS native bridge trigger immediately.
            notificationManager.notify(Constants.newMessageNotificationTag, notificationId, notificationBuilder.build())
            notificationManager.notify(Constants.newMessageNotificationTag, 0, summaryNotificationBuilder.build())
            result.success(null)
        }
    }
}