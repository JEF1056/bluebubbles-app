package com.wearbubbles

import com.wearbubbles.api.ApiClient
import com.wearbubbles.api.dto.ReactionBadge
import com.wearbubbles.api.dto.TapbackType
import com.wearbubbles.relay.PhoneRelayClient
import com.wearbubbles.ui.messages.MessageUi
import com.wearbubbles.ui.messages.buildMessageRows
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicInteger

class WearRelayAndCrashFixTest {

    @Test
    fun `buildMessageRows snapshots messages, grouping, and prevHadReactions cleanly`() {
        val backing = mutableListOf(
            sampleMsg(guid = "m1", date = 1_000L, reactions = listOf(ReactionBadge(TapbackType.LOVE, 1, false))),
            sampleMsg(guid = "m2", date = 2_000L, reactions = emptyList()),
            sampleMsg(guid = "m3", date = 3_000L, reactions = emptyList())
        )

        val rows = buildMessageRows(backing)
        // Mutating the source list afterwards must not affect or shrink the snapshot.
        backing.removeAt(backing.lastIndex)

        assertEquals(3, rows.size)
        assertEquals("m1", rows[0].message.guid)
        assertFalse(rows[0].prevHadReactions)
        assertEquals("m2", rows[1].message.guid)
        assertTrue(rows[1].prevHadReactions)
        assertEquals("m3", rows[2].message.guid)
        assertFalse(rows[2].prevHadReactions)
        assertEquals(emptyList<Any>(), buildMessageRows(emptyList()))
    }

    @Test
    fun `ApiClient getAttachmentUrl adds 512px resize params only for non-GIF images`() {
        val jpegUrl = ApiClient.getAttachmentUrl("https://bb.example.com/", "pw", "att-1", "image/jpeg")
        assertTrue(jpegUrl.endsWith("&width=512&quality=good"))

        val pngWithParams = ApiClient.getAttachmentUrl("https://bb.example.com", "pw", "att-2", "IMAGE/PNG; charset=utf-8")
        assertTrue(pngWithParams.endsWith("&width=512&quality=good"))

        val gifUrl = ApiClient.getAttachmentUrl("https://bb.example.com", "pw", "att-3", "image/gif")
        assertFalse(gifUrl.contains("width="))

        val audioUrl = ApiClient.getAttachmentUrl("https://bb.example.com", "pw", "att-4", "audio/mp4")
        assertFalse(audioUrl.contains("width="))

        val untypedUrl = ApiClient.getAttachmentUrl("https://bb.example.com", "pw", "att-5")
        assertFalse(untypedUrl.contains("width="))
    }

    @Test
    fun `copyChannelStreamBounded enforces hard cap and aborts oversized payloads`() {
        val okPayload = ByteArray(1024) { 7 }
        val okOut = ByteArrayOutputStream()
        assertEquals(1024L, PhoneRelayClient.copyChannelStreamBounded(ByteArrayInputStream(okPayload), okOut, maxBytes = 1024L))
        assertEquals(1024, okOut.size())

        val tooBig = ByteArray(1025) { 9 }
        val bigOut = ByteArrayOutputStream()
        assertEquals(-1L, PhoneRelayClient.copyChannelStreamBounded(ByteArrayInputStream(tooBig), bigOut, maxBytes = 1024L))
    }

    @Test
    fun `debounced disconnect cancels on brief blip and fires only on sustained disconnect`() = runBlocking {
        val fired = AtomicInteger(0)

        // Brief blip: cancel before debounce elapses.
        val blipJob = DataLayerListenerService.scheduleDebouncedDisconnect(
            scope = this,
            delayMs = 120L,
            confirmStillDisconnected = { true },
            onConfirmedDisconnect = { fired.incrementAndGet() }
        )
        delay(30L)
        DataLayerListenerService.cancelPendingDisconnect()
        blipJob.join()
        assertEquals(0, fired.get())

        // Reconnected silently before confirmation check.
        val reconnectedJob = DataLayerListenerService.scheduleDebouncedDisconnect(
            scope = this,
            delayMs = 30L,
            confirmStillDisconnected = { false },
            onConfirmedDisconnect = { fired.incrementAndGet() }
        )
        reconnectedJob.join()
        assertEquals(0, fired.get())

        // Sustained disconnect: fires once.
        val sustainedJob = DataLayerListenerService.scheduleDebouncedDisconnect(
            scope = this,
            delayMs = 30L,
            confirmStillDisconnected = { true },
            onConfirmedDisconnect = { fired.incrementAndGet() }
        )
        sustainedJob.join()
        assertEquals(1, fired.get())
    }

    private fun sampleMsg(
        guid: String,
        date: Long,
        reactions: List<ReactionBadge>
    ) = MessageUi(
        guid = guid,
        text = "hi",
        isFromMe = false,
        senderName = "Alice",
        dateCreated = date,
        dateDelivered = 0L,
        dateRead = 0L,
        sendFailed = false,
        reactions = reactions,
        attachmentGuid = null,
        attachmentMimeType = null,
        attachmentUrl = null,
        localAttachmentPath = null,
        customHeaders = emptyMap(),
        isLatestOutgoing = false
    )
}
