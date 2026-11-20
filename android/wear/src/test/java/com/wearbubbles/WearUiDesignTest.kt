package com.wearbubbles

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.LineHeightStyle
import androidx.compose.ui.unit.sp
import com.wearbubbles.db.entities.ChatEntity
import com.wearbubbles.db.entities.ContactEntity
import com.wearbubbles.ui.messages.BUBBLE_GROUP_GAP_MS
import com.wearbubbles.ui.messages.BUBBLE_INNER_RADIUS_DP
import com.wearbubbles.ui.messages.BUBBLE_OUTER_RADIUS_DP
import com.wearbubbles.ui.messages.BubbleCornerRadii
import com.wearbubbles.ui.messages.BubbleGroupKey
import com.wearbubbles.ui.messages.BubblePosition
import com.wearbubbles.ui.messages.TIMESTAMP_BREAK_MS
import com.wearbubbles.ui.messages.appendDialpadToken
import com.wearbubbles.ui.messages.bubbleCornerRadii
import com.wearbubbles.ui.messages.canStartDirectQuery
import com.wearbubbles.ui.messages.computeBubbleGrouping
import com.wearbubbles.ui.messages.duplicateDisplayNames
import com.wearbubbles.ui.messages.filterContacts
import com.wearbubbles.ui.messages.formatMessageTimestampHeader
import com.wearbubbles.ui.messages.formatReceiptTime
import com.wearbubbles.ui.messages.groupContactsAlphabetically
import com.wearbubbles.ui.messages.looksLikeDirectAddress
import com.wearbubbles.ui.messages.resolveStartChatGuid
import com.wearbubbles.ui.messages.selectFavoriteContacts
import com.wearbubbles.ui.messages.shouldShowTimestampBreak
import com.wearbubbles.ui.theme.AvatarSwatches
import com.wearbubbles.ui.theme.OnPrimary
import com.wearbubbles.ui.theme.Primary
import com.wearbubbles.ui.theme.PrimaryAction
import com.wearbubbles.ui.theme.ReceivedBubble
import com.wearbubbles.ui.theme.SentBubble
import com.wearbubbles.ui.theme.Surface
import com.wearbubbles.ui.theme.SurfaceContainer
import com.wearbubbles.ui.theme.SurfaceContainerHigh
import com.wearbubbles.ui.theme.avatarMonogram
import com.wearbubbles.ui.theme.avatarSwatchFor
import com.wearbubbles.ui.theme.centeredTextStyle
import com.wearbubbles.ui.theme.submitDirectKeyboardText
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.util.Locale

class WearUiDesignTest {

    @Test
    fun `theme palette matches Wear OS 6 tonal Material 3 tokens and optical text centering`() {
        assertEquals(Color(0xFF000000), Surface)
        assertEquals(Color(0xFF202124), SurfaceContainer)
        assertEquals(SurfaceContainer, ReceivedBubble)
        assertEquals(SurfaceContainerHigh, SentBubble)
        assertEquals(Primary, PrimaryAction)
        assertFalse(PrimaryAction == Color(0xFF0B57D0))
        assertFalse(SentBubble == Color(0xFF0842A0))
        assertTrue(OnPrimary != Color(0xFFFFFFFF))

        val style = centeredTextStyle(13.sp, 17.sp)
        assertEquals(false, style.platformStyle?.paragraphStyle?.includeFontPadding)
        assertEquals(LineHeightStyle.Alignment.Center, style.lineHeightStyle?.alignment)
        assertEquals(LineHeightStyle.Trim.Both, style.lineHeightStyle?.trim)
    }

