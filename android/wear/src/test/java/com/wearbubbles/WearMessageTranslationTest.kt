package com.wearbubbles

import com.google.gson.Gson
import com.google.gson.JsonParser
import com.wearbubbles.api.dto.MessageDto
import com.wearbubbles.api.dto.MessageRelayDto
import com.wearbubbles.api.dto.MessageTranslationDto
import com.wearbubbles.data.MessageRepository
import com.wearbubbles.db.AppDatabase
import com.wearbubbles.db.MessageDao
import com.wearbubbles.db.entities.MessageEntity
import com.wearbubbles.relay.PhoneRelayClient.Companion.toEntity
import com.wearbubbles.ui.messages.MessageUi
import com.wearbubbles.ui.messages.resolveBubbleDisplayText
import com.wearbubbles.ui.messages.resolveTranslationActionLabel
import com.wearbubbles.ui.messages.resolveTranslationCaption
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class WearMessageTranslationTest {

    private val gson = Gson()

    @Test
    fun `dtos deserialize translation and dateEdited and map to MessageEntity`() {
        val relayJson = """
            {
              "guid": "msg-1",
              "chatGuid": "iMessage;-;+15551234567",
              "text": "Hola",
              "isFromMe": false,
              "dateCreated": 1000,
              "dateEdited": 2000,
              "translatedText": "Hello",
              "translationSourceLang": "es",
              "translationTargetLang": "en"
            }
        """.trimIndent()
        val relayDto = gson.fromJson(relayJson, MessageRelayDto::class.java)
        val relayEntity = relayDto.toEntity()
        assertEquals("Hello", relayEntity.translatedText)
        assertEquals("es", relayEntity.translationSourceLang)
        assertEquals("en", relayEntity.translationTargetLang)
        assertEquals(2000L, relayEntity.dateEdited)

        val apiJson = """
            {
              "guid": "msg-2",
              "text": "Merci",
              "isFromMe": false,
              "dateCreated": 3000,
              "dateEdited": 4000,
              "translation": {
                "text": "Thanks",
                "sourceLanguage": "fr",
                "targetLanguage": "en",
                "provider": "apple",
                "autoTranslated": true,
                "dateTranslated": 4100
              }
            }
        """.trimIndent()
        val msgDto = gson.fromJson(apiJson, MessageDto::class.java)
        assertEquals(4000L, msgDto.dateEdited)
        assertEquals("Thanks", msgDto.translation?.text)
        assertEquals("fr", msgDto.translation?.sourceLanguage)
        assertEquals("en", msgDto.translation?.targetLanguage)
    }

    @Test
    fun `parseTranslationFromResponse extracts translation and ignores message without translation`() {
        val wrapped = JsonParser.parseString(
            """{"guid":"m1","text":"Hola","translation":{"text":"Hello","sourceLanguage":"es","targetLanguage":"en"}}"""
        ).asJsonObject
        val tr1 = MessageRepository.parseTranslationFromResponse(wrapped)
        assertNotNull(tr1)
        assertEquals("Hello", tr1?.text)
        assertEquals("es", tr1?.sourceLanguage)

        val skippedMessage = JsonParser.parseString(
            """{"guid":"m2","text":"Hello"}"""
        ).asJsonObject
        assertNull(MessageRepository.parseTranslationFromResponse(skippedMessage))
    }

    @Test
    fun `mergeTranslationIfUnchanged preserves existing translation unless text or dateEdited changed`() {
        val existing = MessageEntity(
            guid = "m1",
            chatGuid = "c1",
            text = "Hola",
            isFromMe = false,
            handleAddress = "+1555",
            dateCreated = 1000L,
            translatedText = "Hello",
            translationSourceLang = "es",
            translationTargetLang = "en",
            dateEdited = 0L
        )

        val receiptUpdate = existing.copy(
            dateRead = 5000L,
            translatedText = null,
            translationSourceLang = null,
            translationTargetLang = null
        )
        val merged = MessageDao.mergeTranslationIfUnchanged(receiptUpdate, existing)
        assertEquals("Hello", merged.translatedText)
        assertEquals("es", merged.translationSourceLang)
        assertEquals(5000L, merged.dateRead)

        val editedUpdate = existing.copy(
            text = "Adios",
            dateEdited = 6000L,
            translatedText = null,
            translationSourceLang = null,
            translationTargetLang = null
        )
        val cleared = MessageDao.mergeTranslationIfUnchanged(editedUpdate, existing)
        assertNull(cleared.translatedText)
    }

    @Test
    fun `migration 10 to 11 has expected bounds`() {
        assertEquals(10, AppDatabase.MIGRATION_10_11.startVersion)
        assertEquals(11, AppDatabase.MIGRATION_10_11.endVersion)
    }

    @Test
    fun `ui helpers show translated text by default and format quiet captions and action labels`() {
        val incomingTranslated = MessageUi(
            guid = "m1",
            text = "Hola",
            isFromMe = false,
            senderName = "Ana",
            dateCreated = 1000L,
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
            handleAddress = "+1555",
            dateEdited = 2000L,
            translatedText = "Hello",
            translationSourceLang = "es",
            translationTargetLang = "en",
            showOriginalTranslation = false
        )
        assertEquals("Hello", resolveBubbleDisplayText(incomingTranslated))
        assertEquals(
            "Translated · ES",
            resolveTranslationCaption(
                isFromMe = false,
                translatedText = "Hello",
                sourceLanguage = "es",
                showOriginalTranslation = false,
                isTranslating = false
            )
        )
        assertEquals("Show original", resolveTranslationActionLabel(hasTranslation = true, showOriginalTranslation = false, isTranslating = false))

        val toggledOriginal = incomingTranslated.copy(showOriginalTranslation = true, dateEdited = 0L)
        assertEquals("Hola", resolveBubbleDisplayText(toggledOriginal))
        assertEquals(
            "Original · Translate",
            resolveTranslationCaption(
                isFromMe = false,
                translatedText = "Hello",
                sourceLanguage = "es",
                showOriginalTranslation = true,
                isTranslating = false
            )
        )
        assertEquals("Show translation", resolveTranslationActionLabel(hasTranslation = true, showOriginalTranslation = true, isTranslating = false))

        assertEquals(
            "Translated · FR",
            resolveTranslationCaption(
                isFromMe = false,
                translatedText = "Hi",
                sourceLanguage = "fr",
                showOriginalTranslation = false,
                isTranslating = false
            )
        )
        assertNull(
            resolveTranslationCaption(
                isFromMe = true,
                translatedText = "Hi",
                sourceLanguage = "fr",
                showOriginalTranslation = false,
                isTranslating = false
            )
        )
        assertEquals("Translate", resolveTranslationActionLabel(hasTranslation = false, showOriginalTranslation = false, isTranslating = false))
    }
}
