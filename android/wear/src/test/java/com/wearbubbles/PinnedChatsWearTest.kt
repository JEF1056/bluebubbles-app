package com.wearbubbles

import com.wearbubbles.db.entities.ChatEntity
import com.wearbubbles.db.entities.ContactEntity
import com.wearbubbles.relay.PhoneRelayClient
import com.wearbubbles.ui.messages.selectFavoriteContacts
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PinnedChatsWearTest {

    @Test
    fun `parseRelayChatsToEntities maps isPinned and pinIndex from sync payload`() {
        val json = """
            {
              "chats": [
                {
                  "guid": "iMessage;-;+15550001111",
                  "chatIdentifier": "+15550001111",
                  "displayName": "Pinned Friend",
                  "participantAddresses": ["+15550001111"],
                  "lastMessageText": "Hey",
                  "lastMessageDate": 1000,
                  "lastMessageIsFromMe": false,
                  "hasUnreadMessage": true,
                  "isPinned": true,
                  "pinIndex": 0
                },
                {
                  "guid": "iMessage;-;+15550002222",
                  "chatIdentifier": "+15550002222",
                  "participantAddresses": ["+15550002222"],
                  "lastMessageText": "Yo",
                  "lastMessageDate": 9000,
                  "lastMessageIsFromMe": true,
                  "hasUnreadMessage": false
                }
              ]
            }
        """.trimIndent()

        val entities = PhoneRelayClient.parseRelayChatsToEntities(json)!!
        assertEquals(2, entities.size)
        assertTrue(entities[0].isPinned)
        assertEquals(0, entities[0].pinIndex)
        assertFalse(entities[1].isPinned)
        assertNull(entities[1].pinIndex)
    }

    @Test
    fun `watch sort rule puts pinned chats first by pinIndex then lastMessageDate DESC`() {
        val chats = listOf(
            ChatEntity("unpinned-new", "a", null, "", null, 9000L, false, false, isPinned = false, pinIndex = null),
            ChatEntity("pinned-1", "b", null, "", null, 4000L, false, false, isPinned = true, pinIndex = 1),
            ChatEntity("pinned-no-idx", "c", null, "", null, 7000L, false, false, isPinned = true, pinIndex = null),
            ChatEntity("pinned-0", "d", null, "", null, 1000L, false, false, isPinned = true, pinIndex = 0),
            ChatEntity("unpinned-old", "e", null, "", null, 2000L, false, false, isPinned = false, pinIndex = null)
        )

        // Mirrors ChatDao.getAllChats():
        // ORDER BY isPinned DESC, CASE WHEN pinIndex IS NULL THEN 999999 ELSE pinIndex END ASC, lastMessageDate DESC
        val sorted = chats.sortedWith(
            compareByDescending<ChatEntity> { it.isPinned }
                .thenBy { it.pinIndex ?: 999999 }
                .thenByDescending { it.lastMessageDate }
        )

        assertEquals(
            listOf("pinned-0", "pinned-1", "pinned-no-idx", "unpinned-new", "unpinned-old"),
            sorted.map { it.guid }
        )
    }

    @Test
    fun `selectFavoriteContacts mirrors pinned individual chats in pinIndex order`() {
        val contacts = listOf(
            ContactEntity(normalizedAddress = "+15550001111", displayName = "Alice"),
            ContactEntity(normalizedAddress = "+15550002222", displayName = "Bob"),
            ContactEntity(normalizedAddress = "+15550003333", displayName = "Charlie")
        )
        val chats = listOf(
            ChatEntity("any;-;+15550003333", "+15550003333", "Charlie", "+15550003333", null, 9999L, false, false, isPinned = false, pinIndex = null),
            ChatEntity("any;-;+15550002222", "+15550002222", "Bob", "+15550002222", null, 1000L, false, false, isPinned = true, pinIndex = 1),
            ChatEntity("any;-;+15550001111", "+15550001111", "Alice", "+15550001111", null, 500L, false, false, isPinned = true, pinIndex = 0)
        )

        val favorites = selectFavoriteContacts(contacts, chats)
        assertEquals(listOf("Alice", "Bob"), favorites.map { it.displayName })
    }
}
