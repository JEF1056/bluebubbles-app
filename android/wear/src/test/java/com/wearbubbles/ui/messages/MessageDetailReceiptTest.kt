package com.wearbubbles.ui.messages

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.util.Locale

class MessageDetailReceiptTest {

    private val zone = ZoneOffset.UTC
    private val nowMs = ZonedDateTime.of(2026, 11, 20, 14, 0, 0, 0, zone).toInstant().toEpochMilli()
    private val todayTimeMs = ZonedDateTime.of(2026, 11, 20, 19, 51, 0, 0, zone).toInstant().toEpochMilli()
    private val yesterdayTimeMs = ZonedDateTime.of(2026, 11, 19, 19, 51, 0, 0, zone).toInstant().toEpochMilli()
    private val olderTimeMs = ZonedDateTime.of(2026, 11, 18, 19, 51, 0, 0, zone).toInstant().toEpochMilli()

    @Test
    fun `formatDetailTimestamp formats same-day yesterday and older days concisely`() {
        assertEquals("", formatDetailTimestamp(0L, nowMs = nowMs, zoneId = zone, locale = Locale.US))
        assertEquals("7:51 PM", formatDetailTimestamp(todayTimeMs, nowMs = nowMs, zoneId = zone, locale = Locale.US))
        assertEquals("Yesterday 7:51 PM", formatDetailTimestamp(yesterdayTimeMs, nowMs = nowMs, zoneId = zone, locale = Locale.US))
        assertEquals("Nov 18, 7:51 PM", formatDetailTimestamp(olderTimeMs, nowMs = nowMs, zoneId = zone, locale = Locale.US))
    }

    @Test
    fun `latest sent delivered and earlier last-read both shown while older read is hidden`() {
        val items = listOf(
            MessageReceiptCandidate("m1", isFromMe = true, sendFailed = false, isPending = false, dateRead = olderTimeMs),
            MessageReceiptCandidate("m2", isFromMe = true, sendFailed = false, isPending = false, dateRead = yesterdayTimeMs),
            MessageReceiptCandidate("m3", isFromMe = true, sendFailed = false, isPending = false, dateRead = 0L)
        )
        val flags = computeMessageReceiptFlags(items)
        assertEquals("m3", flags.latestOutgoingGuid)
        assertEquals("m2", flags.lastReadOutgoingGuid)
        assertNull(flags.latestIncomingGuid)

        val m1Status = resolveMessageDetailStatus(
            isFromMe = true, sendFailed = false, isPending = false,
            dateCreated = olderTimeMs, dateDelivered = olderTimeMs, dateRead = olderTimeMs,
            isLatestOutgoing = false, isLastReadOutgoing = false, isLatestIncoming = false,
            nowMs = nowMs, zoneId = zone, locale = Locale.US
        )!!
        assertFalse(m1Status.showAlways)
        assertEquals("Read · Nov 18, 7:51 PM", m1Status.label)

        val m2Status = resolveMessageDetailStatus(
            isFromMe = true, sendFailed = false, isPending = false,
            dateCreated = yesterdayTimeMs, dateDelivered = yesterdayTimeMs, dateRead = yesterdayTimeMs,
            isLatestOutgoing = false, isLastReadOutgoing = true, isLatestIncoming = false,
            nowMs = nowMs, zoneId = zone, locale = Locale.US
        )!!
        assertTrue(m2Status.showAlways)
        assertEquals(MessageDetailKind.READ, m2Status.kind)
        assertEquals("Read · Yesterday 7:51 PM", m2Status.label)

        val m3Status = resolveMessageDetailStatus(
            isFromMe = true, sendFailed = false, isPending = false,
            dateCreated = todayTimeMs, dateDelivered = todayTimeMs, dateRead = 0L,
            isLatestOutgoing = true, isLastReadOutgoing = false, isLatestIncoming = false,
            nowMs = nowMs, zoneId = zone, locale = Locale.US
        )!!
        assertTrue(m3Status.showAlways)
        assertEquals(MessageDetailKind.DELIVERED, m3Status.kind)
        assertEquals("Delivered · 7:51 PM", m3Status.label)
    }

