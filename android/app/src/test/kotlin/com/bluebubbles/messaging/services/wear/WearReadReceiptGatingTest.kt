package com.bluebubbles.messaging.services.wear

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WearReadReceiptGatingTest {

    @Test
    fun `shouldSendWatchReadReceipt requires both enablePrivateAPI and privateMarkChatAsRead`() {
        assertTrue(WearSyncManager.shouldSendWatchReadReceipt(enablePrivateAPI = true, privateMarkChatAsRead = true))
        assertFalse(WearSyncManager.shouldSendWatchReadReceipt(enablePrivateAPI = false, privateMarkChatAsRead = true))
        assertFalse(WearSyncManager.shouldSendWatchReadReceipt(enablePrivateAPI = true, privateMarkChatAsRead = false))
        assertFalse(WearSyncManager.shouldSendWatchReadReceipt(enablePrivateAPI = false, privateMarkChatAsRead = false))
    }
}
