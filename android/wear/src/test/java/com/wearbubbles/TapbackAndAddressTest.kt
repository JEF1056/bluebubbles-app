package com.wearbubbles

import com.wearbubbles.api.dto.AddressNormalizer
import com.wearbubbles.api.dto.TapbackType
import com.wearbubbles.api.dto.TapbackUtils
import com.wearbubbles.db.entities.MessageEntity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TapbackAndAddressTest {

    private fun msg(
        guid: String,
        isFromMe: Boolean = false,
        dateCreated: Long = 1000L,
        assocGuid: String? = null,
        assocType: String? = null,
        assocEmoji: String? = null
    ) = MessageEntity(
        guid = guid,
        chatGuid = "iMessage;-;+15551234567",
        text = null,
        isFromMe = isFromMe,
        handleAddress = if (isFromMe) null else "+15551234567",
        dateCreated = dateCreated,
        dateDelivered = 0L,
        dateRead = 0L,
        associatedMessageGuid = assocGuid,
        associatedMessageType = assocType,
        associatedMessageEmoji = assocEmoji,
        sendFailed = false,
        attachmentGuid = null,
        attachmentMimeType = null
    )

    @Test
    fun `all six picker tapback types map cleanly and support removal`() {
        assertEquals(6, TapbackType.pickerEntries.size)
        assertEquals(7, TapbackType.entries.size)

        val entities = listOf(
            msg("m1", isFromMe = false, dateCreated = 100L),
            msg("r1", isFromMe = true, dateCreated = 200L, assocGuid = "p:0/m1", assocType = "2000"),
            msg("r2", isFromMe = false, dateCreated = 250L, assocGuid = "bp:m1", assocType = "2001"),
            msg("r3", isFromMe = true, dateCreated = 300L, assocGuid = "p:0/m1", assocType = "3000"), // removes r1
            msg("r4", isFromMe = false, dateCreated = 350L, assocGuid = "m1", assocType = "2003"),
            msg("r5", isFromMe = true, dateCreated = 400L, assocGuid = "m1", assocType = "2004"),
            msg("r6", isFromMe = false, dateCreated = 450L, assocGuid = "m1", assocType = "2005")
        )

        val reactions = TapbackUtils.computeReactions(entities)["m1"].orEmpty()
        assertFalse(reactions.any { it.type == TapbackType.LOVE })
        assertTrue(reactions.any { it.type == TapbackType.LIKE && it.count == 1 && !it.isFromMe })
        assertTrue(reactions.any { it.type == TapbackType.LAUGH && it.count == 1 })
        assertTrue(reactions.any { it.type == TapbackType.EMPHASIZE && it.isFromMe })
        assertTrue(reactions.any { it.type == TapbackType.QUESTION && !it.isFromMe })
    }

    @Test
    fun `server string tapback codes and emoji tapback glyphs map and remove cleanly`() {
        assertEquals(TapbackType.LOVE, TapbackType.fromAddCode("love"))
        assertEquals(TapbackType.LIKE, TapbackType.fromAddCode("like"))
        assertEquals(TapbackType.DISLIKE, TapbackType.fromAddCode("dislike"))
        assertEquals(TapbackType.LAUGH, TapbackType.fromAddCode("laugh"))
        assertEquals(TapbackType.EMPHASIZE, TapbackType.fromAddCode("emphasize"))
        assertEquals(TapbackType.QUESTION, TapbackType.fromAddCode("question"))
        assertEquals(TapbackType.EMOJI, TapbackType.fromAddCode("emoji"))
        assertEquals(TapbackType.EMOJI, TapbackType.fromAddCode("2006"))

        assertEquals(TapbackType.LOVE, TapbackType.fromRemoveCode("-love"))
        assertEquals(TapbackType.EMOJI, TapbackType.fromRemoveCode("-emoji"))
        assertEquals(TapbackType.EMOJI, TapbackType.fromRemoveCode("3006"))
        assertTrue(TapbackUtils.isTapbackCode("love"))
        assertTrue(TapbackUtils.isTapbackCode("-emphasize"))
        assertTrue(TapbackUtils.isTapbackCode("emoji"))
        assertTrue(TapbackUtils.isTapbackCode("-emoji"))
        assertTrue(TapbackUtils.isTapbackCode("2006"))
        assertTrue(TapbackUtils.isTapbackCode("3006"))

        val entities = listOf(
            msg("m1", isFromMe = false, dateCreated = 100L),
            msg("r1", isFromMe = true, dateCreated = 200L, assocGuid = "p:0/m1", assocType = "love"),
            msg("r2", isFromMe = true, dateCreated = 300L, assocGuid = "p:0/m1", assocType = "-love"),
            msg("r3", isFromMe = false, dateCreated = 350L, assocGuid = "p:0/m1", assocType = "emoji", assocEmoji = "🔥"),
            msg("r4", isFromMe = true, dateCreated = 400L, assocGuid = "p:0/m1", assocType = "2006", assocEmoji = "🎉"),
            msg("r5", isFromMe = true, dateCreated = 450L, assocGuid = "p:0/m1", assocType = "-emoji", assocEmoji = "🎉")
        )

        val reactions = TapbackUtils.computeReactions(entities)["m1"].orEmpty()
        assertFalse(reactions.any { it.type == TapbackType.LOVE })
        assertTrue(reactions.any { it.type == TapbackType.EMOJI && it.displayEmoji == "🔥" && !it.isFromMe })
        assertFalse(reactions.any { it.displayEmoji == "🎉" })
    }

    @Test
    fun `address normalizer handles phones and emails`() {
        assertEquals("5551234567", AddressNormalizer.normalize("(555) 123-4567"))
        assertEquals("5551234567", AddressNormalizer.normalize("+15551234567"))
        assertEquals("7911123456", AddressNormalizer.normalize("+44 7911 123456"))
        assertEquals("user@example.com", AddressNormalizer.normalize(" User@Example.com "))
    }
}
