package com.wearbubbles.data

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WearReadReceiptGatingTest {

    @Test
    fun `shouldSendStandaloneReadReceipt allows read receipt only when privateMarkChatAsRead is enabled`() {
        assertTrue(ChatRepository.shouldSendStandaloneReadReceipt(privateMarkChatAsRead = true))
        assertFalse(ChatRepository.shouldSendStandaloneReadReceipt(privateMarkChatAsRead = false))
    }
}
