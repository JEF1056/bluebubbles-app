package com.wearbubbles.ui.messages

import com.wearbubbles.db.entities.MessageEntity
import com.wearbubbles.socket.SocketEvent
import com.wearbubbles.socket.SocketManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WearUnreadDividerTest {

    private fun msg(
        guid: String,
        dateCreated: Long,
        isFromMe: Boolean = false,
        dateRead: Long? = null,
        isRead: Boolean? = null,
        associatedMessageType: String? = null,
        groupActionType: Int? = null,
        itemType: Int? = null
    ) = MessageEntity(
        guid = guid,
        chatGuid = "iMessage;-;+15551234567",
        text = "msg-$guid",
        isFromMe = isFromMe,
        dateCreated = dateCreated,
        handleAddress = null,
        dateRead = dateRead,
        isRead = isRead,
        associatedMessageType = associatedMessageType,
        groupActionType = groupActionType,
        itemType = itemType
    )

    private fun msgUi(
        guid: String,
        text: String,
        dateCreated: Long,
        isFromMe: Boolean = false
    ) = MessageUi(
        guid = guid,
        text = text,
        isFromMe = isFromMe,
        senderName = null,
        dateCreated = dateCreated,
        dateDelivered = 0L,
        dateRead = 0L,
        sendFailed = false,
        reactions = emptyList(),
        attachmentGuid = null,
        attachmentMimeType = null,
        attachmentUrl = null,
        localAttachmentPath = null,
        customHeaders = emptyMap(),
        isLatestOutgoing = false
    )

    @Test
    fun `returns null when chat has no unread messages`() {
        val messages = listOf(
            msg("m1", 1000L, isFromMe = false),
            msg("m2", 2000L, isFromMe = false)
        )
        assertNull(computeUnreadDividerGuid(messages, hasUnread = false, lastReadMessageTimestamp = 500L))
        assertNull(computeUnreadDividerGuid(emptyList(), hasUnread = true, lastReadMessageTimestamp = 500L))
    }

    @Test
    fun `picks oldest unread non-reaction non-group-event incoming message after read boundary`() {
        val messages = listOf(
            msg("m1", 1000L, isFromMe = false, dateRead = 1100L),
            msg("m2", 2000L, isFromMe = true),
            // Reaction and group event after boundary must be skipped
            msg("m3-tapback", 2500L, isFromMe = false, associatedMessageType = "2000"),
            msg("m4-group", 2600L, isFromMe = false, groupActionType = 1),
            msg("m5-item", 2700L, isFromMe = false, itemType = 2),
            // Already read even after boundary must be skipped
            msg("m6-already-read", 2800L, isFromMe = false, isRead = true),
            // First eligible unread incoming message
            msg("m7-unread-1", 3000L, isFromMe = false),
            msg("m8-unread-2", 4000L, isFromMe = false)
        )

        val guid = computeUnreadDividerGuid(
            messages = messages,
            hasUnread = true,
            lastReadMessageTimestamp = 2000L
        )
        assertEquals("m7-unread-1", guid)
    }

    @Test
    fun `falls back to contiguous incoming run after latest outgoing message when boundary is absent`() {
        val messages = listOf(
            msg("m1", 1000L, isFromMe = false),
            msg("m2", 2000L, isFromMe = true),
            msg("m3-tapback", 2500L, isFromMe = true, associatedMessageType = "2001"),
            msg("m4-first-after-me", 3000L, isFromMe = false),
            msg("m5-second-after-me", 4000L, isFromMe = false)
        )

        // Our own reaction after m2 must not break the run, while m2 (non-reaction isFromMe) stops it.
        val reversedInput = messages.reversed()
        val guid = computeUnreadDividerGuid(
            messages = reversedInput,
            hasUnread = true,
            lastReadMessageTimestamp = null
        )
        assertEquals("m4-first-after-me", guid)
    }

    @Test
    fun `tracker snapshots before read clears immediately on markRead send or remote read`() {
        val messages = listOf(
            msg("m1", 1000L, isFromMe = true),
            msg("m2", 2000L, isFromMe = false),
            msg("m3", 3000L, isFromMe = false)
        )

        // Case 1: Clear on markChatReadAndAck / user interaction
        val tracker1 = UnreadDividerTracker()
        tracker1.snapshotOnOpen(hasUnread = true, lastReadMessageTimestamp = 1500L)
        assertEquals("m2", tracker1.onMessages(messages))
        assertNull(tracker1.clear())
        assertNull(tracker1.dividerGuid)
        // Late message updates after clear must not resurrect the divider
        assertNull(tracker1.onMessages(messages + msg("m4", 4000L, isFromMe = false)))

        // Case 2: Clear when sending a reply (handled via clear())
        val tracker2 = UnreadDividerTracker()
        tracker2.snapshotOnOpen(hasUnread = true, lastReadMessageTimestamp = null)
        assertEquals("m2", tracker2.onMessages(messages))
        assertNull(tracker2.clear())

        // Case 3: Snapshot when already read keeps divider null
        val tracker3 = UnreadDividerTracker()
        tracker3.snapshotOnOpen(hasUnread = false, lastReadMessageTimestamp = 1500L)
        assertNull(tracker3.onMessages(messages))
    }

    @Test
    fun `buildMessageRows marks only divider row and breaks bubble grouping across divider`() {
        val messages = listOf(
            msgUi(guid = "m1", text = "older", isFromMe = false, dateCreated = 1_000L),
            msgUi(guid = "m2", text = "unread 1", isFromMe = false, dateCreated = 2_000L),
            msgUi(guid = "m3", text = "unread 2", isFromMe = false, dateCreated = 3_000L)
        )

        val rows = buildMessageRows(messages, unreadDividerGuid = "m2")
        assertFalse(rows[0].showUnreadDivider)
        assertTrue(rows[1].showUnreadDivider)
        assertFalse(rows[2].showUnreadDivider)

        // Bubble m1 and m2 must not connect across the unread divider; m2 and m3 still group.
        assertFalse(rows[0].meta.connectLower)
        assertFalse(rows[1].meta.connectUpper)
        assertTrue(rows[1].meta.connectLower)
        assertTrue(rows[2].meta.connectUpper)
    }

    @Test
    fun `socket chat-read-status-changed parser handles direct and wrapped payloads`() {
        val direct = """{"chatGuid":"iMessage;-;+15551234567","read":true,"readAt":1700000000000}"""
        assertEquals(
            SocketEvent.ChatReadStatusChanged("iMessage;-;+15551234567", true, 1_700_000_000_000L),
            SocketManager.parseChatReadStatusChanged(direct)
        )

        val wrapped = """{"data":{"guid":"iMessage;-;+15559876543","status":false,"lastReadMessageTimestamp":1700000005000}}"""
        assertEquals(
            SocketEvent.ChatReadStatusChanged("iMessage;-;+15559876543", false, 1_700_000_005_000L),
            SocketManager.parseChatReadStatusChanged(wrapped)
        )
    }
}
