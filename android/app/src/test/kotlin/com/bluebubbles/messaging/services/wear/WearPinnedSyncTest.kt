package com.bluebubbles.messaging.services.wear

import com.google.gson.JsonArray
import com.google.gson.JsonNull
import com.google.gson.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WearPinnedSyncTest {

    private fun serverChat(
        guid: String,
        dateCreated: Long,
        isArchived: Boolean = false,
        dateDeleted: Long? = null,
        isPinned: Boolean? = null,
        pinIndex: Int? = null
    ): JsonObject = JsonObject().apply {
        addProperty("guid", guid)
        addProperty("chatIdentifier", guid.substringAfterLast(";"))
        addProperty("isArchived", isArchived)
        if (dateDeleted != null) addProperty("dateDeleted", dateDeleted) else add("dateDeleted", JsonNull.INSTANCE)
        if (isPinned != null) addProperty("isPinned", isPinned)
        if (pinIndex != null) addProperty("pinIndex", pinIndex)
        add("participants", JsonArray())
        add("lastMessage", JsonObject().apply {
            addProperty("text", "msg-$guid")
            addProperty("dateCreated", dateCreated)
            addProperty("isFromMe", false)
        })
    }

    @Test
    fun `parsePinnedGuidsResponse handles envelope, direct, and invalid payloads`() {
        assertEquals(
            listOf("c1", "c2"),
            WearSyncManager.parsePinnedGuidsResponse("""{"status":200,"data":{"pinnedChatGuids":["c1","c2"]}}""")
        )
        assertEquals(
            listOf("c3"),
            WearSyncManager.parsePinnedGuidsResponse("""{"pinnedChatGuids":["c3"]}""")
        )
        assertEquals(
            emptyList<String>(),
            WearSyncManager.parsePinnedGuidsResponse("""{"data":{"pinnedChatGuids":[]}}""")
        )
        assertNull(WearSyncManager.parsePinnedGuidsResponse("""{"status":404,"message":"Not Found"}"""))
    }

    @Test
    fun `buildWatchChatSyncList places pinned chats first by pinIndex, includes older extra pins, and filters archived or deleted`() {
        val recentChats = listOf(
            serverChat("recent-unpinned", dateCreated = 9000L),
            serverChat("pinned-1", dateCreated = 5000L),
            serverChat("archived-chat", dateCreated = 9500L, isArchived = true),
            serverChat("deleted-chat", dateCreated = 9600L, dateDeleted = 123456L),
            serverChat("older-unpinned", dateCreated = 2000L)
        )
        val extraPinned = listOf(
            serverChat("pinned-0-old", dateCreated = 100L),
            // Duplicate of pinned-1 should not appear twice
            serverChat("pinned-1", dateCreated = 5000L)
        )

        val result = WearSyncManager.buildWatchChatSyncList(
            recentChats = recentChats,
            extraPinnedChats = extraPinned,
            pinnedGuids = listOf("pinned-0-old", "pinned-1")
        )

        assertEquals(
            listOf("pinned-0-old", "pinned-1", "recent-unpinned", "older-unpinned"),
            result.map { it.get("guid").asString }
        )

        assertTrue(result[0].get("isPinned").asBoolean)
        assertEquals(0, result[0].get("pinIndex").asInt)
        assertTrue(result[1].get("isPinned").asBoolean)
        assertEquals(1, result[1].get("pinIndex").asInt)
        assertFalse(result[2].get("isPinned").asBoolean)
        assertFalse(result[2].has("pinIndex"))
    }

    @Test
    fun `buildWatchChatSyncList falls back to ChatSerializer pin fields when pinned endpoint unavailable`() {
        val recentChats = listOf(
            serverChat("unpinned", dateCreated = 9000L, isPinned = false),
            serverChat("pin-b", dateCreated = 1000L, isPinned = true, pinIndex = 1),
            serverChat("pin-a", dateCreated = 500L, isPinned = true, pinIndex = 0)
        )

        val result = WearSyncManager.buildWatchChatSyncList(
            recentChats = recentChats,
            extraPinnedChats = emptyList(),
            pinnedGuids = null
        )

        assertEquals(listOf("pin-a", "pin-b", "unpinned"), result.map { it.get("guid").asString })
    }
}
