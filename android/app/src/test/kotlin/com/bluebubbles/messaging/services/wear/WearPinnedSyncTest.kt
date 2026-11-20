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

    @Test
    fun `buildWatchChatSyncList truncates lastMessageText to 300 chars`() {
        val longText = "a".repeat(450)
        val chat = serverChat("iMessage;-;+15551234567", dateCreated = 1000L).apply {
            getAsJsonObject("lastMessage").addProperty("text", longText)
        }

        val result = WearSyncManager.buildWatchChatSyncList(
            recentChats = listOf(chat),
            extraPinnedChats = emptyList(),
            pinnedGuids = null
        )

        assertEquals(300, result.single().get("lastMessageText").asString.length)
        assertEquals("a".repeat(300), result.single().get("lastMessageText").asString)
    }

    @Test
    fun `shouldUseDataAsset switches at 60KB threshold`() {
        assertFalse(WearSyncManager.shouldUseDataAsset(ByteArray(WearSyncManager.PAYLOAD_MESSAGE_MAX_BYTES)))
        assertTrue(WearSyncManager.shouldUseDataAsset(ByteArray(WearSyncManager.PAYLOAD_MESSAGE_MAX_BYTES + 1)))
    }

    @Test
    fun `extractDmRecipientIfNewChatError detects 1-to-1 DM missing chat errors only`() {
        assertEquals(
            "+15551234567",
            WearSyncManager.extractDmRecipientIfNewChatError("iMessage;-;+15551234567", 404, null)
        )
        assertEquals(
            "+15551234567",
            WearSyncManager.extractDmRecipientIfNewChatError("SMS;-;+15551234567", 400, """{"message":"Chat does not exist"}""")
        )
        assertEquals(
            "user@example.com",
            WearSyncManager.extractDmRecipientIfNewChatError("iMessage;-;user@example.com", 500, "Chat does not exist")
        )
        assertNull(WearSyncManager.extractDmRecipientIfNewChatError("iMessage;+;chat12345", 404, "does not exist"))
        assertNull(WearSyncManager.extractDmRecipientIfNewChatError("iMessage;-;+15551234567", 500, "Internal error"))
    }

    @Test
    fun `parseNewChatMessageResult extracts created chatGuid and first message`() {
        val response = """
            {
              "status": 200,
              "data": {
                "guid": "iMessage;-;+15551234567",
                "messages": [
                  {
                    "guid": "msg-real-1",
                    "tempGuid": "temp-1",
                    "text": "Hello!",
                    "isFromMe": true,
                    "dateCreated": 1234567890
                  }
                ]
              }
            }
        """.trimIndent()

        val parsed = WearSyncManager.parseNewChatMessageResult(response, "any;-;+15551234567")
        assertEquals("iMessage;-;+15551234567", parsed?.get("chatGuid")?.asString)
        assertEquals("msg-real-1", parsed?.get("guid")?.asString)
        assertEquals("temp-1", parsed?.get("tempGuid")?.asString)
        assertEquals("Hello!", parsed?.get("text")?.asString)
        assertNull(WearSyncManager.parseNewChatMessageResult("""{"status":200,"data":{"guid":"x","messages":[]}}""", "x"))
    }
}
