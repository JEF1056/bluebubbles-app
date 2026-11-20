package com.bluebubbles.messaging.services.wear

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WearProfileSyncTest {

    @Test
    fun `self avatar compression budget stays under 32KB`() {
        assertEquals("/bb/profile", WearSyncManager.PATH_PROFILE)
        assertTrue(WearSyncManager.SELF_AVATAR_MAX_BYTES <= 32_000)
        assertTrue(WearSyncManager.SELF_AVATAR_MAX_DIM <= 160)
    }
}
