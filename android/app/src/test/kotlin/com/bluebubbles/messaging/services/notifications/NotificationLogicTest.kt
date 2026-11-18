package com.bluebubbles.messaging.services.notifications

import android.app.Notification
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.services.intents.InternalIntentReceiver
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationLogicTest {
    @Test
    fun `shouldRecreateNewMessagesChannel triggers once for DND or vibration migration`() {
        assertFalse(
            NotificationChannelHandler.shouldRecreateNewMessagesChannel(
                exists = false,
                shouldVibrate = false,
                vibrationMigrated = false,
                canBypassDnd = true,
                dndMigrated = false
            )
        )
        assertTrue(
            NotificationChannelHandler.shouldRecreateNewMessagesChannel(
                exists = true,
                shouldVibrate = true,
                vibrationMigrated = true,
                canBypassDnd = true,
                dndMigrated = false
            )
        )
        assertFalse(
            NotificationChannelHandler.shouldRecreateNewMessagesChannel(
                exists = true,
                shouldVibrate = true,
                vibrationMigrated = true,
                canBypassDnd = true,
                dndMigrated = true
            )
        )
        assertTrue(
            NotificationChannelHandler.shouldRecreateNewMessagesChannel(
                exists = true,
                shouldVibrate = false,
                vibrationMigrated = false,
                canBypassDnd = false,
                dndMigrated = true
            )
        )
    }

    @Test
    fun `resolveTargetChannelId routes to conversation channel only when conversationId matches chatGuid`() {
        val base = "com.bluebubbles.new_messages"
        val chatGuid = "iMessage;-;+15551234567"

        assertEquals(
            chatGuid,
            CreateIncomingMessageNotification.resolveTargetChannelId(base, chatGuid, chatGuid, chatGuid)
        )
        assertEquals(
            base,
            CreateIncomingMessageNotification.resolveTargetChannelId(base, base, null, chatGuid)
        )
        assertEquals(
            base,
            CreateIncomingMessageNotification.resolveTargetChannelId(base, null, null, chatGuid)
        )
    }

    @Test
    fun `buildSummaryLines caps at maxLines and drops blank lines`() {
        val lines = CreateIncomingMessageNotification.buildSummaryLines(
            existingLines = listOf("A: 1", " ", "B: 2", "C: 3", "D: 4", "E: 5"),
            newLine = "F: 6",
            maxLines = 5
        )
        assertEquals(listOf("B: 2", "C: 3", "D: 4", "E: 5", "F: 6"), lines)
    }

    @Test
    fun `pending intent offsets for like and mute do not collide with adjacent chat IDs or existing offsets`() {
        val likeOffset = CreateIncomingMessageNotification.PENDING_INTENT_LIKE_OFFSET
        val muteOffset = CreateIncomingMessageNotification.PENDING_INTENT_MUTE_OFFSET
        assertEquals(400000, likeOffset)
        assertEquals(500000, muteOffset)
        assertNotEquals(1, likeOffset)
        assertNotEquals(likeOffset, muteOffset)
        val existingOffsets = setOf(
            Constants.pendingIntentOpenChatOffset,
            Constants.pendingIntentMarkReadOffset,
            Constants.pendingIntentOpenBubbleOffset,
            Constants.pendingIntentDeleteNotificationOffset
        )
        assertFalse(likeOffset in existingOffsets)
        assertFalse(muteOffset in existingOffsets)
    }

    @Test
    fun `reactionButtonTitle toggles like and love labels`() {
        assertEquals("Like", InternalIntentReceiver.reactionButtonTitle("like", false))
        assertEquals("Un-Like", InternalIntentReceiver.reactionButtonTitle("like", true))
        assertEquals("Love", InternalIntentReceiver.reactionButtonTitle("love", false))
        assertEquals("Un-Love", InternalIntentReceiver.reactionButtonTitle("love", true))
    }

    @Test
    fun `replaceReactionAction preserves Mark As Read, Reply, and Mute actions`() {
        val actions = listOf("Mark As Read", "Reply", "Like", "Mute")
        val updated = InternalIntentReceiver.replaceReactionAction(actions, "Un-Like") { title ->
            InternalIntentReceiver.isReactionAction(title, null)
        }
        assertEquals(listOf("Mark As Read", "Reply", "Un-Like", "Mute"), updated)
        assertTrue(InternalIntentReceiver.isReactionAction("Custom", Notification.Action.SEMANTIC_ACTION_THUMBS_UP))
        assertFalse(InternalIntentReceiver.isReactionAction("Mute", Notification.Action.SEMANTIC_ACTION_MUTE))
    }

    @Test
    fun `shouldOnlyAlertOnce suppresses sound on reaction, edit, fromMe, or explicit flag`() {
        assertFalse(
            CreateIncomingMessageNotification.shouldOnlyAlertOnce(
                messageIsFromMe = false,
                isReaction = false,
                isEdit = false,
                explicitOnlyAlertOnce = false
            )
        )
        assertTrue(
            CreateIncomingMessageNotification.shouldOnlyAlertOnce(
                messageIsFromMe = false,
                isReaction = true,
                isEdit = false,
                explicitOnlyAlertOnce = false
            )
        )
        assertTrue(
            CreateIncomingMessageNotification.shouldOnlyAlertOnce(
                messageIsFromMe = false,
                isReaction = false,
                isEdit = true,
                explicitOnlyAlertOnce = false
            )
        )
        assertTrue(
            CreateIncomingMessageNotification.shouldOnlyAlertOnce(
                messageIsFromMe = true,
                isReaction = false,
                isEdit = false,
                explicitOnlyAlertOnce = false
            )
        )
        assertTrue(
            CreateIncomingMessageNotification.shouldOnlyAlertOnce(
                messageIsFromMe = false,
                isReaction = false,
                isEdit = false,
                explicitOnlyAlertOnce = true
            )
        )
    }

    @Test
    fun `shouldCancelSummary returns true only when summary remains with no child notifications`() {
        val tag = Constants.newMessageNotificationTag
        assertTrue(
            com.bluebubbles.messaging.services.wear.WearSyncManager.shouldCancelSummary(
                listOf(tag to 0),
                tag
            )
        )
        assertFalse(
            com.bluebubbles.messaging.services.wear.WearSyncManager.shouldCancelSummary(
                listOf(tag to 0, tag to 42),
                tag
            )
        )
        assertFalse(
            com.bluebubbles.messaging.services.wear.WearSyncManager.shouldCancelSummary(
                emptyList(),
                tag
            )
        )
    }

    @Test
    fun `resolveDismissedChatGuid falls back to intent extra when notification is already removed`() {
        assertEquals(
            "iMessage;-;+15551234567",
            DeleteNotificationHandler.resolveDismissedChatGuid("iMessage;-;+15551234567", "other")
        )
        assertEquals(
            "iMessage;-;+15551234567",
            DeleteNotificationHandler.resolveDismissedChatGuid(null, "iMessage;-;+15551234567")
        )
        assertEquals(
            "iMessage;-;+15551234567",
            DeleteNotificationHandler.resolveDismissedChatGuid("", "iMessage;-;+15551234567")
        )
        assertEquals(null, DeleteNotificationHandler.resolveDismissedChatGuid(null, ""))
    }
}