    @Test
    fun `avatar monogram and deterministic swatches handle names numbers and edge seeds`() {
        assertEquals("A", avatarMonogram("Alice"))
        assertEquals("J", avatarMonogram("  jessica "))
        assertNull(avatarMonogram("+1 (555) 123-4567"))
        assertNull(avatarMonogram("5551234567"))
        assertNull(avatarMonogram("   "))
        assertNull(avatarMonogram(""))
        assertNull(avatarMonogram("🚀 Launch"))

        // Deterministic mapping across normal, empty, and Int.MIN_VALUE hashCode seed ("polygenelubricants")
        val swatchA = avatarSwatchFor("chat-alice")
        assertEquals(swatchA, avatarSwatchFor("chat-alice"))
        assertTrue(swatchA in AvatarSwatches)
        assertTrue(avatarSwatchFor("") in AvatarSwatches)
        assertTrue(avatarSwatchFor("polygenelubricants") in AvatarSwatches)
    }

    @Test
    fun `bubble corner radii apply 24dp pill corners`() {
        val pill = BubbleCornerRadii(24, 24, 24, 24)
        assertEquals(pill, bubbleCornerRadii(isFromMe = true, connectUpper = false, connectLower = false))
        assertEquals(pill, bubbleCornerRadii(isFromMe = true, connectUpper = false, connectLower = true))
        assertEquals(pill, bubbleCornerRadii(isFromMe = true, connectUpper = true, connectLower = true))
        assertEquals(pill, bubbleCornerRadii(isFromMe = true, connectUpper = true, connectLower = false))

        assertEquals(pill, bubbleCornerRadii(isFromMe = false, connectUpper = false, connectLower = false))
        assertEquals(pill, bubbleCornerRadii(isFromMe = false, connectUpper = false, connectLower = true))
        assertEquals(pill, bubbleCornerRadii(isFromMe = false, connectUpper = true, connectLower = true))
        assertEquals(pill, bubbleCornerRadii(isFromMe = false, connectUpper = true, connectLower = false))
        assertEquals(24, BUBBLE_OUTER_RADIUS_DP)
        assertEquals(24, BUBBLE_INNER_RADIUS_DP)
    }

    @Test
    fun `computeBubbleGrouping handles bursts sender switches time gaps and failed sends`() {
        val base = ZonedDateTime.of(2026, 5, 10, 14, 0, 0, 0, ZoneOffset.UTC)
            .toInstant()
            .toEpochMilli()

        val items = listOf(
            // Burst of 3 received messages from Alice within 2 min
            BubbleGroupKey(isFromMe = false, senderKey = "+15550001", dateCreated = base),
            BubbleGroupKey(isFromMe = false, senderKey = "+15550001", dateCreated = base + 30_000L),
            BubbleGroupKey(isFromMe = false, senderKey = "+15550001", dateCreated = base + 60_000L),
            // Different sender Bob right after (group chat) -> breaks group
            BubbleGroupKey(isFromMe = false, senderKey = "+15550002", dateCreated = base + 70_000L),
            // Same sender Bob after > 2 min gap (but < 15 min) -> breaks bubble group, no timestamp header
            BubbleGroupKey(isFromMe = false, senderKey = "+15550002", dateCreated = base + 70_000L + BUBBLE_GROUP_GAP_MS + 1_000L),
            // Outgoing succeeded followed immediately by failed outgoing -> must not merge
            BubbleGroupKey(isFromMe = true, senderKey = "__ME__", dateCreated = base + 70_000L + BUBBLE_GROUP_GAP_MS + 5_000L, sendFailed = false),
            BubbleGroupKey(isFromMe = true, senderKey = "__ME__", dateCreated = base + 70_000L + BUBBLE_GROUP_GAP_MS + 6_000L, sendFailed = true),
            // Next message >= 15 min later -> forces timestamp header & new group
            BubbleGroupKey(isFromMe = true, senderKey = "__ME__", dateCreated = base + 70_000L + BUBBLE_GROUP_GAP_MS + 6_000L + TIMESTAMP_BREAK_MS)
        )

        val meta = computeBubbleGrouping(
            items = items,
            hasSenderLabel = { idx -> idx <= 4 },
            zoneId = ZoneOffset.UTC
        )

        assertEquals(8, meta.size)
        // Alice burst: FIRST / MIDDLE / LAST, sender name only on FIRST
        assertEquals(BubblePosition.FIRST, meta[0].position)
        assertTrue(meta[0].showTimestampHeader)
        assertTrue(meta[0].showSenderName)
        assertEquals(BubbleCornerRadii(24, 24, 24, 24), meta[0].corners)

        assertEquals(BubblePosition.MIDDLE, meta[1].position)
        assertFalse(meta[1].showTimestampHeader)
        assertFalse(meta[1].showSenderName)
        assertEquals(BubbleCornerRadii(24, 24, 24, 24), meta[1].corners)

        assertEquals(BubblePosition.LAST, meta[2].position)
        assertFalse(meta[2].showTimestampHeader)
        assertFalse(meta[2].showSenderName)
        assertEquals(BubbleCornerRadii(24, 24, 24, 24), meta[2].corners)

        // Bob breaks group from Alice
        assertEquals(BubblePosition.SINGLE, meta[3].position)
        assertTrue(meta[3].showSenderName)
        assertFalse(meta[3].showTimestampHeader)

        // Bob after >2min gap is a new SINGLE group without a timestamp header
        assertEquals(BubblePosition.SINGLE, meta[4].position)
        assertTrue(meta[4].showSenderName)
        assertFalse(meta[4].showTimestampHeader)

        // Sent vs failed sent do not merge
        assertEquals(BubblePosition.SINGLE, meta[5].position)
        assertEquals(BubblePosition.SINGLE, meta[6].position)
        assertFalse(meta[5].showSenderName)
        assertFalse(meta[6].showSenderName)

        // >=15 min later forces timestamp break
        assertEquals(BubblePosition.SINGLE, meta[7].position)
        assertTrue(meta[7].showTimestampHeader)
    }

