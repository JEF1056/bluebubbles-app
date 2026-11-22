package com.wearbubbles

import com.wearbubbles.service.ForegroundSocketSession
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StandaloneSocketPolicyTest {

    @Test
    fun `standalone socket runs only when resumed or in call without phone relay`() {
        assertTrue(
            ForegroundSocketSession.shouldRunStandaloneSocket(
                resumed = true,
                configured = true,
                phoneConnected = false,
                userDisconnected = false,
                callActive = false
            )
        )

        // Active FaceTime call keeps the standalone socket alive even after MainActivity pauses.
        assertTrue(
            ForegroundSocketSession.shouldRunStandaloneSocket(
                resumed = false,
                configured = true,
                phoneConnected = false,
                userDisconnected = false,
                callActive = true
            )
        )

        // Backgrounded with no active call -> off.
        assertFalse(
            ForegroundSocketSession.shouldRunStandaloneSocket(
                resumed = false,
                configured = true,
                phoneConnected = false,
                userDisconnected = false,
                callActive = false
            )
        )
    }

    @Test
    fun `phone relay, unconfigured state, and explicit disconnect force socket off`() {
        // Phone connected -> off even while resumed or in call.
        assertFalse(
            ForegroundSocketSession.shouldRunStandaloneSocket(
                resumed = true,
                configured = true,
                phoneConnected = true,
                userDisconnected = false,
                callActive = false
            )
        )
        assertFalse(
            ForegroundSocketSession.shouldRunStandaloneSocket(
                resumed = false,
                configured = true,
                phoneConnected = true,
                userDisconnected = false,
                callActive = true
            )
        )

        // Unconfigured -> off.
        assertFalse(
            ForegroundSocketSession.shouldRunStandaloneSocket(
                resumed = true,
                configured = false,
                phoneConnected = false,
                userDisconnected = false,
                callActive = true
            )
        )

        // User explicitly disconnected -> off even while resumed or callActive flag set.
        assertFalse(
            ForegroundSocketSession.shouldRunStandaloneSocket(
                resumed = true,
                configured = true,
                phoneConnected = false,
                userDisconnected = true,
                callActive = false
            )
        )
        assertFalse(
            ForegroundSocketSession.shouldRunStandaloneSocket(
                resumed = false,
                configured = true,
                phoneConnected = false,
                userDisconnected = true,
                callActive = true
            )
        )
    }
}
