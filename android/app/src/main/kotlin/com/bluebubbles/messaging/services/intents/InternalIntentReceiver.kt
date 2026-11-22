package com.bluebubbles.messaging.services.intents

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.app.RemoteInput
import androidx.core.content.ContextCompat
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.MainActivity
import com.bluebubbles.messaging.services.backend_ui_interop.DartWorkManager
import com.bluebubbles.messaging.services.network.HttpService
import com.bluebubbles.messaging.services.notifications.CreateIncomingMessageNotification
import com.bluebubbles.messaging.services.notifications.DeleteNotificationHandler
import com.bluebubbles.messaging.services.telecom.FaceTimeConnectionService
import com.bluebubbles.messaging.services.telecom.FaceTimeRoutingPolicy
import com.bluebubbles.messaging.services.wear.WearSyncManager
import com.bluebubbles.messaging.utils.PersistentLog
import com.bluebubbles.messaging.utils.SettingsHelper
import com.bluebubbles.messaging.utils.Utils
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import java.io.File
import java.net.URLEncoder
import java.util.UUID


class InternalIntentReceiver: BroadcastReceiver() {
    @SuppressLint("NewApi")
    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null || intent == null) return

        PersistentLog.d(context, Constants.logTag, "Received internal intent ${intent.type}, handling...")
        when (intent.type) {
            "DeleteNotification" -> {
                val notificationId: Int = intent.getIntExtra("notificationId", 0)
                val tag: String? = intent.getStringExtra("tag")
                val chatGuid: String? = intent.getStringExtra("chatGuid")
                DeleteNotificationHandler().deleteNotification(context, notificationId, tag, chatGuidFallback = chatGuid)
            }
            "DeclineFaceTime" -> {
                val notificationId: Int = intent.getIntExtra("notificationId", 0)
                val tag: String? = intent.getStringExtra("tag")
                val callUuid: String? = intent.getStringExtra("callUuid")
                DeleteNotificationHandler().deleteNotification(context, notificationId, tag, callUuidFallback = callUuid)
                if (!callUuid.isNullOrBlank()) {
                    FaceTimeConnectionService.endCall(callUuid, onlyIfRinging = false, recordIfPending = true)
                    WearSyncManager.notifyCallEnded(context, callUuid)
                }
                if (FaceTimeRoutingPolicy.shouldTriggerServerDecline(callUuid) && callUuid != null) {
                    val pendingResult = goAsync()
                    HttpService(context).declineFaceTimeCall(
                        callUuid = callUuid,
                        onSuccess = { pendingResult.finish() },
                        onError = { pendingResult.finish() }
                    )
                }
            }
            "AnswerFaceTimeAudio" -> {
                val notificationId: Int = intent.getIntExtra("notificationId", 0)
                val tag: String? = intent.getStringExtra("tag")
                val callUuid: String? = intent.getStringExtra("callUuid")
                val callerName: String = intent.getStringExtra("callerName") ?: "Unknown Caller"
                val callerAddress: String? = intent.getStringExtra("callerAddress")
                val isTelephony: Boolean = intent.getBooleanExtra("isTelephony", false)
                DeleteNotificationHandler().deleteNotification(context, notificationId, tag, callUuidFallback = callUuid)
                if (!callUuid.isNullOrBlank()) {
                    val routed = FaceTimeConnectionService.addIncomingCall(
                        context = context,
                        callUuid = callUuid,
                        callerName = callerName,
                        address = callerAddress,
                        autoAnswer = true,
                        isTelephony = isTelephony
                    )
                    if (!routed) {
                        val launch = Intent(context, MainActivity::class.java).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            putExtra("callUuid", callUuid)
                            putExtra("answer", true)
                            putExtra("audioOnly", true)
                            putExtra("isTelephony", isTelephony)
                            putExtra("caller", callerName)
                            type = "AnswerFaceTime"
                        }
                        context.startActivity(launch)
                    }
                }
            }
            "OpenCallingAccounts" -> {
                val notificationId: Int = intent.getIntExtra("notificationId", 0)
                val tag: String? = intent.getStringExtra("tag")
                if (notificationId != 0) {
                    val nm = context.getSystemService(NotificationManager::class.java)
                    if (tag != null) nm?.cancel(tag, notificationId) else nm?.cancel(notificationId)
                }
                FaceTimeConnectionService.openCallingAccountsSettings(context)
            }
            "MarkChatRead" -> {
                val notificationId: Int = intent.getIntExtra("notificationId", 0)
                val chatGuid: String? = intent.getStringExtra("chatGuid")
                val tag: String? = intent.getStringExtra("tag")
                DeleteNotificationHandler().deleteNotification(context, notificationId, tag, chatGuidFallback = chatGuid, keepBubble = true)
                DartWorkManager.createWorker(context, intent.type!!, hashMapOf("chatGuid" to chatGuid)) {}
            }
            "MuteChat" -> {
                val notificationId: Int = intent.getIntExtra("notificationId", 0)
                val chatGuid: String? = intent.getStringExtra("chatGuid")
                val tag: String? = intent.getStringExtra("tag")
                DeleteNotificationHandler().deleteNotification(context, notificationId, tag, chatGuidFallback = chatGuid)
                if (!chatGuid.isNullOrEmpty()) {
                    DartWorkManager.createWorker(context, "MuteChat", hashMapOf("chatGuid" to chatGuid)) {}
                }
            }
            "ReplyChat" -> {
                val notificationId: Int = intent.getIntExtra("notificationId", 0)
                val chatGuid: String? = intent.getStringExtra("chatGuid")
                val messageGuid: String? = intent.getStringExtra("messageGuid")
                val dataReply = resolveFirstDataResult(RemoteInput.getDataResultsFromIntent(intent, "text_reply"))
                if (dataReply != null && !chatGuid.isNullOrBlank()) {
                    val (mimeType, dataUri) = dataReply
                    val ext = extensionForMime(mimeType)
                    val pendingResult = goAsync()
                    CoroutineScope(Dispatchers.IO).launch {
                        val tempFile = File(context.cacheDir, "reply_media_${System.currentTimeMillis()}.$ext")
                        var succeeded = false
                        try {
                            val copied = try {
                                context.contentResolver.openInputStream(dataUri)?.use { input ->
                                    tempFile.outputStream().use { output -> input.copyTo(output) }
                                    true
                                } ?: false
                            } catch (e: Exception) {
                                PersistentLog.e(context, Constants.logTag, "Failed to read RemoteInput data URI: ${e.message}")
                                false
                            }
                            if (!copied) {
                                return@launch
                            }
                            val settings = SettingsHelper(context)
                            if (settings.hasServerUrl() && settings.hasAuthKey()) {
                                val client = WearSyncManager.buildOkHttpClient(settings, minReadTimeoutMs = 130_000L)
                                val method = if (settings.enablePrivateAPI && settings.privateAPIAttachmentSend) {
                                    "private-api"
                                } else {
                                    "apple-script"
                                }
                                val tempGuid = "temp-${UUID.randomUUID()}"
                                val multipart = MultipartBody.Builder()
                                    .setType(MultipartBody.FORM)
                                    .addFormDataPart("chatGuid", chatGuid)
                                    .addFormDataPart("tempGuid", tempGuid)
                                    .addFormDataPart("name", tempFile.name)
                                    .addFormDataPart("method", method)
                                    .addFormDataPart(
                                        "attachment",
                                        tempFile.name,
                                        tempFile.asRequestBody(mimeType.toMediaType())
                                    )
                                    .build()
                                val url = "${settings.apiRoot}/message/attachment?password=${URLEncoder.encode(settings.guidAuthKey, "UTF-8")}"
                                client.newCall(Request.Builder().url(url).post(multipart).build()).execute().use { resp ->
                                    succeeded = resp.isSuccessful
                                    if (!succeeded) {
                                        PersistentLog.e(context, Constants.logTag, "Media reply upload failed with HTTP ${resp.code}")
                                    }
                                }
                            } else {
                                PersistentLog.w(context, Constants.logTag, "Missing server settings for media reply")
                            }
                        } catch (e: Exception) {
                            PersistentLog.e(context, Constants.logTag, "Media reply upload error: ${e.message}")
                        } finally {
                            tempFile.delete()
                            updateReplyNotification(
                                context = context,
                                notificationId = notificationId,
                                replyText = if (succeeded) "Sent an image" else "Media reply",
                                mediaMime = if (succeeded) mimeType else null,
                                mediaUri = if (succeeded) dataUri else null,
                                succeeded = succeeded
                            )
                            pendingResult.finish()
                        }
                    }
                    return
                }

                val replyText = RemoteInput.getResultsFromIntent(intent)?.getString("text_reply") ?: return

                DartWorkManager.createWorker(context, intent.type!!, hashMapOf("chatGuid" to chatGuid, "messageGuid" to messageGuid, "text" to replyText)) { succeeded ->
                    CoroutineScope(Dispatchers.IO).launch {
                        updateReplyNotification(context, notificationId, replyText = replyText, succeeded = succeeded)
                    }
                }
            }
            "LikeMessage" -> {
                val notificationId: Int = intent.getIntExtra("notificationId", 0)
                val chatGuid: String? = intent.getStringExtra("chatGuid")
                val messageGuid: String? = intent.getStringExtra("messageGuid")
                val messageText: String? = intent.getStringExtra("messageText")
                val reactionType: String = intent.getStringExtra("reactionType") ?: "like"
                val tag: String? = intent.getStringExtra("tag")
                val channelId: String? = intent.getStringExtra("channelId")
                val reactionSent: Boolean = intent.getBooleanExtra("reactionSent", false)
                
                if (chatGuid.isNullOrEmpty() || messageGuid.isNullOrEmpty() || messageText.isNullOrEmpty()) {
                    PersistentLog.e(context, Constants.logTag, "Missing required parameters for LikeMessage")
                    return
                }
                
                // Show "Sending..." while processing
                updateReactionButton(
                    context, 
                    notificationId, 
                    chatGuid, 
                    messageGuid, 
                    messageText, 
                    reactionType, 
                    reactionSent,
                    channelId,
                    tag,
                    buttonText = "Sending..."
                )
                
                // Use the new HttpService to send the tapback without Flutter engine
                // If reaction was already sent, prefix with "-" to remove it
                val reactionToSend = if (reactionSent) "-$reactionType" else reactionType
                val pendingResult = goAsync()
                val httpService = HttpService(context)
                httpService.sendTapback(
                    chatGuid = chatGuid,
                    selectedMessageText = messageText,
                    selectedMessageGuid = messageGuid,
                    reaction = reactionToSend,
                    onSuccess = { response ->
                        try {
                            val actionName = if (reactionSent) "removed" else "sent"
                            PersistentLog.i(context, Constants.logTag, "Reaction ($reactionToSend) $actionName successfully")

                            // Update the notification to toggle the button label
                            updateReactionButton(
                                context,
                                notificationId,
                                chatGuid,
                                messageGuid,
                                messageText,
                                reactionType,
                                !reactionSent,
                                channelId,
                                tag
                            )
                        } finally {
                            pendingResult.finish()
                        }
                    },
                    onError = { error ->
                        try {
                            PersistentLog.e(context, Constants.logTag, "Failed to send reaction: $error")

                            // Show error state, then revert after a delay
                            updateReactionButton(
                                context,
                                notificationId,
                                chatGuid,
                                messageGuid,
                                messageText,
                                reactionType,
                                reactionSent,
                                channelId,
                                tag,
                                buttonText = "Error - Retry"
                            )
                        } finally {
                            pendingResult.finish()
                        }
                    }
                )
            }
        }
    }

    @SuppressLint("NewApi")
    private fun updateReplyNotification(
        context: Context,
        notificationId: Int,
        replyText: String,
        mediaMime: String? = null,
        mediaUri: Uri? = null,
        succeeded: Boolean
    ) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            CoroutineScope(Dispatchers.IO).launch {
                updateReplyNotification(context, notificationId, replyText, mediaMime, mediaUri, succeeded)
            }
            return
        }
        val notificationManager = context.getSystemService(NotificationManager::class.java)
        PersistentLog.d(context, Constants.logTag, "Fetching existing notification values")
        val chatNotification = notificationManager.activeNotifications.lastOrNull {
            matchesMessageNotification(it.tag, it.id, notificationId)
        }
        if (chatNotification == null) {
            PersistentLog.e(context, Constants.logTag, "Could not find notification with ID $notificationId")
            return
        }
        val oldBuilder = Notification.Builder.recoverBuilder(context, chatNotification.notification)
        val oldStyle = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            oldBuilder.style as? Notification.MessagingStyle
        } else {
            val temp = NotificationCompat.MessagingStyle.extractMessagingStyleFromNotification(chatNotification.notification)
            if (temp != null) {
                Notification.MessagingStyle(Person.Builder()
                    .setName(temp.user.name)
                    .setKey(temp.user.key ?: "me")
                    .setIcon(temp.user.icon?.toIcon(context))
                    .build()
                )
            } else null
        }

        PersistentLog.d(context, Constants.logTag, "Creating sender and message object for the user-created reply")
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", 0)

        val messagingStyle = oldStyle ?: run {
            PersistentLog.w(context, Constants.logTag, "Could not extract MessagingStyle, creating new one for reply")
            Notification.MessagingStyle(Person.Builder()
                .setName(prefs.getString("userName", "You"))
                .setKey("me")
                .build()
            )
        }
        // Pass null Person so Android MessagingStyle treats this reply as from messagingStyle.user
        // instead of a remote sender (which would overwrite the 1:1 notification title with userName).
        val msg = Notification.MessagingStyle.Message(
            if (succeeded) replyText else "⚠ Not sent: $replyText",
            System.currentTimeMillis(),
            null as Person?
        )
        if (succeeded && mediaMime != null && mediaUri != null) {
            msg.setData(mediaMime, mediaUri)
        }
        messagingStyle.addMessage(msg)

        PersistentLog.d(context, Constants.logTag, "Posting the user-created reply")
        oldBuilder.setStyle(messagingStyle)
        oldBuilder.setOnlyAlertOnce(true)
        oldBuilder.setGroupAlertBehavior(Notification.GROUP_ALERT_CHILDREN)
        if (succeeded && mediaMime == null && replyText.isNotBlank() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val existingHistory = chatNotification.notification.extras
                ?.getCharSequenceArray(Notification.EXTRA_REMOTE_INPUT_HISTORY)
                ?.toList()
                ?: emptyList()
            val updatedHistory = (listOf<CharSequence>(replyText) + existingHistory).take(5).toTypedArray()
            oldBuilder.setRemoteInputHistory(updatedHistory)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            PersistentLog.w(context, Constants.logTag, "POST_NOTIFICATIONS permission not granted; skipping reply update")
            return
        }
        notificationManager.notify(Constants.newMessageNotificationTag, notificationId, oldBuilder.build())
    }

    private fun updateReactionButton(
        context: Context,
        notificationId: Int,
        chatGuid: String,
        messageGuid: String,
        messageText: String,
        reactionType: String,
        reactionSent: Boolean,
        channelId: String?,
        tag: String?,
        buttonText: String? = null
    ) {
        val notificationManager = context.getSystemService(NotificationManager::class.java)
        
        // Get the existing notification
        val existingNotification = notificationManager.activeNotifications.firstOrNull { 
            it.id == notificationId && it.tag == tag 
        } ?: return
        
        // Rebuild the notification with updated action
        val oldBuilder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            Notification.Builder.recoverBuilder(context, existingNotification.notification)
        } else {
            return // Can't update on older versions
        }
        
        // Create new extras with updated reaction state
        val extras = Bundle()
        extras.putString("chatGuid", chatGuid)
        extras.putString("messageGuid", messageGuid)
        extras.putString("channelId", channelId)
        extras.putString("tag", tag)
        extras.putBoolean("reactionSent", reactionSent)
        
        // Create the updated reaction intent
        val likeIntent = PendingIntent.getBroadcast(
            context,
            notificationId + CreateIncomingMessageNotification.PENDING_INTENT_LIKE_OFFSET,
            Intent(context, InternalIntentReceiver::class.java)
                .putExtras(extras)
                .putExtra("notificationId", notificationId)
                .putExtra("messageText", messageText)
                .putExtra("reactionType", reactionType)
                .putExtra("reactionSent", reactionSent)
                .setType("LikeMessage"),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        
        // Update button label based on state
        val actionTitle = buttonText ?: reactionButtonTitle(reactionType, reactionSent)
        
        val likeAction = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Notification.Action.Builder(
                null,
                actionTitle,
                likeIntent
            ).apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    setSemanticAction(Notification.Action.SEMANTIC_ACTION_THUMBS_UP)
                }
            }.build()
        } else {
            return
        }
        
        // Preserve all existing actions (Mark As Read, Reply w/ RemoteInput+choices, Mute, WearableExtender),
        // replacing only the reaction action in-place.
        val existingActions = existingNotification.notification.actions
        if (existingActions != null && existingActions.isNotEmpty()) {
            val updatedActions = replaceReactionAction(existingActions.toList(), likeAction) { action ->
                isReactionAction(
                    title = action.title?.toString(),
                    semanticAction = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) action.semanticAction else null
                )
            }
            oldBuilder.setActions(*updatedActions.toTypedArray())
        } else {
            oldBuilder.setActions(likeAction)
        }
        
        // Post the updated notification
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            PersistentLog.w(context, Constants.logTag, "POST_NOTIFICATIONS permission not granted; skipping reaction update")
            return
        }
        oldBuilder.setOnlyAlertOnce(true)
        notificationManager.notify(tag, notificationId, oldBuilder.build())
    }

    companion object {
        internal fun extensionForMime(mimeType: String): String =
            com.bluebubbles.messaging.services.intents.extensionForMime(mimeType)

        internal fun reactionButtonTitle(reactionType: String, reactionSent: Boolean): String =
            com.bluebubbles.messaging.services.intents.reactionButtonTitle(reactionType, reactionSent)

        internal fun matchesMessageNotification(tag: String?, id: Int, targetId: Int): Boolean =
            com.bluebubbles.messaging.services.intents.matchesMessageNotification(tag, id, targetId)

        internal fun isReactionAction(title: String?, semanticAction: Int?): Boolean =
            com.bluebubbles.messaging.services.intents.isReactionAction(title, semanticAction)

        internal fun <T> replaceReactionAction(
            actions: List<T>,
            newReactionAction: T,
            predicate: (T) -> Boolean
        ): List<T> = com.bluebubbles.messaging.services.intents.replaceReactionAction(
            actions,
            newReactionAction,
            predicate
        )
    }
}