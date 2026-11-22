package com.wearbubbles.ui.messages

import com.wearbubbles.ui.theme.extractSpokenText
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
    private val nowMs = ZonedDateTime.of(2026, 11, 20, 21, 0, 0, 0, zone).toInstant().toEpochMilli()
    private val todayTimeMs = ZonedDateTime.of(2026, 11, 20, 19, 51, 0, 0, zone).toInstant().toEpochMilli()
    private val yesterdayTimeMs = ZonedDateTime.of(2026, 11, 19, 19, 51, 0, 0, zone).toInstant().toEpochMilli()
    private val olderTimeMs = ZonedDateTime.of(2026, 11, 10, 19, 51, 0, 0, zone).toInstant().toEpochMilli()
    private val lastYearTimeMs = ZonedDateTime.of(2025, 10, 5, 19, 51, 0, 0, zone).toInstant().toEpochMilli()

    @Test
    fun `formatDetailTimestamp formats same-day week-range year-range and older days concisely`() {
        assertEquals("", formatDetailTimestamp(0L, nowMs = nowMs, zoneId = zone, locale = Locale.US))
        assertEquals("7:51 PM", formatDetailTimestamp(todayTimeMs, nowMs = nowMs, zoneId = zone, locale = Locale.US))
        assertEquals("Thu 7:51 PM", formatDetailTimestamp(yesterdayTimeMs, nowMs = nowMs, zoneId = zone, locale = Locale.US))
        assertEquals("Nov 10, 7:51 PM", formatDetailTimestamp(olderTimeMs, nowMs = nowMs, zoneId = zone, locale = Locale.US))
        assertEquals("10/5/25", formatDetailTimestamp(lastYearTimeMs, nowMs = nowMs, zoneId = zone, locale = Locale.US))
    }

    @Test
    fun `four-tier receipts show read delivered and sent simultaneously while superseding older tiers`() {
        val items = listOf(
            MessageReceiptCandidate("m1", isFromMe = true, sendFailed = false, isPending = false, dateRead = olderTimeMs, dateDelivered = olderTimeMs, dateCreated = olderTimeMs),
            MessageReceiptCandidate("m2", isFromMe = true, sendFailed = false, isPending = false, dateRead = yesterdayTimeMs, dateDelivered = yesterdayTimeMs, dateCreated = yesterdayTimeMs),
            MessageReceiptCandidate("m3", isFromMe = true, sendFailed = false, isPending = false, dateRead = 0L, dateDelivered = todayTimeMs, dateCreated = todayTimeMs),
            MessageReceiptCandidate("m4", isFromMe = true, sendFailed = false, isPending = false, dateRead = 0L, dateDelivered = 0L, dateCreated = todayTimeMs + 1_000L)
        )
        val flags = computeMessageReceiptFlags(items)
        assertEquals("m4", flags.latestOutgoingGuid)
        assertEquals("m2", flags.lastReadOutgoingGuid)
        assertEquals("m3", flags.lastDeliveredOutgoingGuid)
        assertEquals("m4", flags.lastSentOutgoingGuid)
        assertNull(flags.latestIncomingGuid)

        val m1Status = resolveMessageDetailStatus(
            isFromMe = true, sendFailed = false, isPending = false,
            dateCreated = olderTimeMs, dateDelivered = olderTimeMs, dateRead = olderTimeMs,
            nowMs = nowMs, zoneId = zone, locale = Locale.US
        )!!
        assertFalse(m1Status.showAlways)
        assertEquals("Read · Nov 10, 7:51 PM", m1Status.label)

        val m2Status = resolveMessageDetailStatus(
            isFromMe = true, sendFailed = false, isPending = false,
            dateCreated = yesterdayTimeMs, dateDelivered = yesterdayTimeMs, dateRead = yesterdayTimeMs,
            isLastReadOutgoing = true,
            nowMs = nowMs, zoneId = zone, locale = Locale.US
        )!!
        assertTrue(m2Status.showAlways)
        assertEquals(MessageDetailKind.READ, m2Status.kind)
        assertEquals("Read · Thu 7:51 PM", m2Status.label)

        val m3Status = resolveMessageDetailStatus(
            isFromMe = true, sendFailed = false, isPending = false,
            dateCreated = todayTimeMs, dateDelivered = todayTimeMs, dateRead = 0L,
            isLastDeliveredOutgoing = true,
            nowMs = nowMs, zoneId = zone, locale = Locale.US
        )!!
        assertTrue(m3Status.showAlways)
        assertEquals(MessageDetailKind.DELIVERED, m3Status.kind)
        assertEquals("Delivered · 7:51 PM", m3Status.label)

        val m4Status = resolveMessageDetailStatus(
            isFromMe = true, sendFailed = false, isPending = false,
            dateCreated = todayTimeMs, dateDelivered = 0L, dateRead = 0L,
            isLastSentOutgoing = true,
            nowMs = nowMs, zoneId = zone, locale = Locale.US
        )!!
        assertTrue(m4Status.showAlways)
        assertEquals(MessageDetailKind.SENT, m4Status.kind)
        assertEquals("Sent · 7:51 PM", m4Status.label)

        // Newer read supersedes older delivered and sent
        val supersededFlags = computeMessageReceiptFlags(
            listOf(
                MessageReceiptCandidate("s1", isFromMe = true, sendFailed = false, isPending = false, dateRead = 0L, dateDelivered = 0L, dateCreated = olderTimeMs),
                MessageReceiptCandidate("d1", isFromMe = true, sendFailed = false, isPending = false, dateRead = 0L, dateDelivered = yesterdayTimeMs, dateCreated = yesterdayTimeMs),
                MessageReceiptCandidate("r1", isFromMe = true, sendFailed = false, isPending = false, dateRead = todayTimeMs, dateDelivered = todayTimeMs, dateCreated = todayTimeMs)
            )
        )
        assertEquals("r1", supersededFlags.lastReadOutgoingGuid)
        assertNull(supersededFlags.lastDeliveredOutgoingGuid)
        assertNull(supersededFlags.lastSentOutgoingGuid)
    }

    @Test
    fun `latest sent already read resolves once with showAlways true`() {
        val items = listOf(
            MessageReceiptCandidate("m1", isFromMe = true, sendFailed = false, isPending = false, dateRead = yesterdayTimeMs, dateCreated = yesterdayTimeMs),
            MessageReceiptCandidate("m2", isFromMe = true, sendFailed = false, isPending = false, dateRead = todayTimeMs, dateCreated = todayTimeMs)
        )
        val flags = computeMessageReceiptFlags(items)
        assertEquals("m2", flags.latestOutgoingGuid)
        assertEquals("m2", flags.lastReadOutgoingGuid)
        assertNull(flags.lastDeliveredOutgoingGuid)
        assertNull(flags.lastSentOutgoingGuid)

        val m2Status = resolveMessageDetailStatus(
            isFromMe = true, sendFailed = false, isPending = false,
            dateCreated = todayTimeMs, dateDelivered = todayTimeMs, dateRead = todayTimeMs,
            isLastReadOutgoing = true,
            nowMs = nowMs, zoneId = zone, locale = Locale.US
        )!!
        assertTrue(m2Status.showAlways)
        assertEquals(MessageDetailKind.READ, m2Status.kind)
        assertEquals("Read · 7:51 PM", m2Status.label)
    }

    @Test
    fun `pending failed and edited states match web and android`() {
        val sentOnly = resolveMessageDetailStatus(
            isFromMe = true, sendFailed = false, isPending = false,
            dateCreated = todayTimeMs, dateDelivered = 0L, dateRead = 0L,
            isLastSentOutgoing = true,
            nowMs = nowMs, zoneId = zone, locale = Locale.US
        )!!
        assertTrue(sentOnly.showAlways)
        assertEquals(MessageDetailKind.SENT, sentOnly.kind)
        assertEquals("Sent · 7:51 PM", sentOnly.label)

        val pending = resolveMessageDetailStatus(
            isFromMe = true, sendFailed = false, isPending = true,
            dateCreated = todayTimeMs, dateDelivered = 0L, dateRead = 0L,
            nowMs = nowMs, zoneId = zone, locale = Locale.US
        )!!
        assertTrue(pending.showAlways)
        assertEquals(MessageDetailKind.SENDING, pending.kind)
        assertEquals("Sending…", pending.label)

        val editedUnexpanded = resolveMessageDetailStatus(
            isFromMe = true, sendFailed = false, isPending = false,
            dateCreated = olderTimeMs, dateDelivered = olderTimeMs, dateRead = olderTimeMs,
            dateEdited = todayTimeMs,
            isExpanded = false,
            nowMs = nowMs, zoneId = zone, locale = Locale.US
        )!!
        assertTrue(editedUnexpanded.showAlways)
        assertEquals(MessageDetailKind.EDITED, editedUnexpanded.kind)
        assertEquals("Edited", editedUnexpanded.label)

        val editedExpanded = resolveMessageDetailStatus(
            isFromMe = true, sendFailed = false, isPending = false,
            dateCreated = olderTimeMs, dateDelivered = olderTimeMs, dateRead = olderTimeMs,
            dateEdited = todayTimeMs,
            isExpanded = true,
            nowMs = nowMs, zoneId = zone, locale = Locale.US
        )!!
        assertTrue(editedExpanded.showAlways)
        assertEquals(MessageDetailKind.READ, editedExpanded.kind)
        assertEquals("Edited · Read · Nov 10, 7:51 PM", editedExpanded.label)

        val failed = resolveMessageDetailStatus(
            isFromMe = true, sendFailed = true, isPending = false,
            dateCreated = todayTimeMs, dateDelivered = 0L, dateRead = 0L,
            nowMs = nowMs, zoneId = zone, locale = Locale.US
        )!!
        assertTrue(failed.showAlways)
        assertEquals(MessageDetailKind.FAILED, failed.kind)
    }

    @Test
    fun `mixed sent and received highlights latest incoming and latest outgoing and last read`() {
        val items = listOf(
            MessageReceiptCandidate("r1", isFromMe = false, sendFailed = false, isPending = false, dateRead = 0L, dateCreated = olderTimeMs),
            MessageReceiptCandidate("s1", isFromMe = true, sendFailed = false, isPending = false, dateRead = yesterdayTimeMs, dateCreated = yesterdayTimeMs),
            MessageReceiptCandidate("r2", isFromMe = false, sendFailed = false, isPending = false, dateRead = 0L, dateCreated = todayTimeMs),
            MessageReceiptCandidate("s2", isFromMe = true, sendFailed = false, isPending = false, dateRead = 0L, dateCreated = todayTimeMs + 1_000L)
        )
        val flags = computeMessageReceiptFlags(items)
        assertEquals("s2", flags.latestOutgoingGuid)
        assertEquals("s1", flags.lastReadOutgoingGuid)
        assertEquals("s2", flags.lastSentOutgoingGuid)
        assertEquals("r2", flags.latestIncomingGuid)

        val r1Status = resolveMessageDetailStatus(
            isFromMe = false, sendFailed = false, isPending = false,
            dateCreated = olderTimeMs, dateDelivered = 0L, dateRead = 0L,
            nowMs = nowMs, zoneId = zone, locale = Locale.US
        )
        assertNotNull(r1Status)
        assertFalse(r1Status!!.showAlways)
        assertEquals("Received · Nov 10, 7:51 PM", r1Status.label)

        val r2Status = resolveMessageDetailStatus(
            isFromMe = false, sendFailed = false, isPending = false,
            dateCreated = todayTimeMs, dateDelivered = 0L, dateRead = 0L,
            isLatestIncoming = true,
            nowMs = nowMs, zoneId = zone, locale = Locale.US
        )!!
        assertTrue(r2Status.showAlways)
        assertEquals(MessageDetailKind.RECEIVED, r2Status.kind)
        assertEquals("Received · 7:51 PM", r2Status.label)
    }

    @Test
    fun `extractSpokenText picks first non-blank trimmed result`() {
        assertNull(extractSpokenText(null))
        assertNull(extractSpokenText(emptyList()))
        assertNull(extractSpokenText(listOf("   ", "")))
        assertEquals("On my way", extractSpokenText(listOf("  ", " On my way ", "fallback")))
    }

    @Test
    fun `formatDetailTimestamp uses Now and X min buckets before 60m absolute cutoff`() {
        val baseNow = ZonedDateTime.of(2026, 11, 20, 14, 30, 0, 0, zone).toInstant().toEpochMilli()
        assertEquals("Now", formatDetailTimestamp(baseNow, nowMs = baseNow, zoneId = zone, locale = Locale.US))
        assertEquals("Now", formatDetailTimestamp(baseNow - 59_999L, nowMs = baseNow, zoneId = zone, locale = Locale.US))
        assertEquals("1 min", formatDetailTimestamp(baseNow - 60_000L, nowMs = baseNow, zoneId = zone, locale = Locale.US))
        assertEquals("59 min", formatDetailTimestamp(baseNow - 59 * 60_000L, nowMs = baseNow, zoneId = zone, locale = Locale.US))
        assertEquals("1:30 PM", formatDetailTimestamp(baseNow - 60 * 60_000L, nowMs = baseNow, zoneId = zone, locale = Locale.US))

        assertEquals(60_000L, nextDetailTimestampTickDelayMs(baseNow, nowMs = baseNow))
        assertEquals(1L, nextDetailTimestampTickDelayMs(baseNow - 59_999L, nowMs = baseNow))
        assertEquals(60_000L, nextDetailTimestampTickDelayMs(baseNow - 60_000L, nowMs = baseNow))
        assertEquals(15_000L, nextDetailTimestampTickDelayMs(baseNow - 45_000L, nowMs = baseNow))
        assertNull(nextDetailTimestampTickDelayMs(baseNow - 60 * 60_000L, nowMs = baseNow))
        assertNull(nextDetailTimestampTickDelayMs(0L, nowMs = baseNow))
        assertEquals("Now", formatDetailTimestamp(baseNow + 5 * 60_000L, nowMs = baseNow, zoneId = zone, locale = Locale.US))
        assertNotNull(nextDetailTimestampTickDelayMs(baseNow + 5 * 60_000L, nowMs = baseNow))
    }

    @Test
    fun `nextDisplayedTimestampTickDelayMs skips unexpanded non-boundary messages`() {
        val nowMs = 1_700_000_000_000L
        val olderUnexpanded = MessageUi(
            guid = "m-old",
            text = "old",
            isFromMe = true,
            senderName = null,
            dateCreated = nowMs - 30_000L,
            dateDelivered = 0L,
            dateRead = 0L,
            sendFailed = false,
            reactions = emptyList(),
            attachmentGuid = null,
            attachmentMimeType = null,
            attachmentUrl = null,
            localAttachmentPath = null,
            customHeaders = emptyMap(),
            isLatestOutgoing = false,
            isLastReadOutgoing = false,
            isLatestIncoming = false
        )
        val latestOutgoing = olderUnexpanded.copy(
            guid = "m-latest",
            dateCreated = nowMs - 10_000L,
            isLatestOutgoing = true
        )

        assertEquals(
            50_000L,
            nextDisplayedTimestampTickDelayMs(
                messages = listOf(olderUnexpanded, latestOutgoing),
                expandedMessageGuid = null,
                nowMs = nowMs
            )
        )
        assertEquals(
            30_000L,
            nextDisplayedTimestampTickDelayMs(
                messages = listOf(olderUnexpanded, latestOutgoing),
                expandedMessageGuid = "m-old",
                nowMs = nowMs
            )
        )
    }
}
