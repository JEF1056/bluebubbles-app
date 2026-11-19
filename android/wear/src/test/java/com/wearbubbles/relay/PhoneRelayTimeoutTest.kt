package com.wearbubbles.relay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

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
        assertSame(expected, actual)
    }
}
