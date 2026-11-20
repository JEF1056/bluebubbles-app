package com.bluebubbles.messaging.services.telecom

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FaceTimeRoutingTest {

    @Test
    fun `audio incoming routes directly to telecom when phone account is enabled`() {
        val route = FaceTimeRoutingPolicy.resolveIncomingRoute(
            isVideo = false,
            callUuid = "call-123",
            phoneAccountEnabled = true
        )
        assertEquals(IncomingFaceTimeRoute.TELECOM_DIRECT, route)
    }

    @Test
    fun `audio incoming falls back to notification when phone account is disabled or uuid missing`() {
        assertEquals(
            IncomingFaceTimeRoute.NOTIFICATION,
            FaceTimeRoutingPolicy.resolveIncomingRoute(
                isVideo = false,
                callUuid = "call-123",
                phoneAccountEnabled = false
            )
        )
        assertEquals(
            IncomingFaceTimeRoute.NOTIFICATION,
            FaceTimeRoutingPolicy.resolveIncomingRoute(
                isVideo = false,
                callUuid = null,
                phoneAccountEnabled = true
            )
        )
        assertEquals(
            IncomingFaceTimeRoute.NOTIFICATION,
            FaceTimeRoutingPolicy.resolveIncomingRoute(
                isVideo = false,
                callUuid = "   ",
                phoneAccountEnabled = true
            )
        )
    }

    @Test
    fun `video incoming uses callstyle notification even when phone account is enabled`() {
        val route = FaceTimeRoutingPolicy.resolveIncomingRoute(
            isVideo = true,
            callUuid = "call-video-1",
            phoneAccountEnabled = true
        )
        assertEquals(IncomingFaceTimeRoute.NOTIFICATION, route)
    }

    @Test
    fun `video callstyle notification exposes answer video, audio auto-answer handoff, and decline`() {
        val actions = FaceTimeRoutingPolicy.buildVideoNotificationActions("call-video-1")
        assertTrue(actions.hasAnswerVideo)
        assertTrue(actions.hasAudioHandoff)
        assertTrue(actions.hasDecline)
        assertTrue(actions.audioHandoffAutoAnswer)

        val noUuidActions = FaceTimeRoutingPolicy.buildVideoNotificationActions(null)
        assertTrue(noUuidActions.hasAnswerVideo)
        assertFalse(noUuidActions.hasAudioHandoff)
        assertTrue(noUuidActions.hasDecline)
        assertFalse(noUuidActions.audioHandoffAutoAnswer)
    }

    @Test
    fun `decline triggers server decline only when callUuid is present`() {
        assertTrue(FaceTimeRoutingPolicy.shouldTriggerServerDecline("call-123"))
        assertFalse(FaceTimeRoutingPolicy.shouldTriggerServerDecline(null))
        assertFalse(FaceTimeRoutingPolicy.shouldTriggerServerDecline(""))
    }

    @Test
    fun `handle scheme selects mailto for emails and tel for phone numbers`() {
        assertEquals("mailto", FaceTimeRoutingPolicy.resolveHandleScheme("alice@icloud.com"))
        assertEquals("tel", FaceTimeRoutingPolicy.resolveHandleScheme("+15551234567"))
    }

    @Test
    fun `outgoing call pre-uuid cancel leaves call and skips bind and audio bridge`() {
        var failed: String? = null
        var bound: String? = null
        var unregistered: String? = null
        var left: String? = null
        var activated = false

        FaceTimeConnectionService.handleOutgoingCallSuccess(
            uuid = "ft-uuid-1",
            isEnded = { true },
            failOutgoing = { failed = it },
            bindCallUuid = { bound = it },
            unregisterActive = { unregistered = it },
            leaveCall = { left = it },
            activateAndStart = { activated = true }
        )

        assertEquals(null, failed)
        assertEquals(null, bound)
        assertEquals("ft-uuid-1", unregistered)
        assertEquals("ft-uuid-1", left)
        assertFalse(activated)
    }

    @Test
    fun `outgoing call cancel racing with bind unregisters and leaves without activating`() {
        var ended = false
        var bound: String? = null
        var unregistered: String? = null
        var left: String? = null
        var activated = false

        FaceTimeConnectionService.handleOutgoingCallSuccess(
            uuid = "ft-uuid-2",
            isEnded = { ended },
            failOutgoing = {},
            bindCallUuid = {
                bound = it
                ended = true
            },
            unregisterActive = { unregistered = it },
            leaveCall = { left = it },
            activateAndStart = { activated = true }
        )

        assertEquals("ft-uuid-2", bound)
        assertEquals("ft-uuid-2", unregistered)
        assertEquals("ft-uuid-2", left)
        assertFalse(activated)
    }

    @Test
    fun `outgoing call normal success binds and activates without leaving`() {
        var bound: String? = null
        var left: String? = null
        var activated = false

        FaceTimeConnectionService.handleOutgoingCallSuccess(
            uuid = "ft-uuid-3",
            isEnded = { false },
            failOutgoing = {},
            bindCallUuid = { bound = it },
            unregisterActive = {},
            leaveCall = { left = it },
            activateAndStart = { activated = true }
        )

        assertEquals("ft-uuid-3", bound)
        assertEquals(null, left)
        assertTrue(activated)
    }
}
