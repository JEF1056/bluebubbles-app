package com.bluebubbles.messaging.services.wear

import com.google.gson.JsonParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class WearLinkPreviewAndMultiAttachmentTest {

    @Test
    fun `mapMessageToRelayJson serializes all attachments in order`() {
        val msg = JsonParser.parseString(
            """
            {
              "guid": "msg-multi-1",
              "text": "Beach pics",
              "isFromMe": false,
              "dateCreated": 1700000000000,
              "handle": { "address": "+15551234567" },
              "attachments": [
                { "guid": "att-1", "mimeType": "image/jpeg", "transferName": "IMG_1.jpg" },
                { "guid": "att-2", "mimeType": "image/png", "transferName": "IMG_2.png" },
                { "guid": "att-3", "mimeType": "image/heic", "transferName": "IMG_3.heic" }
              ]
            }
            """.trimIndent()
        ).asJsonObject

        val relay = WearSyncManager.mapMessageToRelayJson(msg, "iMessage;-;+15551234567")
        assertEquals("att-1", relay.get("attachmentGuid").asString)
        assertEquals("image/jpeg", relay.get("attachmentMimeType").asString)

        val atts = relay.getAsJsonArray("attachments")
        assertNotNull(atts)
        assertEquals(3, atts.size())
        assertEquals("att-1", atts[0].asJsonObject.get("guid").asString)
        assertEquals("att-2", atts[1].asJsonObject.get("guid").asString)
        assertEquals("att-3", atts[2].asJsonObject.get("guid").asString)
        assertEquals("IMG_2.png", atts[1].asJsonObject.get("transferName").asString)
        assertNull(relay.get("linkPreview"))
    }

    @Test
    fun `mapMessageToRelayJson extracts parsed URLBalloonProvider payload and pluginPayloadAttachment`() {
        val msg = JsonParser.parseString(
            """
            {
              "guid": "msg-url-1",
              "text": "https://www.example.com/article",
              "isFromMe": false,
              "dateCreated": 1700000001000,
              "balloonBundleId": "com.apple.messages.URLBalloonProvider",
              "attachments": [
                { "guid": "plugin-att-1", "mimeType": "image/jpeg", "transferName": "pluginPayloadAttachment.jpg" }
              ],
              "payloadData": {
                "type": 0,
                "urlData": [
                  {
                    "title": "Example Headline",
                    "summary": "Short summary text",
                    "siteName": "Ignored OG Site",
                    "originalURL": { "NS.relative": "https://www.example.com/article" },
                    "URL": { "NS.relative": "https://www.example.com/article?utm=1" }
                  }
                ]
              }
            }
            """.trimIndent()
        ).asJsonObject

        val relay = WearSyncManager.mapMessageToRelayJson(msg, "iMessage;-;+15551234567")
        assertEquals("com.apple.messages.URLBalloonProvider", relay.get("balloonBundleId").asString)

        val preview = relay.getAsJsonObject("linkPreview")
        assertNotNull(preview)
        assertEquals("Example Headline", preview.get("title").asString)
        assertEquals("Short summary text", preview.get("subtitle").asString)
        assertEquals("https://www.example.com/article", preview.get("url").asString)
        assertEquals("example.com", preview.get("site").asString)
        assertEquals("plugin-att-1", preview.get("imageAttachmentGuid").asString)
    }

    @Test
    fun `extractLinkPreviewJson decodes NSKeyedArchiver bplist payloadData`() {
        val msg = JsonParser.parseString(
            """
            {
              "guid": "msg-bplist-1",
              "text": "https://news.ycombinator.com/item?id=1",
              "balloonBundleId": "com.apple.messages.URLBalloonProvider",
              "payloadData": [
                {
                  "${'$'}archiver": "NSKeyedArchiver",
                  "${'$'}objects": [
                    "${'$'}null",
                    { "NS.keys": [], "NS.objects": [] },
                    {
                      "title": { "UID": 3 },
                      "summary": { "UID": 4 },
                      "URL": { "UID": 5 }
                    },
                    "Hacker News Thread",
                    "Discussion on Wear OS",
                    { "NS.relative": "https://news.ycombinator.com/item?id=1" }
                  ]
                }
              ]
            }
            """.trimIndent()
        ).asJsonObject

        val preview = WearLinkPreview.extractLinkPreviewJson(msg, null)
        assertNotNull(preview)
        assertEquals("Hacker News Thread", preview!!.get("title").asString)
        assertEquals("Discussion on Wear OS", preview.get("subtitle").asString)
        assertEquals("news.ycombinator.com", preview.get("site").asString)
        assertEquals("https://news.ycombinator.com/item?id=1", preview.get("url").asString)
    }
}
