package com.wearbubbles

import com.google.gson.JsonParser
import com.wearbubbles.api.dto.AttachmentDto
import com.wearbubbles.api.dto.LinkPreviewDto
import com.wearbubbles.api.dto.MessageDto
import com.wearbubbles.api.dto.MessageRelayDto
import com.wearbubbles.data.LinkPreviewHelper
import com.wearbubbles.db.AppDatabase
import com.wearbubbles.db.entities.MessageEntity
import com.wearbubbles.ui.messages.selectEagerAttachmentGuids
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WearMediaAndLinkPreviewTest {

    @Test
    fun `relayDtoToEntity preserves all attachments and link preview metadata`() {
        val dto = MessageRelayDto(
            guid = "msg-1",
            chatGuid = "iMessage;-;+15550001111",
            text = "Check out these photos",
            isFromMe = false,
            dateCreated = 1_700_000_000_000L,
            attachmentGuid = "att-1",
            attachmentMimeType = "image/jpeg",
            attachments = listOf(
                AttachmentDto("att-1", "image/jpeg", "IMG_1.jpg"),
                AttachmentDto("att-2", "image/png", "IMG_2.png"),
                AttachmentDto("att-3", "image/webp", "IMG_3.webp")
            ),
            balloonBundleId = LinkPreviewHelper.URL_BALLOON_BUNDLE_ID,
            linkPreview = LinkPreviewDto(
                title = "Article Title",
                subtitle = "Summary",
                url = "https://www.example.com/a",
                site = "example.com",
                imageAttachmentGuid = "plugin-1"
            )
        )

        val entity = LinkPreviewHelper.relayDtoToEntity(dto)
        val parsedAtts = LinkPreviewHelper.parseAttachments(
            entity.attachmentsJson,
            entity.attachmentGuid,
            entity.attachmentMimeType
        )
        assertEquals(3, parsedAtts.size)
        assertEquals(listOf("att-1", "att-2", "att-3"), parsedAtts.map { it.guid })

        val parsedPreview = LinkPreviewHelper.parseLinkPreview(entity.linkPreviewJson)
        assertNotNull(parsedPreview)
        assertEquals("Article Title", parsedPreview!!.title)
        assertEquals("example.com", parsedPreview.site)
        assertEquals("plugin-1", parsedPreview.imageAttachmentGuid)
    }

    @Test
    fun `messageDtoToEntity extracts NSKeyedArchiver payloadData and keeps non-plugin attachment primary`() {
        val payloadJson = JsonParser.parseString(
            """
            [
              {
                "${'$'}archiver": "NSKeyedArchiver",
                "${'$'}objects": [
                  "${'$'}null",
                  { "NS.keys": [], "NS.objects": [] },
                  {
                    "title": { "UID": 3 },
                    "originalURL": { "UID": 4 }
                  },
                  "Wear OS Guide",
                  { "NS.relative": "https://www.android.com/wear/" }
                ]
              }
            ]
            """.trimIndent()
        )
        val dto = MessageDto(
            guid = "msg-direct-1",
            text = "https://www.android.com/wear/",
            isFromMe = false,
            dateCreated = 1_700_000_002_000L,
            attachments = listOf(
                AttachmentDto("plugin-img", "image/jpeg", "pluginPayloadAttachment.jpg")
            ),
            balloonBundleId = LinkPreviewHelper.URL_BALLOON_BUNDLE_ID,
            payloadData = payloadJson
        )

        val entity = LinkPreviewHelper.messageDtoToEntity(dto, "iMessage;-;+15550001111")
        val preview = LinkPreviewHelper.parseLinkPreview(entity.linkPreviewJson)
        assertNotNull(preview)
        assertEquals("Wear OS Guide", preview!!.title)
        assertEquals("android.com", preview.site)
        assertEquals("plugin-img", preview.imageAttachmentGuid)
    }

    @Test
    fun `selectEagerAttachmentGuids picks multi-image attachments and preview artwork within limit`() {
        val multiJson = LinkPreviewHelper.serializeAttachments(
            listOf(
                AttachmentDto("att-a", "image/jpeg", "1.jpg"),
                AttachmentDto("att-b", "image/png", "2.png"),
                AttachmentDto("att-c", "image/jpeg", "3.jpg")
            )
        )
        val previewJson = LinkPreviewHelper.serializeLinkPreview(
            LinkPreviewDto(
                title = "Post",
                url = "https://example.com",
                site = "example.com",
                imageAttachmentGuid = "preview-att"
            )
        )
        val entities = listOf(
            MessageEntity(
                guid = "m-link",
                chatGuid = "c1",
                text = "https://example.com",
                isFromMe = false,
                dateCreated = 1000L,
                handleAddress = "+1555",
                linkPreviewJson = previewJson
            ),
            MessageEntity(
                guid = "m-multi",
                chatGuid = "c1",
                text = null,
                isFromMe = false,
                dateCreated = 2000L,
                handleAddress = "+1555",
                attachmentGuid = "att-a",
                attachmentMimeType = "image/jpeg",
                attachmentsJson = multiJson
            )
        )

        val selected = selectEagerAttachmentGuids(
            messages = entities,
            cachedGuids = setOf("att-b"),
            failedGuids = emptySet(),
            limit = 4
        )
        assertEquals(listOf("att-a", "att-c", "preview-att"), selected)
    }

    @Test
    fun `link preview helpers suppress redundant bare URL text and duplicate site lines`() {
        assertTrue(LinkPreviewHelper.shouldHideBareUrlText("https://example.com/a/", "https://example.com/a"))
        assertFalse(LinkPreviewHelper.shouldHideBareUrlText("Check this: https://example.com/a", "https://example.com/a"))
        assertFalse(LinkPreviewHelper.showsSiteLine("example.com", "example.com"))
        assertTrue(LinkPreviewHelper.showsSiteLine("Article Headline", "example.com"))
    }

    @Test
    fun `parseAttachments falls back to single legacy attachment columns`() {
        val legacy = LinkPreviewHelper.parseAttachments(
            attachmentsJson = null,
            fallbackGuid = "legacy-att",
            fallbackMimeType = "image/gif"
        )
        assertEquals(1, legacy.size)
        assertEquals("legacy-att", legacy[0].guid)
        assertEquals("image/gif", legacy[0].mimeType)
        assertEquals(11, AppDatabase.MIGRATION_11_12.startVersion)
        assertEquals(12, AppDatabase.MIGRATION_11_12.endVersion)
    }
}
