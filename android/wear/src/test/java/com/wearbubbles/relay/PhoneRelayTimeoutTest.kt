package com.wearbubbles.relay

import com.wearbubbles.data.MessageRepository
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.concurrent.ConcurrentHashMap

class PhoneRelayTimeoutTest {
    @Test
    fun `send timeout exceeds server transaction timeout`() {
        assertTrue(PhoneRelayClient.SEND_TIMEOUT_MS > 120_000L)
    }

    @Test
    fun `timed out send returns non-null failure so caller never retries same tempGuid on direct server`() {
        val result = PhoneRelayClient.orTimedOutResult(
            result = null,
            requestId = "req-1",
            tempGuid = "temp-123"
        )
        assertFalse(result.success)
        assertTrue(result.timedOut)
        assertEquals("req-1", result.requestId)
        assertEquals("temp-123", result.tempGuid)
        assertEquals("Phone relay timed out", result.error)
    }

    @Test
    fun `completed relay result passes through unchanged`() {
        val expected = SendResultPayload(
            requestId = "req-1",
            tempGuid = "temp-123",
            success = true
        )
        val actual = PhoneRelayClient.orTimedOutResult(
            result = expected,
            requestId = "req-1",
            tempGuid = "temp-123"
        )
        assertFalse(actual.timedOut)
        assertSame(expected, actual)
    }

    @Test
    fun `requestAttachmentDeduped completes null immediately when pending request fails`() = runBlocking {
        val pending = ConcurrentHashMap<String, CompletableDeferred<File?>>()
        val waiter = async {
            PhoneRelayClient.requestAttachmentDeduped(
                attachmentGuid = "att-fail",
                pending = pending,
                cachedFile = { null },
                sendRequest = { true },
                timeoutMs = 20_000L
            )
        }
        delay(20)
        pending.remove("att-fail")?.complete(null)
        assertNull(waiter.await())
        assertTrue(pending.isEmpty())
    }

    @Test
    fun `computeAckWaitBudgetMs subtracts handoff latency from ceiling without cancelling send`() {
        assertEquals(
            1_000L,
            PhoneRelayClient.computeAckWaitBudgetMs(
                timeoutMs = MessageRepository.NOTIFICATION_REPLY_WAIT_MS,
                totalCeilingMs = MessageRepository.NOTIFICATION_REPLY_CEILING_MS,
                elapsedSinceStartMs = 7_000L
            )
        )
        assertEquals(
            0L,
            PhoneRelayClient.computeAckWaitBudgetMs(
                timeoutMs = MessageRepository.NOTIFICATION_REPLY_WAIT_MS,
                totalCeilingMs = MessageRepository.NOTIFICATION_REPLY_CEILING_MS,
                elapsedSinceStartMs = 8_500L
            )
        )
        assertEquals(
            5_000L,
            PhoneRelayClient.computeAckWaitBudgetMs(
                timeoutMs = 5_000L,
                totalCeilingMs = null,
                elapsedSinceStartMs = 9_000L
            )
        )
    }
}
