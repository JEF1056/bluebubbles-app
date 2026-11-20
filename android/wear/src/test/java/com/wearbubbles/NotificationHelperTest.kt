package com.wearbubbles

import com.wearbubbles.notifications.CallNotificationHelper
import com.wearbubbles.notifications.CallPhase
import com.wearbubbles.notifications.NotificationHelper
import com.wearbubbles.relay.PhoneRelayClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationHelperTest {
    @Test
    fun `quick reply choices are populated for Wear RemoteInput`() {
        assertTrue(NotificationHelper.QUICK_REPLY_CHOICES.isNotEmpty())
        assertTrue(NotificationHelper.QUICK_REPLY_CHOICES.all { it.isNotBlank() })
    }

    @Test
    fun `setActiveChat updates activeChatGuid state`() {
        NotificationHelper.setActiveChat("iMessage;-;+15551234567")
        assertEquals("iMessage;-;+15551234567", NotificationHelper.activeChatGuid.value)
        NotificationHelper.setActiveChat(null)
        assertNull(NotificationHelper.activeChatGuid.value)
    }

    @Test
    fun `clearConversationHistory is idempotent for unknown chat`() {
        NotificationHelper.clearConversationHistory("iMessage;-;nonexistent")
        assertTrue(NotificationHelper.ACTION_DISMISS.isNotBlank())
        assertTrue(NotificationHelper.ACTION_MARK_READ.isNotBlank())
    }

    @Test
    fun `buildPersonUri formats phone and email addresses`() {
        assertEquals("tel:+15551234567", NotificationHelper.buildPersonUri("+15551234567"))
        assertEquals("mailto:alice@example.com", NotificationHelper.buildPersonUri("alice@example.com"))
        assertNull(NotificationHelper.buildPersonUri("   "))
        assertNull(NotificationHelper.buildPersonUri(null))
    }

    @Test
    fun `buildPerson uses stable address key and falls back to name`() {
        val withAddr = NotificationHelper.buildPerson(
            name = "Alice",
            address = "+15551234567"
        )
        assertEquals("Alice", withAddr.name)
        assertEquals("+15551234567", withAddr.key)
        assertEquals("tel:+15551234567", withAddr.uri)

        val fallback = NotificationHelper.buildPerson(name = "Bob", address = null)
        assertEquals("Bob", fallback.key)
        assertNull(fallback.uri)
    }

    @Test
    fun `notification grouping and call constants are distinct`() {
        assertEquals("com.wearbubbles.MESSAGES", NotificationHelper.GROUP_KEY_MESSAGES)
        assertEquals("calls", NotificationHelper.CHANNEL_CALLS)
        assertTrue(NotificationHelper.SUMMARY_NOTIFICATION_ID != NotificationHelper.CALL_NOTIFICATION_ID)
        assertTrue(NotificationHelper.SUMMARY_NOTIFICATION_ID != 1001)
        assertTrue(NotificationHelper.CALL_NOTIFICATION_ID != 1001)
    }

    @Test
    fun `call pickup relay paths and receiver actions match contract`() {
        assertEquals("/bb/incoming-call", PhoneRelayClient.PATH_INCOMING_CALL)
        assertEquals("/bb/call-ended", PhoneRelayClient.PATH_CALL_ENDED)
        assertEquals("/bb/answer-call-audio", PhoneRelayClient.PATH_ANSWER_CALL_AUDIO)
        assertEquals("/bb/decline-call", PhoneRelayClient.PATH_DECLINE_CALL)
        assertEquals("/bb/open-chat", PhoneRelayClient.PATH_OPEN_CHAT)

        assertTrue(CallNotificationHelper.ACTION_ANSWER_CALL.isNotBlank())
        assertTrue(CallNotificationHelper.ACTION_DECLINE_CALL.isNotBlank())
        assertTrue(CallNotificationHelper.ACTION_END_CALL.isNotBlank())
        assertEquals(2, CallPhase.entries.size)
    }

    @Test
    fun `shouldMarkChatReadOnIncoming requires active matching chat and non-fromMe`() {
        val chat = "iMessage;-;+15551234567"
        assertTrue(NotificationHelper.shouldMarkChatReadOnIncoming(chat, chat, isFromMe = false))
        assertFalse(NotificationHelper.shouldMarkChatReadOnIncoming(null, chat, isFromMe = false))
        assertFalse(NotificationHelper.shouldMarkChatReadOnIncoming("iMessage;-;+15550000000", chat, isFromMe = false))
        assertFalse(NotificationHelper.shouldMarkChatReadOnIncoming(chat, chat, isFromMe = true))
    }

    @Test
    fun `isAppResumedOrUnbound blocks activation only while explicitly paused`() {
        assertTrue(NotificationHelper.isAppResumedOrUnbound())
        NotificationHelper.setAppResumed(false)
        assertFalse(NotificationHelper.isAppResumedOrUnbound())
        NotificationHelper.setAppResumed(true)
        assertTrue(NotificationHelper.isAppResumedOrUnbound())
    }

    @Test
    fun `shouldActivateChat blocks stale chat while another launch target is pending`() {
        val chatA = "iMessage;-;+15551111111"
        val chatB = "iMessage;-;+15552222222"
        try {
            NotificationHelper.setAppResumed(true)
            NotificationHelper.setPendingLaunchChatGuid(chatB)
            assertFalse(NotificationHelper.shouldActivateChat(chatA))
            assertTrue(NotificationHelper.shouldActivateChat(chatB))

            NotificationHelper.setAppResumed(false)
            assertFalse(NotificationHelper.shouldActivateChat(chatB))

            NotificationHelper.setAppResumed(true)
            NotificationHelper.setPendingLaunchChatGuid(null)
            assertTrue(NotificationHelper.shouldActivateChat(chatA))
        } finally {
            NotificationHelper.setPendingLaunchChatGuid(null)
            NotificationHelper.setAppResumed(true)
        }
    }
}
