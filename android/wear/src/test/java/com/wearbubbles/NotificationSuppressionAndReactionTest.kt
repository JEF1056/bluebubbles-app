package com.wearbubbles

import com.wearbubbles.notifications.NotificationHelper
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.io.path.createTempDirectory

class NotificationSuppressionAndReactionTest {

    @After
    fun tearDown() {
        NotificationHelper.setActiveChat(null)
        NotificationHelper.setPhoneActiveChat(null, null)
    }

    @Test
    fun `setPhoneActiveChat updates phoneActiveChatGuid and suppresses matching notifications`() {
        val chatA = "iMessage;-;+15551112222"
        val chatB = "iMessage;-;+15553334444"

        NotificationHelper.setPhoneActiveChat(null, chatA)
        assertEquals(chatA, NotificationHelper.phoneActiveChatGuid)
        assertTrue(NotificationHelper.shouldSuppressNotification(chatA))
        assertFalse(NotificationHelper.shouldSuppressNotification(chatB))

        NotificationHelper.setPhoneActiveChat(null, "   ")
        assertNull(NotificationHelper.phoneActiveChatGuid)
        assertFalse(NotificationHelper.shouldSuppressNotification(chatA))
    }

    @Test
    fun `shouldSuppressNotification respects both watch active chat and phone active chat`() {
        val watchChat = "iMessage;-;+15550001111"
        val phoneChat = "iMessage;-;+15550002222"
        val otherChat = "iMessage;-;+15550003333"

        NotificationHelper.setActiveChat(watchChat)
        NotificationHelper.setPhoneActiveChat(null, phoneChat)

        assertTrue(NotificationHelper.shouldSuppressNotification(watchChat))
        assertTrue(NotificationHelper.shouldSuppressNotification(phoneChat))
        assertFalse(NotificationHelper.shouldSuppressNotification(otherChat))
    }

    @Test
    fun `phone active chat path and json parser handle valid and invalid payloads`() {
        assertEquals("/wearbubbles/phone_active_chat", DataLayerListenerService.PATH_PHONE_ACTIVE_CHAT)
        assertEquals(
            "iMessage;-;+15551234567",
            DataLayerListenerService.parsePhoneActiveChatGuid("""{"chatGuid":"iMessage;-;+15551234567"}""")
        )
        assertNull(DataLayerListenerService.parsePhoneActiveChatGuid("""{"chatGuid":""}"""))
        assertNull(DataLayerListenerService.parsePhoneActiveChatGuid("""{"chatGuid":null}"""))
        assertNull(DataLayerListenerService.parsePhoneActiveChatGuid("""{}"""))
        assertNull(DataLayerListenerService.parsePhoneActiveChatGuid("not-json"))
    }

    @Test
    fun `pruneNotifPhotos removes expired and excess files while keeping newest`() {
        val tempDir = createTempDirectory("notif_photos_test").toFile()
        try {
            val now = 1_000_000_000L
            val expired = File(tempDir, "expired.jpg").apply {
                writeBytes(byteArrayOf(1, 2, 3))
                setLastModified(now - 25L * 60L * 60L * 1000L)
            }
            val oldestKept = File(tempDir, "old.jpg").apply {
                writeBytes(byteArrayOf(1, 2, 3))
                setLastModified(now - 30_000L)
            }
            val middleKept = File(tempDir, "mid.jpg").apply {
                writeBytes(byteArrayOf(1, 2, 3))
                setLastModified(now - 20_000L)
            }
            val newestKept = File(tempDir, "new.jpg").apply {
                writeBytes(byteArrayOf(1, 2, 3))
                setLastModified(now - 10_000L)
            }

            NotificationHelper.pruneNotifPhotos(
                dir = tempDir,
                maxFiles = 2,
                maxAgeMs = 24L * 60L * 60L * 1000L,
                nowMs = now
            )

            assertFalse(expired.exists())
            assertFalse(oldestKept.exists())
            assertTrue(middleKept.exists())
            assertTrue(newestKept.exists())
        } finally {
            tempDir.deleteRecursively()
        }
    }

    @Test
    fun `quick reaction action and extras constants are populated and distinct`() {
        assertTrue(NotificationHelper.ACTION_QUICK_REACTION.isNotBlank())
        assertTrue(NotificationHelper.EXTRA_MESSAGE_GUID.isNotBlank())
        assertTrue(NotificationHelper.EXTRA_REACTION.isNotBlank())
        assertTrue(NotificationHelper.ACTION_QUICK_REACTION != NotificationHelper.ACTION_REPLY)
        assertTrue(NotificationHelper.EXTRA_MESSAGE_GUID != NotificationHelper.EXTRA_CHAT_GUID)
        assertTrue(NotificationHelper.EXTRA_REACTION != NotificationHelper.EXTRA_MESSAGE_GUID)
    }
}
