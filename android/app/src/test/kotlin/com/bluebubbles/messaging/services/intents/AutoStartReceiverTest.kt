package com.bluebubbles.messaging.services.intents

import android.os.Build
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AutoStartReceiverTest {

    @Test
    fun `startForegroundServiceSafely uses startForeground on Oreo+ and startLegacy below Oreo`() {
        var foregroundCalls = 0
        var legacyCalls = 0

        AutoStartReceiver.startForegroundServiceSafely(
            sdkInt = Build.VERSION_CODES.O,
            startForeground = { foregroundCalls++ },
            startLegacy = { legacyCalls++ },
            logWarning = {},
            logError = { _, _ -> },
        )
        assertEquals(1, foregroundCalls)
        assertEquals(0, legacyCalls)

        AutoStartReceiver.startForegroundServiceSafely(
            sdkInt = Build.VERSION_CODES.N_MR1,
            startForeground = { foregroundCalls++ },
            startLegacy = { legacyCalls++ },
            logWarning = {},
            logError = { _, _ -> },
        )
        assertEquals(1, foregroundCalls)
        assertEquals(1, legacyCalls)
    }

    @Test
    fun `startForegroundServiceSafely catches SecurityException and IllegalStateException without crashing`() {
        val errors = mutableListOf<Pair<String, Exception>>()
        var warned = false

        AutoStartReceiver.startForegroundServiceSafely(
            sdkInt = Build.VERSION_CODES.UPSIDE_DOWN_CAKE,
            startForeground = { throw SecurityException("denied on boot") },
            startLegacy = {},
            logWarning = { warned = true },
            logError = { msg, e -> errors.add(msg to e) },
        )

        AutoStartReceiver.startForegroundServiceSafely(
            sdkInt = Build.VERSION_CODES.UPSIDE_DOWN_CAKE,
            startForeground = { throw IllegalStateException("fgs not allowed") },
            startLegacy = {},
            logWarning = { warned = true },
            logError = { msg, e -> errors.add(msg to e) },
        )

        assertFalse(warned)
        assertEquals(2, errors.size)
        assertTrue(errors[0].second is SecurityException)
        assertTrue(errors[1].second is IllegalStateException)
    }
}
