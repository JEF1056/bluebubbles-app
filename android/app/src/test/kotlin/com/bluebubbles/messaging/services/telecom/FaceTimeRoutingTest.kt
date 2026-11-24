package com.bluebubbles.messaging.services.telecom

import android.telecom.Connection
import android.telecom.PhoneAccount
import com.bluebubbles.messaging.services.network.HttpService
import com.bluebubbles.messaging.services.notifications.CreateIncomingFaceTimeNotification
import com.bluebubbles.messaging.services.wear.WearSyncManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
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
    fun `car mode routes video incoming directly to telecom when phone account is enabled`() {
        val route = FaceTimeRoutingPolicy.resolveIncomingRoute(
            isVideo = true,
            callUuid = "call-car-video-1",
            phoneAccountEnabled = true,
            inCar = true
        )
        assertEquals(IncomingFaceTimeRoute.TELECOM_DIRECT, route)
    }

    @Test
    fun `car mode video incoming falls back to notification when phone account is disabled`() {
        val route = FaceTimeRoutingPolicy.resolveIncomingRoute(
            isVideo = true,
            callUuid = "call-car-video-2",
            phoneAccountEnabled = false,
            inCar = true
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

    @Test
    fun `telephony incoming routes to telecom when enabled and enable-account notification when disabled`() {
        assertEquals(
            IncomingFaceTimeRoute.TELECOM_DIRECT,
            FaceTimeRoutingPolicy.resolveIncomingRoute(
                isVideo = false,
                callUuid = "cell-1",
                phoneAccountEnabled = true,
                isTelephony = true
            )
        )
        assertEquals(
            IncomingFaceTimeRoute.NOTIFICATION_ENABLE_ACCOUNT,
            FaceTimeRoutingPolicy.resolveIncomingRoute(
                isVideo = false,
                callUuid = "cell-1",
                phoneAccountEnabled = false,
                isTelephony = true
            )
        )
    }

    @Test
    fun `notification actions omit facetime link for disabled telephony and offer enable calling for audio`() {
        assertEquals(
            listOf(IncomingNotificationAction.ENABLE_CALLING, IncomingNotificationAction.DECLINE),
            FaceTimeRoutingPolicy.buildIncomingNotificationActions(
                isVideo = false,
                callUuid = "cell-1",
                phoneAccountEnabled = false,
                isTelephony = true
            )
        )
        assertEquals(
            listOf(
                IncomingNotificationAction.ENABLE_CALLING,
                IncomingNotificationAction.ANSWER_LINK,
                IncomingNotificationAction.DECLINE
            ),
            FaceTimeRoutingPolicy.buildIncomingNotificationActions(
                isVideo = false,
                callUuid = "ft-audio-1",
                phoneAccountEnabled = false,
                isTelephony = false
            )
        )
        assertEquals(
            listOf(
                IncomingNotificationAction.ANSWER_VIDEO,
                IncomingNotificationAction.ANSWER_AUDIO,
                IncomingNotificationAction.DECLINE
            ),
            FaceTimeRoutingPolicy.buildIncomingNotificationActions(
                isVideo = true,
                callUuid = "ft-video-1",
                phoneAccountEnabled = true,
                isTelephony = false
            )
        )
    }

    @Test
    fun `telephony handle scheme forces tel even for email-like handles`() {
        assertEquals("tel", FaceTimeRoutingPolicy.resolveHandleScheme("alice@icloud.com", isTelephony = true))
        assertEquals("mailto", FaceTimeRoutingPolicy.resolveHandleScheme("alice@icloud.com", isTelephony = false))
    }

    @Test
    fun `onlyIfRinging ends ringing connections but preserves active local calls`() {
        assertTrue(FaceTimeConnectionService.shouldEndCallForState(Connection.STATE_RINGING, onlyIfRinging = true))
        assertFalse(FaceTimeConnectionService.shouldEndCallForState(Connection.STATE_ACTIVE, onlyIfRinging = true))
        assertFalse(FaceTimeConnectionService.shouldEndCallForState(Connection.STATE_HOLDING, onlyIfRinging = true))
        assertTrue(FaceTimeConnectionService.shouldEndCallForState(Connection.STATE_ACTIVE, onlyIfRinging = false))
    }

    @Test
    fun `dtmf normalization accepts 0-9 star hash A-D and rejects invalid input`() {
        assertEquals("5", FaceTimeConnection.normalizeDtmfDigit('5'))
        assertEquals("*", FaceTimeConnection.normalizeDtmfDigit('*'))
        assertEquals("#", FaceTimeConnection.normalizeDtmfDigit('#'))
        assertEquals("A", FaceTimeConnection.normalizeDtmfDigit('a'))
        assertNull(FaceTimeConnection.normalizeDtmfDigit('E'))
        assertNull(FaceTimeConnection.normalizeDtmfDigit('x'))

        assertEquals("9", HttpService.normalizeDtmfDigit("9"))
        assertEquals("D", HttpService.normalizeDtmfDigit(" d "))
        assertNull(HttpService.normalizeDtmfDigit("12"))
        assertNull(HttpService.normalizeDtmfDigit(""))
    }

    @Test
    fun `pending outgoing answer and end events replay and respect state guards`() {
        FaceTimeConnectionService.markCallActive("prebind-ans-1", recordIfPending = true)
        assertFalse(FaceTimeConnectionService.shouldEndCallForState(Connection.STATE_DIALING, onlyIfRinging = true))
        assertTrue(FaceTimeConnectionService.shouldEndCallForState(Connection.STATE_DIALING, onlyIfRinging = false))

        FaceTimeConnectionService.endCall("prebind-end-1", onlyIfRinging = false, recordIfPending = true)
        assertEquals("tel", FaceTimeRoutingPolicy.resolveHandleScheme("alice@icloud.com", isTelephony = true))
        assertEquals("mailto", FaceTimeRoutingPolicy.resolveHandleScheme("+15551234567".let { "alice@icloud.com" }, isTelephony = false))
    }

    @Test
    fun `wear call uuid uses explicit uuid when present and falls back to caller hash`() {
        assertEquals("call-uuid-1", CreateIncomingFaceTimeNotification.resolveWearCallUuid("call-uuid-1", "Alice"))
        assertEquals("ft_${"Alice".hashCode()}", CreateIncomingFaceTimeNotification.resolveWearCallUuid(null, "Alice"))
        assertEquals("ft_${"Alice".hashCode()}", CreateIncomingFaceTimeNotification.resolveWearCallUuid("   ", "Alice"))
    }

    @Test
    fun `incoming facetime notification timeout is 60s only when not ongoing`() {
        assertEquals(60_000L, CreateIncomingFaceTimeNotification.resolveNotificationTimeoutMs(isOngoing = false))
        assertNull(CreateIncomingFaceTimeNotification.resolveNotificationTimeoutMs(isOngoing = true))
    }

    @Test
    fun `bounded uuid set evicts oldest entry via lru instead of wholesale clear`() {
        val set = BoundedUuidSet(maxSize = 32)
        for (i in 1..32) {
            set.add("uuid-$i")
        }
        assertEquals(32, set.size())
        // Touch uuid-1 to make it MRU so uuid-2 becomes oldest
        set.add("uuid-1")
        set.add("uuid-33")
        assertEquals(32, set.size())
        assertTrue(set.contains("uuid-1"))
        assertFalse(set.contains("uuid-2"))
        assertTrue(set.contains("uuid-33"))
    }

    @Test
    fun `incoming call uuid dedupe suppresses duplicate fast-path and dart notifications`() {
        CreateIncomingFaceTimeNotification.clearSeenIncomingCallsForTest()
        assertTrue(CreateIncomingFaceTimeNotification.markIncomingCallSeen("call-dedupe-1"))
        assertFalse(CreateIncomingFaceTimeNotification.markIncomingCallSeen("call-dedupe-1"))
        assertTrue(CreateIncomingFaceTimeNotification.markIncomingCallSeen("call-dedupe-2"))
        CreateIncomingFaceTimeNotification.clearSeenIncomingCallsForTest()
    }

    @Test
    fun `phone account uses self-managed capability without call provider flag`() {
        val caps = FaceTimeConnectionService.phoneAccountCapabilities()
        assertTrue((caps and PhoneAccount.CAPABILITY_SELF_MANAGED) != 0)
        assertEquals(0, caps and PhoneAccount.CAPABILITY_CALL_PROVIDER)
    }

    @Test
    fun `watch audio matcher selects wear node or bonded watch bluetooth device`() {
        val buds = FaceTimeConnection.Companion.WatchAudioCandidate("buds", name = "Pixel Buds Pro", address = "11:22:33:44:55:66")
        val watch = FaceTimeConnection.Companion.WatchAudioCandidate("watch5", name = "Google Pixel Watch 5", address = "AA:BB:CC:DD:EE:FF")
        val speaker = FaceTimeConnection.Companion.WatchAudioCandidate("spk", name = "Speaker", address = null, isBluetooth = false)

        // Matches Wear node display name
        assertEquals(
            "watch5",
            FaceTimeConnection.selectWatchAudioCandidate(
                candidates = listOf(buds, watch, speaker),
                watchNodeNames = setOf("Google Pixel Watch 5")
            )
        )

        // Matches bonded watch BT address when endpoint/device name differs
        val unnamedWatch = FaceTimeConnection.Companion.WatchAudioCandidate("watch-addr", name = "BT Headset", address = "aa:bb:cc:dd:ee:ff")
        assertEquals(
            "watch-addr",
            FaceTimeConnection.selectWatchAudioCandidate(
                candidates = listOf(buds, unnamedWatch),
                watchNodeNames = emptySet(),
                bondedWatchAddresses = setOf("AA:BB:CC:DD:EE:FF")
            )
        )

        // Falls back to "watch" name heuristic, ignoring non-watch earbuds
        assertEquals(
            "watch5",
            FaceTimeConnection.selectWatchAudioCandidate(
                candidates = listOf(buds, watch),
                watchNodeNames = emptySet()
            )
        )
        assertNull(
            FaceTimeConnection.selectWatchAudioCandidate(
                candidates = listOf(buds, speaker),
                watchNodeNames = emptySet()
            )
        )
    }

    @Test
    fun `webrtc offer payload includes uplinkVideo when wantVideo is true and falls back cleanly when local camera unavailable`() {
        val withUplink = WebRtcAudioClient.buildOfferPayloadMap(
            callUuid = "call-1",
            sdp = "v=0",
            wantVideo = true,
            hasLocalVideo = true,
            answerCall = false
        )
        assertEquals("call-1", withUplink["callUuid"])
        assertEquals("v=0", withUplink["sdp"])
        assertEquals("offer", withUplink["type"])
        assertEquals(true, withUplink["video"])
        assertEquals(true, withUplink["uplinkVideo"])
        assertFalse(withUplink.containsKey("answerCall"))

        val downlinkOnly = WebRtcAudioClient.buildOfferPayloadMap(
            callUuid = "call-2",
            sdp = "v=0",
            wantVideo = true,
            hasLocalVideo = false,
            answerCall = true
        )
        assertEquals(true, downlinkOnly["video"])
        assertEquals(false, downlinkOnly["uplinkVideo"])
        assertEquals(true, downlinkOnly["answerCall"])

        val audioOnly = WebRtcAudioClient.buildOfferPayloadMap(
            callUuid = "call-3",
            sdp = "v=0",
            wantVideo = false,
            hasLocalVideo = false,
            answerCall = false
        )
        assertFalse(audioOnly.containsKey("video"))
        assertFalse(audioOnly.containsKey("uplinkVideo"))
    }

    @Test
    fun `webrtc camera state payload encodes callUuid and enabled flag`() {
        val disabled = WebRtcAudioClient.buildCameraStatePayloadMap("call-cam-1", false)
        assertEquals("call-cam-1", disabled["callUuid"])
        assertEquals(false, disabled["enabled"])

        val enabled = WebRtcAudioClient.buildCameraStatePayloadMap("call-cam-1", true)
        assertEquals(true, enabled["enabled"])
    }

    @Test
    fun `facetime local video and camera controls return null or false without active connection`() {
        assertNull(FaceTimeConnectionService.getCallLocalVideoTextureId("missing-call"))
        assertFalse(FaceTimeConnectionService.setCallCameraEnabled("missing-call", true))
        assertFalse(FaceTimeConnectionService.flipCallCamera("missing-call"))
        assertEquals("get-facetime-local-video-texture", GetFaceTimeLocalVideoTextureHandler.tag)
        assertEquals("set-facetime-camera-enabled", SetFaceTimeCameraEnabledHandler.tag)
        assertEquals("flip-facetime-camera", FlipFaceTimeCameraHandler.tag)
    }

    @Test
    fun `emitCallState payload includes is_video and non-blank caller_name`() {
        val videoPayload = FaceTimeConnection.buildCallStatePayload(
            phase = "active",
            uuid = "ft-video-9",
            isTelephony = false,
            isVideo = true,
            callerName = "Dana"
        )
        assertEquals("active", videoPayload["phase"])
        assertEquals("ft-video-9", videoPayload["call_uuid"])
        assertEquals(false, videoPayload["is_telephony"])
        assertEquals(true, videoPayload["is_video"])
        assertEquals("Dana", videoPayload["caller_name"])

        val telephonyPayload = FaceTimeConnection.buildCallStatePayload(
            phase = "active",
            uuid = "cell-9",
            isTelephony = true,
            isVideo = true,
            callerName = "   "
        )
        assertEquals(false, telephonyPayload["is_video"])
        assertFalse(telephonyPayload.containsKey("caller_name"))
    }

    @Test
    fun `isCallPendingEnded tracks pending ended state correctly`() {
        val callUuid = "test-pending-ended-routing-uuid"
        assertFalse(FaceTimeConnectionService.isCallPendingEnded(callUuid))
        FaceTimeConnectionService.endCall(callUuid, onlyIfRinging = false, recordIfPending = true)
        assertTrue(FaceTimeConnectionService.isCallPendingEnded(callUuid))
    }

    @Test
    fun `hasActiveCall returns false when no active connections`() {
        assertFalse(FaceTimeConnectionService.hasActiveCall())
    }

    @Test
    fun `watchAnsweredCalls tracks and rolls back call registration`() {
        val uuid = "watch-answer-rollback-uuid"
        WearSyncManager.markWatchAnsweredCall(uuid)
        assertTrue(WearSyncManager.isWatchAnsweredCall(uuid))
        WearSyncManager.clearWatchAnsweredCall(uuid)
        assertFalse(WearSyncManager.isWatchAnsweredCall(uuid))
    }
}
