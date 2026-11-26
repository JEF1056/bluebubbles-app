package com.bluebubbles.messaging.services.wear

import com.google.gson.JsonParser
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class WearSyncEnhancementsTest {

    @Before
    fun setUp() {
        WearSyncManager.phoneActiveChatGuid = null
    }

    @After
    fun tearDown() {
        WearSyncManager.phoneActiveChatGuid = null
    }

    @Test
    fun `constants match specification`() {
        assertEquals("/wearbubbles/phone_active_chat", WearSyncManager.PATH_PHONE_ACTIVE_CHAT)
        assertEquals(240, WearSyncManager.PHOTO_THUMB_MAX_DIM)
        assertEquals(65, WearSyncManager.PHOTO_THUMB_QUALITY)
        assertEquals(20 * 1024, WearSyncManager.PHOTO_THUMB_MAX_BYTES)
    }

    @Test
    fun `buildNotificationMessagePayload serializes fields without thumbnail`() {
        val payloadStr = WearSyncManager.buildNotificationMessagePayload(
            chatGuid = "iMessage;-;+15551234567",
            senderName = "Alice",
            messageText = "Hello from phone",
            isGroup = false,
            groupTitle = null,
            timestamp = 1700000000000L,
            isTapback = false,
            onlyAlertOnce = true,
            senderAddress = "+15551234567",
            messageGuid = "msg-guid-1",
            photoThumbB64 = null
        )

        val obj = JsonParser.parseString(payloadStr).asJsonObject
        assertEquals("iMessage;-;+15551234567", obj.get("chatGuid").asString)
        assertEquals("Alice", obj.get("senderName").asString)
        assertEquals("Hello from phone", obj.get("messageText").asString)
        assertFalse(obj.get("isGroup").asBoolean)
        assertNull(obj.get("groupTitle"))
        assertEquals(1700000000000L, obj.get("timestamp").asLong)
        assertFalse(obj.get("isTapback").asBoolean)
        assertTrue(obj.get("onlyAlertOnce").asBoolean)
        assertEquals("+15551234567", obj.get("senderAddress").asString)
        assertEquals("msg-guid-1", obj.get("messageGuid").asString)
        assertNull(obj.get("photoThumbB64"))
    }

    @Test
    fun `buildNotificationMessagePayload serializes photoThumbB64 and groupTitle when present`() {
        val fakeThumb = "data:image/jpeg;base64,/9j/4AAQSkZJRg=="
        val payloadStr = WearSyncManager.buildNotificationMessagePayload(
            chatGuid = "iMessage;+;chat12345",
            senderName = "Bob",
            messageText = "Photo attached",
            isGroup = true,
            groupTitle = "Family Chat",
            timestamp = 1700000005000L,
            isTapback = false,
            onlyAlertOnce = false,
            senderAddress = "+15559876543",
            messageGuid = "msg-guid-2",
            photoThumbB64 = fakeThumb
        )

        val obj = JsonParser.parseString(payloadStr).asJsonObject
        assertEquals("iMessage;+;chat12345", obj.get("chatGuid").asString)
        assertEquals("Bob", obj.get("senderName").asString)
        assertTrue(obj.get("isGroup").asBoolean)
        assertEquals("Family Chat", obj.get("groupTitle").asString)
        assertEquals(fakeThumb, obj.get("photoThumbB64").asString)
    }

    @Test
    fun `buildPhoneActiveChatPayload returns chatGuid or empty string`() {
        val activePayload = WearSyncManager.buildPhoneActiveChatPayload("iMessage;-;+15551234567")
        val activeObj = JsonParser.parseString(activePayload).asJsonObject
        assertEquals("iMessage;-;+15551234567", activeObj.get("chatGuid").asString)

        val nullPayload = WearSyncManager.buildPhoneActiveChatPayload(null)
        val nullObj = JsonParser.parseString(nullPayload).asJsonObject
        assertEquals("", nullObj.get("chatGuid").asString)

        val emptyPayload = WearSyncManager.buildPhoneActiveChatPayload("   ")
        val emptyObj = JsonParser.parseString(emptyPayload).asJsonObject
        assertEquals("", emptyObj.get("chatGuid").asString)

        val negativeOnePayload = WearSyncManager.buildPhoneActiveChatPayload("-1")
        val negativeOneObj = JsonParser.parseString(negativeOnePayload).asJsonObject
        assertEquals("", negativeOneObj.get("chatGuid").asString)
    }

    @Test
    fun `phoneActiveChatGuid tracks active chat and suppresses matching notifications`() {
        assertFalse(WearSyncManager.isPhoneActiveChat("iMessage;-;+15551234567"))
        assertFalse(WearSyncManager.isPhoneActiveChat(null))
        assertFalse(WearSyncManager.isPhoneActiveChat(""))

        WearSyncManager.phoneActiveChatGuid = "iMessage;-;+15551234567"
        assertTrue(WearSyncManager.isPhoneActiveChat("iMessage;-;+15551234567"))
        assertFalse(WearSyncManager.isPhoneActiveChat("iMessage;-;+15559999999"))
        assertFalse(WearSyncManager.isPhoneActiveChat(null))
        assertFalse(WearSyncManager.isPhoneActiveChat(""))
        assertFalse(WearSyncManager.isPhoneActiveChat("-1"))

        WearSyncManager.phoneActiveChatGuid = null
        assertFalse(WearSyncManager.isPhoneActiveChat("iMessage;-;+15551234567"))
    }

    @Test
    fun `applyOpenChatIntentExtras sets type, chatGuid, and optional draftText`() {
        val strings = mutableMapOf<String, String>()
        val bools = mutableMapOf<String, Boolean>()
        var type: String? = null

        WearSyncManager.applyOpenChatIntentExtras(
            chatGuid = "iMessage;-;+15551234567",
            draftText = "Replying with text",
            putString = { k, v -> strings[k] = v },
            putBoolean = { k, v -> bools[k] = v },
            setType = { type = it }
        )

        assertEquals("OpenChat", type)
        assertEquals("iMessage;-;+15551234567", strings["chatGuid"])
        assertEquals("Replying with text", strings["text"])
        assertEquals(false, bools["bubble"])

        // Without draftText
        strings.clear()
        bools.clear()
        type = null

        WearSyncManager.applyOpenChatIntentExtras(
            chatGuid = "iMessage;-;+15551234567",
            draftText = null,
            putString = { k, v -> strings[k] = v },
            putBoolean = { k, v -> bools[k] = v },
            setType = { type = it }
        )

        assertEquals("OpenChat", type)
        assertEquals("iMessage;-;+15551234567", strings["chatGuid"])
        assertNull(strings["text"])
        assertEquals(false, bools["bubble"])
    }

    @Test
    fun `parseForwardableMessage extracts chatGuid and active chat suppression works`() {
        val messageJson = """
            {
              "guid": "msg-push-123",
              "text": "Hey there",
              "dateCreated": 1700000010000,
              "isFromMe": false,
              "chats": [
                { "guid": "iMessage;-;+15551234567" }
              ]
            }
        """.trimIndent()

        val parsed = WearSyncManager.parseForwardableMessage(messageJson)
        assertNotNull(parsed)
        val (chatGuid, dto) = parsed!!
        assertEquals("iMessage;-;+15551234567", chatGuid)
        assertEquals("msg-push-123", dto.get("guid").asString)

        WearSyncManager.phoneActiveChatGuid = "iMessage;-;+15551234567"
        assertTrue(WearSyncManager.isPhoneActiveChat(chatGuid))

        WearSyncManager.phoneActiveChatGuid = "iMessage;-;+15559999999"
        assertFalse(WearSyncManager.isPhoneActiveChat(chatGuid))
    }

    @Test
    fun `encodeBase64String encodes byte array correctly`() {
        val sample = "Hello Wearable World".toByteArray(Charsets.UTF_8)
        val b64 = WearSyncManager.encodeBase64String(sample)
        val decoded = java.util.Base64.getDecoder().decode(b64.trim())
        assertEquals("Hello Wearable World", String(decoded, Charsets.UTF_8))
    }
}
