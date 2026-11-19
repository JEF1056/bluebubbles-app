package com.bluebubbles.messaging.services.notifications

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Build
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayOutputStream

@RunWith(AndroidJUnit4::class)
class NotificationShadeVisualTest {

    private lateinit var context: Context
    private lateinit var nm: NotificationManager

    private val noopResult = object : MethodChannel.Result {
        override fun success(result: Any?) {}
        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}
        override fun notImplemented() {}
    }

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        nm = context.getSystemService(NotificationManager::class.java)
        nm.cancelAll()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannelHandler.ensureChannelGroups(nm)
            if (nm.getNotificationChannel(NotificationChannelHandler.NEW_MESSAGES_CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        NotificationChannelHandler.NEW_MESSAGES_CHANNEL_ID,
                        "New Messages",
                        NotificationManager.IMPORTANCE_HIGH
                    ).apply { group = NotificationChannelHandler.GROUP_MESSAGES }
                )
            }
            if (nm.getNotificationChannel(NotificationChannelHandler.FACETIME_CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        NotificationChannelHandler.FACETIME_CHANNEL_ID,
                        "Incoming FaceTime Calls",
                        NotificationManager.IMPORTANCE_HIGH
                    ).apply { group = NotificationChannelHandler.GROUP_CALLS }
                )
            }
        }
    }

    private fun sampleAvatarBytes(bgColor: Int, initials: String): ByteArray {
        val size = 128
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = bgColor }
        canvas.drawCircle(size / 2f, size / 2f, size / 2f, paint)
        val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = 48f
            textAlign = Paint.Align.CENTER
            isFakeBoldText = true
        }
        val yPos = size / 2f - (textPaint.descent() + textPaint.ascent()) / 2f
        canvas.drawText(initials, size / 2f, yPos, textPaint)
        return ByteArrayOutputStream().use {
            bmp.compress(Bitmap.CompressFormat.PNG, 100, it)
            it.toByteArray()
        }
    }

    @Test
    fun postMessagingWithReaction() {
        val now = System.currentTimeMillis()
        val avatar = sampleAvatarBytes(Color.rgb(20, 126, 251), "AL")
        val args = mapOf<String, Any?>(
            "channel_id" to NotificationChannelHandler.NEW_MESSAGES_CHANNEL_ID,
            "chat_guid" to "iMessage;-;+15551234567",
            "chat_title" to "Alex Lin",
            "chat_is_group" to false,
            "chat_icon" to avatar,
            "message_text" to "Just landed! Meet at Gate B12?",
            "message_guid" to "msg-qa-reaction-1",
            "message_date" to now,
            "message_is_from_me" to false,
            "contact_name" to "Alex Lin",
            "contact_avatar" to avatar,
            "contact_key" to "+15551234567",
            "contact_uri" to "tel:+15551234567",
            "show_reaction_action" to true,
            "reaction_type" to "like",
            "chat_id" to 101,
            "historic_messages" to listOf(
                mapOf("text" to "Flight is boarding now", "date" to now - 180_000L, "is_from_me" to false),
                mapOf("text" to "Awesome, heading to the airport", "date" to now - 90_000L, "is_from_me" to true)
            )
        )
        CreateIncomingMessageNotification().handleMethodCall(
            MethodCall(CreateIncomingMessageNotification.tag, args),
            noopResult,
            context
        )
    }

    @Test
    fun postMessagingWithoutReaction() {
        val now = System.currentTimeMillis()
        val avatar = sampleAvatarBytes(Color.rgb(34, 197, 94), "MJ")
        val args = mapOf<String, Any?>(
            "channel_id" to NotificationChannelHandler.NEW_MESSAGES_CHANNEL_ID,
            "chat_guid" to "iMessage;-;+15559876543",
            "chat_title" to "Maya Jordan",
            "chat_is_group" to false,
            "chat_icon" to avatar,
            "message_text" to "Can you review the PR before 5pm?",
            "message_guid" to "msg-qa-mute-1",
            "message_date" to now,
            "message_is_from_me" to false,
            "contact_name" to "Maya Jordan",
            "contact_avatar" to avatar,
            "contact_key" to "+15559876543",
            "contact_uri" to "tel:+15559876543",
            "show_reaction_action" to false,
            "chat_id" to 102,
            "historic_messages" to listOf(
                mapOf("text" to "Pushed the latest fixes", "date" to now - 120_000L, "is_from_me" to false)
            )
        )
        CreateIncomingMessageNotification().handleMethodCall(
            MethodCall(CreateIncomingMessageNotification.tag, args),
            noopResult,
            context
        )
    }

    @Test
    fun postFaceTimeIncomingVideo() {
        val avatar = sampleAvatarBytes(Color.rgb(20, 126, 251), "AL")
        val args = mapOf<String, Any?>(
            "channel_id" to NotificationChannelHandler.FACETIME_CHANNEL_ID,
            "notification_id" to 201,
            "call_uuid" to "ft-qa-video-1",
            "title" to "FaceTime Video",
            "body" to "Incoming FaceTime Video",
            "is_video" to true,
            "is_ongoing" to false,
            "caller_address" to "alex@example.com",
            "caller" to "Alex Lin",
            "caller_avatar" to avatar
        )
        CreateIncomingFaceTimeNotification().handleMethodCall(
            MethodCall(CreateIncomingFaceTimeNotification.tag, args),
            noopResult,
            context
        )
    }

    @Test
    fun postFaceTimeIncomingAudio() {
        val avatar = sampleAvatarBytes(Color.rgb(34, 197, 94), "MJ")
        val args = mapOf<String, Any?>(
            "channel_id" to NotificationChannelHandler.FACETIME_CHANNEL_ID,
            "notification_id" to 202,
            "call_uuid" to "ft-qa-audio-1",
            "title" to "FaceTime Audio",
            "body" to "Incoming FaceTime Audio",
            "is_video" to false,
            "is_ongoing" to false,
            "caller_address" to "+15559876543",
            "caller" to "Maya Jordan",
            "caller_avatar" to avatar
        )
        CreateIncomingFaceTimeNotification().handleMethodCall(
            MethodCall(CreateIncomingFaceTimeNotification.tag, args),
            noopResult,
            context
        )
    }

    @Test
    fun postFaceTimeOngoingCall() {
        val avatar = sampleAvatarBytes(Color.rgb(20, 126, 251), "AL")
        val args = mapOf<String, Any?>(
            "channel_id" to NotificationChannelHandler.FACETIME_CHANNEL_ID,
            "notification_id" to 203,
            "call_uuid" to "ft-qa-ongoing-1",
            "title" to "FaceTime Video",
            "body" to "Ongoing FaceTime Call",
            "is_video" to true,
            "is_ongoing" to true,
            "caller_address" to "alex@example.com",
            "caller" to "Alex Lin",
            "caller_avatar" to avatar
        )
        CreateIncomingFaceTimeNotification().handleMethodCall(
            MethodCall(CreateIncomingFaceTimeNotification.tag, args),
            noopResult,
            context
        )
    }
}