    @Test
    fun `timestamp breaks detect day boundary and formatting uses M-d-yy header and h-mm a receipt`() {
        val zone = ZoneOffset.UTC
        val lateYesterday = ZonedDateTime.of(2026, 5, 9, 23, 58, 0, 0, zone).toInstant().toEpochMilli()
        val earlyToday = ZonedDateTime.of(2026, 6, 23, 1, 17, 0, 0, zone).toInstant().toEpochMilli()
        val now = ZonedDateTime.of(2026, 6, 23, 15, 30, 0, 0, zone).toInstant().toEpochMilli()

        assertTrue(shouldShowTimestampBreak(lateYesterday, earlyToday, zoneId = zone))
        assertEquals("", formatMessageTimestampHeader(0L, nowMs = now, zoneId = zone, locale = Locale.US))
        assertEquals(
            "6/23/26",
            formatMessageTimestampHeader(earlyToday, nowMs = now, zoneId = zone, locale = Locale.US)
        )
        assertEquals(
            "5/9/26",
            formatMessageTimestampHeader(lateYesterday, nowMs = now, zoneId = zone, locale = Locale.US)
        )
        assertEquals("", formatReceiptTime(0L, zoneId = zone, locale = Locale.US))
        assertEquals(
            "1:17 AM",
            formatReceiptTime(earlyToday, zoneId = zone, locale = Locale.US)
        )
    }

