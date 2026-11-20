package com.wearbubbles

import com.wearbubbles.data.ChatRepository
import com.wearbubbles.data.MessageRepository
import com.wearbubbles.relay.PhoneRelayClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class OptWearDataTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    @Test
    fun `notification reply wait and ceiling stay within broadcast timeout`() {
        assertEquals(5_000L, MessageRepository.NOTIFICATION_REPLY_WAIT_MS)
        assertTrue(MessageRepository.NOTIFICATION_REPLY_CEILING_MS <= 10_000L)
        assertTrue(MessageRepository.NOTIFICATION_REPLY_CEILING_MS > MessageRepository.NOTIFICATION_REPLY_WAIT_MS)
    }

    @Test
    fun `phone relay cache and prune throttle constants are configured`() {
        assertEquals(15_000L, PhoneRelayClient.NODE_CACHE_TTL_MS)
        assertEquals(30_000L, PhoneRelayClient.PRUNE_INTERVAL_MS)
        assertEquals(20, PhoneRelayClient.PRUNE_WRITE_THRESHOLD)
    }

    @Test
    fun `timed out relay send result is marked timedOut without failing`() {
        val result = PhoneRelayClient.orTimedOutResult(
            result = null,
            requestId = "req-x01",
            tempGuid = "temp-x01"
        )
        assertTrue(result.timedOut)
        assertFalse(result.success)
        assertEquals("temp-x01", result.tempGuid)
    }

    @Test
    fun `pruneDirectory evicts oldest files above count or size cap`() {
        val dir = tempFolder.newFolder("avatars")
        val f1 = dir.resolve("a.img").apply { writeBytes(ByteArray(10)); setLastModified(1_000L) }
        val f2 = dir.resolve("b.img").apply { writeBytes(ByteArray(10)); setLastModified(2_000L) }
        val f3 = dir.resolve("c.img").apply { writeBytes(ByteArray(10)); setLastModified(3_000L) }

        PhoneRelayClient.pruneDirectory(dir, maxBytes = 25L, maxFiles = 2)

        assertFalse(f1.exists())
        assertTrue(f2.exists())
        assertTrue(f3.exists())
    }

    @Test
    fun `standalone read receipt gating remains strictly opt-in`() {
        assertTrue(ChatRepository.shouldSendStandaloneReadReceipt(privateMarkChatAsRead = true))
        assertFalse(ChatRepository.shouldSendStandaloneReadReceipt(privateMarkChatAsRead = false))
    }

    @Test
    fun `relayed message paging sentinel and page size match contract`() {
        assertTrue(MessageRepository.hasMoreRelayedMessages(-1))
        assertTrue(MessageRepository.hasMoreRelayedMessages(40))
        assertFalse(MessageRepository.hasMoreRelayedMessages(12))
    }
}
