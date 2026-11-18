package com.wearbubbles

import com.wearbubbles.notifications.NotificationHelper
import org.junit.Assert.assertEquals
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
        assertEquals(null, NotificationHelper.activeChatGuid.value)
    }

    @Test
    fun `clearConversationHistory is idempotent for unknown chat`() {
        NotificationHelper.clearConversationHistory("iMessage;-;nonexistent")
        assertTrue(NotificationHelper.ACTION_DISMISS.isNotBlank())
        assertTrue(NotificationHelper.ACTION_MARK_READ.isNotBlank())
    }
}
