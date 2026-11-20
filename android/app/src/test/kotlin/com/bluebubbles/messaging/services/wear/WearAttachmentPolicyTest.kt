package com.bluebubbles.messaging.services.wear

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream

class WearAttachmentPolicyTest {

    @Test
    fun `buildWatchAttachmentDownloadUrl requests 512px good quality resize`() {
        val url = WearSyncManager.buildWatchAttachmentDownloadUrl(
            apiRoot = "https://bb.example.com/api/v1",
            attachmentGuid = "att/123",
            authKey = "pass word"
        )
        assertTrue(url.startsWith("https://bb.example.com/api/v1/attachment/att%2F123/download?password=pass+word"))
        assertTrue(url.endsWith("&width=512&quality=good"))
    }

    @Test
    fun `classifyWatchAttachment applies MIME allowlist and size caps`() {
        assertEquals(
            WearSyncManager.WatchAttachmentAction.COMPRESS_STATIC_IMAGE,
            WearSyncManager.classifyWatchAttachment("image/jpeg; charset=binary", 1_500_000L)
        )
        assertEquals(
            WearSyncManager.WatchAttachmentAction.COMPRESS_STATIC_IMAGE,
            WearSyncManager.classifyWatchAttachment("image/png", -1L)
        )
        assertEquals(
            WearSyncManager.WatchAttachmentAction.REJECT,
            WearSyncManager.classifyWatchAttachment("image/jpeg", WearSyncManager.WATCH_IMAGE_MAX_READ_BYTES + 1L)
        )

        assertEquals(
            WearSyncManager.WatchAttachmentAction.GIF_PASSTHROUGH_OR_PREVIEW,
            WearSyncManager.classifyWatchAttachment("image/gif", 500_000L)
        )
        assertEquals(
            WearSyncManager.WatchAttachmentAction.REJECT,
            WearSyncManager.classifyWatchAttachment("image/gif", WearSyncManager.WATCH_IMAGE_MAX_READ_BYTES + 1L)
        )

        assertEquals(
            WearSyncManager.WatchAttachmentAction.STREAM_BOUNDED_AUDIO,
            WearSyncManager.classifyWatchAttachment("audio/mp4", WearSyncManager.WATCH_AUDIO_MAX_BYTES.toLong())
        )
        assertEquals(
            WearSyncManager.WatchAttachmentAction.REJECT,
            WearSyncManager.classifyWatchAttachment("audio/mp4", WearSyncManager.WATCH_AUDIO_MAX_BYTES + 1L)
        )

        assertEquals(
            WearSyncManager.WatchAttachmentAction.REJECT,
            WearSyncManager.classifyWatchAttachment("video/quicktime", 100_000L)
        )
        assertEquals(
            WearSyncManager.WatchAttachmentAction.REJECT,
            WearSyncManager.classifyWatchAttachment("application/pdf", 10_000L)
        )
        assertEquals(
            WearSyncManager.WatchAttachmentAction.REJECT,
            WearSyncManager.classifyWatchAttachment(null, 1_000L)
        )
    }

    @Test
    fun `computeInSampleSize returns largest power of two keeping max side at or above target`() {
        assertEquals(1, WearSyncManager.computeInSampleSize(512, 384, 512))
        assertEquals(1, WearSyncManager.computeInSampleSize(800, 600, 512))
        assertEquals(2, WearSyncManager.computeInSampleSize(1024, 768, 512))
        assertEquals(4, WearSyncManager.computeInSampleSize(4032, 3024, 512))
        assertEquals(1, WearSyncManager.computeInSampleSize(0, 0, 512))
    }

    @Test
    fun `readBoundedBytes enforces hard byte limit`() {
        val exact = ByteArray(1024) { it.toByte() }
        assertArrayEquals(exact, WearSyncManager.readBoundedBytes(ByteArrayInputStream(exact), 1024))
        assertNull(WearSyncManager.readBoundedBytes(ByteArrayInputStream(ByteArray(1025)), 1024))
    }
}
