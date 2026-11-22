package com.bluebubbles.messaging.services.wear

import com.google.gson.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class WearMessageTranslationTest {

    @Test
    fun `buildTranslateUrl encodes guid and password`() {
        val url = WearSyncManager.buildTranslateUrl(
            apiRoot = "https://bb.example.com/api/v1",
            messageGuid = "msg/with space",
            authKey = "p@ss word"
        )
        assertEquals(
            "https://bb.example.com/api/v1/message/msg%2Fwith%20space/translate?password=p%40ss+word",
            url
        )
    }

    @Test
    fun `parseTranslationData extracts data translation and ignores skipped messages`() {
        val translatedBody = JsonObject().apply {
            addProperty("status", 200)
            add("data", JsonObject().apply {
                addProperty("guid", "msg-1")
                addProperty("text", "Bonjour")
                add("translation", JsonObject().apply {
                    addProperty("text", "Hello")
                    addProperty("sourceLanguage", "fr")
                    addProperty("targetLanguage", "en")
                })
            })
        }.toString()

        val tr = WearSyncManager.parseTranslationData(translatedBody)
        assertNotNull(tr)
        assertEquals("Hello", tr!!.get("text").asString)
        assertEquals("fr", tr.get("sourceLanguage").asString)
        assertEquals("en", tr.get("targetLanguage").asString)

        val skippedBody = """{"status":200,"data":{"guid":"msg-2","text":"Hello there","isFromMe":false}}"""
        assertNull(WearSyncManager.parseTranslationData(skippedBody))
    }
}
