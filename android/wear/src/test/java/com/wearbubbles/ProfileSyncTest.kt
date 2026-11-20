package com.wearbubbles

import com.wearbubbles.api.dto.ICloudContactDto
import com.wearbubbles.relay.PhoneRelayClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ProfileSyncTest {

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
}
