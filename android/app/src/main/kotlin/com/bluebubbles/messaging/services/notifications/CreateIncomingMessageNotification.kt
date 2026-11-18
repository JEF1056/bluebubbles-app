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
        ): String {
            return if (!convChannelId.isNullOrEmpty() && convId == chatGuid) {
                convChannelId
            } else {
                baseChannelId
            }
        }

        internal fun buildPerson(
            name: String,
            icon: IconCompat?,
            uri: String?,
            key: String?,
            isImportant: Boolean
        ): Person {
            val builder = Person.Builder()
                .setName(name)
                .setImportant(isImportant)
            if (icon != null) {
                builder.setIcon(icon)
            }
            if (!uri.isNullOrEmpty()) {
                builder.setUri(uri)
            }
            if (!key.isNullOrEmpty()) {
                builder.setKey(key)
            }
            return builder.build()
        }

        internal fun buildSummaryLines(
            existingLines: List<String>,
            newLine: String,
            maxLines: Int = 5
        ): List<String> {
            val combined = existingLines.filter { it.isNotBlank() } + listOf(newLine).filter { it.isNotBlank() }
            return if (combined.size <= maxLines) combined else combined.takeLast(maxLines)
        }

        internal fun shouldOnlyAlertOnce(
            messageIsFromMe: Boolean,
            isReaction: Boolean,
            isEdit: Boolean,
            explicitOnlyAlertOnce: Boolean
        ): Boolean = messageIsFromMe || isReaction || isEdit || explicitOnlyAlertOnce
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        // channel details
        val channelId: String = call.argument("channel_id")!!
        // chat details
        val chatGuid: String = call.argument("chat_guid")!!
        val chatTitle: String = call.argument("chat_title")!!
        val chatIsGroup: Boolean = call.argument("chat_is_group")!!
        val chatIcon: ByteArray? = call.argument("chat_icon")
        val chatBitmap = if ((chatIcon?.size ?: 0) == 0) null else Utils.getAdaptiveIconFromByteArray(chatIcon!!)
        // message details
        val messageText: String = call.argument("message_text")!!
        val messageGuid: String = call.argument("message_guid")!!
        val messageDate: Long = call.argument("message_date")!!
        val messageIsFromMe: Boolean = call.argument("message_is_from_me")!!
        // contact details
        val contactName: String = call.argument("contact_name")!!
        val contactIcon: ByteArray? = call.argument("contact_avatar")
        val contactBitmap = if ((contactIcon?.size ?: 0) == 0) null else Utils.getAdaptiveIconFromByteArray(contactIcon!!)
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

        // calculate a notification ID based on the chat database ID
        val notificationId: Int = call.argument("chat_id")!!

        val notificationManager = context.getSystemService(NotificationManager::class.java)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            PersistentLog.w(context, Constants.logTag, "POST_NOTIFICATIONS permission not granted; skipping message notification")
            return result.success(null)
        }
        
        // Synchronize to prevent duplicate notifications from concurrent calls
        synchronized(notificationLock) {
            // check if the message has already been posted as a notification
            val notificationPostedAlready = notificationManager.activeNotifications.firstOrNull { it.notification.extras.getString("chatGuid") == chatGuid && it.notification.extras.getString("messageGuid") == messageGuid } != null
            // don't double post a notification
            if (notificationPostedAlready) return result.success(null)
        }
        
        // this is used to copy the style, since the notification already exists
        val chatNotification = notificationManager.activeNotifications.lastOrNull { it.notification.extras.getString("chatGuid") == chatGuid && it.notification.extras.getString("channelId") == channelId }

        // Route to conversation-specific channel on Android 11+ when present
        val targetChannelId = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val convChannel = notificationManager.getNotificationChannel(channelId, chatGuid)
            resolveTargetChannelId(channelId, convChannel?.id, convChannel?.conversationId, chatGuid)
        } else {
            channelId
        }

        // build the sender, "You", and participant Person objects for DND contact breakthrough & shortcuts
        val resolvedSenderUri = PushShareTargetsHandler.resolveContactLookupUri(context, nativeContactId, contactUri)
        val sender = buildPerson(contactName, contactBitmap, resolvedSenderUri, contactKey, true)
        val youPerson = buildPerson(youName, null, null, youKey, false)
        val participantPersons = rawParticipants?.mapNotNull { p ->
            val pName = p["name"] as? String ?: return@mapNotNull null
            val pKey = p["key"] as? String
            val pUri = PushShareTargetsHandler.resolveContactLookupUri(
                context,
                p["native_contact_id"] as? String,
                p["uri"] as? String
            )
            val pIcon = if (pKey != null && pKey == contactKey) contactBitmap else null
            buildPerson(pName, pIcon, pUri, pKey, true)
        } ?: emptyList()

        PushShareTargetsHandler().pushShareTarget(
            context = context,
            name = chatTitle,
            guid = chatGuid,
            icon = chatIcon,
            contactUri = resolvedSenderUri,
            contactKey = contactKey,
            nativeContactId = nativeContactId,
            participants = participantPersons.ifEmpty { null }
        )

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
            PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
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

        // intent for bubbling (create it even if not used, for future compatibility)
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
        val publicNotification = NotificationCompat.Builder(context, targetChannelId)
            .setSmallIcon(R.mipmap.ic_stat_icon)
            .setContentTitle(context.getString(R.string.app_name_en))
            .setContentText("New message")
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setColor(4888294)
            .setNumber(1)
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

        if (participantPersons.isNotEmpty()) {
            notificationBuilder.addPerson(sender)
            participantPersons.filter { it.key != sender.key }.forEach { notificationBuilder.addPerson(it) }
        } else {
            notificationBuilder.addPerson(sender)
        }

        val existingHistory = chatNotification?.notification?.extras?.getCharSequenceArray(Notification.EXTRA_REMOTE_INPUT_HISTORY)
        if (!existingHistory.isNullOrEmpty()) {
            notificationBuilder.setRemoteInputHistory(existingHistory)
        }

        // Conditionally add reaction action if enabled
        if (showReactionAction) {
            notificationBuilder.addAction(likeAction)
        }
        notificationBuilder.addAction(muteAction)

        // Build wearable extender
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

        // Set bubble metadata on API 29+ using bubbleIntent (BubbleActivity) + shortcutId below
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val bubbleMetadata = NotificationCompat.BubbleMetadata.Builder(bubbleIntent, chatBitmap ?: IconCompat.createWithResource(context, R.mipmap.ic_stat_icon))
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
            PendingIntent.FLAG_IMMUTABLE
        )

        val activeChildren = notificationManager.activeNotifications.filter {
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

        notificationManager.notify(Constants.newMessageNotificationTag, 0, summaryNotificationBuilder.build())
        notificationManager.notify(Constants.newMessageNotificationTag, notificationId, notificationBuilder.build())
        result.success(null)
    }
}