    @Test
    fun `latest sent already read resolves once with showAlways true`() {
        val items = listOf(
            MessageReceiptCandidate("m1", isFromMe = true, sendFailed = false, isPending = false, dateRead = yesterdayTimeMs),
            MessageReceiptCandidate("m2", isFromMe = true, sendFailed = false, isPending = false, dateRead = todayTimeMs)
        )
        val flags = computeMessageReceiptFlags(items)
        assertEquals("m2", flags.latestOutgoingGuid)
        assertEquals("m2", flags.lastReadOutgoingGuid)

        val m2Status = resolveMessageDetailStatus(
            isFromMe = true, sendFailed = false, isPending = false,
            dateCreated = todayTimeMs, dateDelivered = todayTimeMs, dateRead = todayTimeMs,
            isLatestOutgoing = true, isLastReadOutgoing = true, isLatestIncoming = false,
            nowMs = nowMs, zoneId = zone, locale = Locale.US
        )!!
        assertTrue(m2Status.showAlways)
        assertEquals(MessageDetailKind.READ, m2Status.kind)
        assertEquals("Read · 7:51 PM", m2Status.label)
    }

    @Test
    fun `latest sent handles sent-only pending and failed states`() {
        val sentOnly = resolveMessageDetailStatus(
            isFromMe = true, sendFailed = false, isPending = false,
            dateCreated = todayTimeMs, dateDelivered = 0L, dateRead = 0L,
            isLatestOutgoing = true, isLastReadOutgoing = false, isLatestIncoming = false,
            nowMs = nowMs, zoneId = zone, locale = Locale.US
        )!!
        assertTrue(sentOnly.showAlways)
        assertEquals(MessageDetailKind.SENT, sentOnly.kind)
        assertEquals("Sent · 7:51 PM", sentOnly.label)

        val pending = resolveMessageDetailStatus(
            isFromMe = true, sendFailed = false, isPending = true,
            dateCreated = todayTimeMs, dateDelivered = 0L, dateRead = 0L,
            isLatestOutgoing = true, isLastReadOutgoing = false, isLatestIncoming = false,
            nowMs = nowMs, zoneId = zone, locale = Locale.US
        )!!
        assertTrue(pending.showAlways)
        assertEquals(MessageDetailKind.SENDING, pending.kind)
        assertEquals("Sending…", pending.label)

        val nonLatestPending = resolveMessageDetailStatus(
            isFromMe = true, sendFailed = false, isPending = true,
            dateCreated = todayTimeMs, dateDelivered = 0L, dateRead = 0L,
            isLatestOutgoing = false, isLastReadOutgoing = false, isLatestIncoming = false,
            nowMs = nowMs, zoneId = zone, locale = Locale.US
        )
        assertNull(nonLatestPending)

        val failed = resolveMessageDetailStatus(
            isFromMe = true, sendFailed = true, isPending = false,
            dateCreated = todayTimeMs, dateDelivered = 0L, dateRead = 0L,
            isLatestOutgoing = true, isLastReadOutgoing = false, isLatestIncoming = false,
            nowMs = nowMs, zoneId = zone, locale = Locale.US
        )!!
        assertTrue(failed.showAlways)
        assertEquals(MessageDetailKind.FAILED, failed.kind)
    }

    @Test
    fun `mixed sent and received highlights latest incoming and latest outgoing and last read`() {
        val items = listOf(
            MessageReceiptCandidate("r1", isFromMe = false, sendFailed = false, isPending = false, dateRead = 0L),
            MessageReceiptCandidate("s1", isFromMe = true, sendFailed = false, isPending = false, dateRead = yesterdayTimeMs),
            MessageReceiptCandidate("r2", isFromMe = false, sendFailed = false, isPending = false, dateRead = 0L),
            MessageReceiptCandidate("s2", isFromMe = true, sendFailed = false, isPending = false, dateRead = 0L)
        )
        val flags = computeMessageReceiptFlags(items)
        assertEquals("s2", flags.latestOutgoingGuid)
        assertEquals("s1", flags.lastReadOutgoingGuid)
        assertEquals("r2", flags.latestIncomingGuid)

        val r1Status = resolveMessageDetailStatus(
            isFromMe = false, sendFailed = false, isPending = false,
            dateCreated = olderTimeMs, dateDelivered = 0L, dateRead = 0L,
            isLatestOutgoing = false, isLastReadOutgoing = false, isLatestIncoming = false,
            nowMs = nowMs, zoneId = zone, locale = Locale.US
        )
        assertNotNull(r1Status)
        assertFalse(r1Status!!.showAlways)
        assertEquals("Received · Nov 18, 7:51 PM", r1Status.label)

        val r2Status = resolveMessageDetailStatus(
            isFromMe = false, sendFailed = false, isPending = false,
            dateCreated = todayTimeMs, dateDelivered = 0L, dateRead = 0L,
            isLatestOutgoing = false, isLastReadOutgoing = false, isLatestIncoming = true,
            nowMs = nowMs, zoneId = zone, locale = Locale.US
        )!!
        assertTrue(r2Status.showAlways)
        assertEquals(MessageDetailKind.RECEIVED, r2Status.kind)
        assertEquals("Received · 7:51 PM", r2Status.label)
    }
}