    @Test
    fun `start chat helpers select favorites group alphabetically and detect direct addresses`() {
        val contacts = listOf(
            ContactEntity("5550001111", "Mom", "+15550001111", avatarPath = "/tmp/mom.jpg"),
            ContactEntity("mom@icloud.com", "Mom", "mom@icloud.com", avatarPath = null),
            ContactEntity("5550002222", "Dad", "+15550002222", avatarPath = null),
            ContactEntity("5550003333", "Audrey Sioeng", "+15550003333", avatarPath = "/tmp/audrey.jpg"),
            ContactEntity("5550004444", "Jack Fan", "+15550004444", avatarPath = null),
            ContactEntity("5550005555", "aaron lee", "+15550005555", avatarPath = null),
            ContactEntity("5550006666", "123 Support", "+15550006666", avatarPath = null)
        )
        val recentChats = listOf(
            ChatEntity(
                guid = "iMessage;+;group1",
                chatIdentifier = "group1",
                displayName = "Family",
                participantAddresses = "+15550004444,+15550002222",
                lastMessageText = "hi",
                lastMessageDate = 9000L,
                lastMessageIsFromMe = false,
                hasUnreadMessage = false
            ),
            ChatEntity(
                guid = "iMessage;-;+15550002222",
                chatIdentifier = "+15550002222",
                displayName = null,
                participantAddresses = "+15550002222",
                lastMessageText = "hey",
                lastMessageDate = 5000L,
                lastMessageIsFromMe = false,
                hasUnreadMessage = false
            ),
            ChatEntity(
                guid = "iMessage;-;mom@icloud.com",
                chatIdentifier = "mom@icloud.com",
                displayName = null,
                participantAddresses = "mom@icloud.com",
                lastMessageText = "call me",
                lastMessageDate = 4000L,
                lastMessageIsFromMe = false,
                hasUnreadMessage = false
            )
        )

        val favorites = selectFavoriteContacts(contacts, recentChats)
        assertEquals(4, favorites.size)
        // Recency 1:1 chats first (Dad, Mom), then photo fallback (Audrey Sioeng), then alphabetical (aaron lee)
        assertEquals(listOf("Dad", "Mom", "Audrey Sioeng", "aaron lee"), favorites.map { it.displayName })

        val sections = groupContactsAlphabetically(contacts)
        assertEquals(listOf("A", "D", "J", "M", "#"), sections.map { it.letter })
        assertEquals(listOf("aaron lee", "Audrey Sioeng"), sections[0].contacts.map { it.displayName })
        assertEquals(listOf("123 Support"), sections.last().contacts.map { it.displayName })

        assertTrue(looksLikeDirectAddress("+1 (555) 123-4567"))
        assertTrue(looksLikeDirectAddress("alice@icloud.com"))
        assertFalse(looksLikeDirectAddress("Audrey Sioeng"))
        assertFalse(looksLikeDirectAddress("555"))
        assertFalse(looksLikeDirectAddress(""))

        assertTrue(canStartDirectQuery("555"))
        assertTrue(canStartDirectQuery("alice@icloud.com"))
        assertFalse(canStartDirectQuery("John"))
        assertFalse(canStartDirectQuery("   "))

        assertEquals("+", appendDialpadToken("", "+"))
        assertEquals("+1", appendDialpadToken("+1", "+"))
        assertEquals("123", appendDialpadToken("12", "3"))

        val smsRecent = listOf(
            ChatEntity(
                guid = "SMS;-;+15557778888",
                chatIdentifier = "+15557778888",
                displayName = null,
                participantAddresses = "+15557778888",
                lastMessageText = "sms hi",
                lastMessageDate = 7000L,
                lastMessageIsFromMe = false,
                hasUnreadMessage = false
            )
        )
        assertEquals(
            "SMS;-;+15557778888",
            resolveStartChatGuid("(555) 777-8888", smsRecent) { "iMessage;-;$it" }
        )
        assertEquals(
            "iMessage;-;+15559990000",
            resolveStartChatGuid("+15559990000", smsRecent) { "iMessage;-;$it" }
        )

        assertEquals(setOf("mom"), duplicateDisplayNames(contacts))
        assertEquals(2, filterContacts(contacts, "mom").size)
        assertEquals(1, filterContacts(contacts, "5550003333").size)
    }

    @Test
    fun `submitDirectKeyboardText rejects blank input and trims non-empty replies`() {
        assertNull(submitDirectKeyboardText(""))
        assertNull(submitDirectKeyboardText("   \n\t  "))
        assertEquals("On my way!", submitDirectKeyboardText("  On my way!  "))
        assertEquals("👍", submitDirectKeyboardText(" 👍 "))
    }
}
