package com.wearbubbles

import com.wearbubbles.api.dto.ICloudContactDto
import com.wearbubbles.relay.PhoneRelayClient
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ProfileSyncTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    @Test
    fun `ICloudContactDto resolves display name and handle with fallbacks`() {
        val full = ICloudContactDto(
            account_name = "Account Name",
            name = "Short Name",
            display_name = "Jess Fan",
            first_name = "Jess",
            last_name = "Fan",
            apple_id = "jess@example.com",
            active_alias = "+15551234567"
        )
        assertEquals("Jess Fan", full.resolvedName())
        assertEquals("+15551234567", full.resolvedHandle())

        val fallback = ICloudContactDto(
            first_name = "Jess",
            last_name = "Fan",
            apple_id = "jess@example.com"
        )
        assertEquals("Jess Fan", fallback.resolvedName())
        assertEquals("jess@example.com", fallback.resolvedHandle())
    }

    @Test
    fun `self avatar limits keep DataLayer payload under 32KB`() {
        assertTrue(PhoneRelayClient.SELF_AVATAR_MAX_BYTES <= 32_000)
        assertTrue(PhoneRelayClient.SELF_AVATAR_MAX_DIM <= 160)
    }

    @Test
    fun `applySelfAvatarUpdate writes atomically and deletes local file when cleared upstream`() {
        val dir = tempFolder.newFolder("profile")
        val avatarFile = dir.resolve("self_avatar.img")
        val tmpFile = dir.resolve("self_avatar.img.tmp")

        val (writtenPath, updated) = PhoneRelayClient.applySelfAvatarUpdate(
            outFile = avatarFile,
            avatarBytes = byteArrayOf(1, 2, 3, 4),
            compress = { it }
        )
        assertTrue(updated)
        assertNotNull(writtenPath)
        assertTrue(avatarFile.exists())
        assertFalse(tmpFile.exists())
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), avatarFile.readBytes())

        val (clearedPath, cleared) = PhoneRelayClient.applySelfAvatarUpdate(
            outFile = avatarFile,
            avatarBytes = null
        )
        assertNull(clearedPath)
        assertTrue(cleared)
        assertFalse(avatarFile.exists())

        val (noopPath, noop) = PhoneRelayClient.applySelfAvatarUpdate(
            outFile = avatarFile,
            avatarBytes = byteArrayOf()
        )
        assertNull(noopPath)
        assertFalse(noop)
    }
}
