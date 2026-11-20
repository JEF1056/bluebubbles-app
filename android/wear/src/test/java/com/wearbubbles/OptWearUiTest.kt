package com.wearbubbles

import com.wearbubbles.db.entities.MessageEntity
import com.wearbubbles.ui.messages.MessageDetailViewModel
import com.wearbubbles.ui.messages.resolveEffectiveChatGuid
import com.wearbubbles.ui.messages.selectEagerAttachmentGuids
import org.junit.Assert.assertEquals
import org.junit.Test

class OptWearUiTest {

    @Test
    fun `resolveEffectiveChatGuid switches to canonical server guid when non-blank`() {
        assertEquals(
            "SMS;-;+15551234567",
            resolveEffectiveChatGuid("iMessage;-;+15551234567", "SMS;-;+15551234567")
        )
        assertEquals(
            "iMessage;-;+15551234567",
            resolveEffectiveChatGuid("iMessage;-;+15551234567", null)
        )
        assertEquals(
            "iMessage;-;+15551234567",
            resolveEffectiveChatGuid("iMessage;-;+15551234567", "   ")
        )
    }

    @Test
    fun `selectEagerAttachmentGuids caps to newest 8 uncached non-failed image or audio attachments`() {
        val entities = (1..12).map { i ->
            MessageEntity(
                guid = "msg-$i",
                chatGuid = "iMessage;-;+15551234567",
                text = null,
                isFromMe = false,
                handleAddress = "+15551234567",
                dateCreated = i.toLong() * 1000L,
                attachmentGuid = "att-$i",
                attachmentMimeType = if (i % 3 == 0) "audio/m4a" else "image/jpeg"
            )
        } + listOf(
            MessageEntity(
                guid = "msg-pdf",
                chatGuid = "iMessage;-;+15551234567",
                text = null,
                isFromMe = false,
                handleAddress = "+15551234567",
                dateCreated = 13_000L,
                attachmentGuid = "att-pdf",
                attachmentMimeType = "application/pdf"
            )
        )

        val selected = selectEagerAttachmentGuids(
            messages = entities,
            cachedGuids = setOf("att-11"),
            failedGuids = setOf("att-10"),
            limit = MessageDetailViewModel.MAX_EAGER_ATTACHMENTS
        )

        assertEquals(
            listOf("att-12", "att-9", "att-8", "att-7", "att-6", "att-5", "att-4", "att-3"),
            selected
        )
    }
}
