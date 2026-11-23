package com.wearbubbles

import com.google.gson.JsonParser
import com.wearbubbles.notifications.ActiveCallState
import com.wearbubbles.notifications.CallNotificationHelper
import com.wearbubbles.notifications.CallPhase
import com.wearbubbles.relay.PhoneRelayClient
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CallLiveActivityTest {

    @After
    fun tearDown() {
        CallNotificationHelper.cancelRingTimeout()
        CallNotificationHelper.setActiveCallStateForTest(null)
    }

    @Test
    fun `call live activity relay paths and mute action constants match contract`() {
        assertEquals("/bb/call-active", PhoneRelayClient.PATH_CALL_ACTIVE)
        assertEquals("/bb/set-call-muted", PhoneRelayClient.PATH_SET_CALL_MUTED)
        assertEquals("com.wearbubbles.ACTION_TOGGLE_MUTE", CallNotificationHelper.ACTION_TOGGLE_MUTE)
    }

    @Test
    fun `parseCallActivePayload handles valid, blank uuid, and missing muted`() {
        val valid = DataLayerListenerService.parseCallActivePayload(
            """{"callUuid":"call-123","startedAtMs":1700000005000,"muted":true}"""
        )
        assertNotNull(valid)
        assertEquals("call-123", valid!!.callUuid)
        assertEquals(1700000005000L, valid.startedAtMs)
        assertTrue(valid.muted)

        val missingMuted = DataLayerListenerService.parseCallActivePayload(
            """{"callUuid":"call-456","startedAtMs":1700000009000}"""
        )
        assertNotNull(missingMuted)
        assertEquals("call-456", missingMuted!!.callUuid)
        assertEquals(1700000009000L, missingMuted.startedAtMs)
        assertFalse(missingMuted.muted)

        assertNull(DataLayerListenerService.parseCallActivePayload("""{"callUuid":"","startedAtMs":123}"""))
        assertNull(DataLayerListenerService.parseCallActivePayload("""{"callUuid":"   ","muted":true}"""))
        assertNull(DataLayerListenerService.parseCallActivePayload("""{"startedAtMs":123}"""))
        assertNull(DataLayerListenerService.parseCallActivePayload("not-json"))
    }

    @Test
    fun `wallClockStart and elapsedStartFromWall preserve elapsed call duration`() {
        val nowElapsed = 50_000L
        val nowWall = 1_700_000_050_000L
        val startedElapsed = 38_000L

        assertEquals(1_700_000_038_000L, CallNotificationHelper.wallClockStart(startedElapsed, nowElapsed, nowWall))
        assertEquals(nowWall, CallNotificationHelper.wallClockStart(0L, nowElapsed, nowWall))
        assertEquals(nowWall, CallNotificationHelper.wallClockStart(60_000L, nowElapsed, nowWall))

        assertEquals(
            38_000L,
            CallNotificationHelper.elapsedStartFromWall(1_700_000_038_000L, nowElapsed, nowWall)
        )
        assertEquals(nowElapsed, CallNotificationHelper.elapsedStartFromWall(0L, nowElapsed, nowWall))
        // Future startedAtMs due to clock skew clamps to nowElapsed instead of negative age.
        assertEquals(
            nowElapsed,
            CallNotificationHelper.elapsedStartFromWall(nowWall + 5_000L, nowElapsed, nowWall)
        )
    }

    @Test
    fun `markOngoingFromPhone transitions RINGING to ONGOING and updates mute state`() {
        val initialRinging = ActiveCallState(
            callUuid = "call-1",
            callerName = "Alice",
            callerAddress = "+15551234567",
            isVideo = true,
            fromPhoneRelay = true,
            phase = CallPhase.RINGING,
            isTelephony = false
        )
        CallNotificationHelper.setActiveCallStateForTest(initialRinging)

        val nowElapsed = 100_000L
        val nowWall = 1_700_000_100_000L
        CallNotificationHelper.markOngoingFromPhone(
            context = null,
            callUuid = "call-1",
            startedAtMs = nowWall - 5_000L,
            muted = false,
            nowElapsedMs = nowElapsed,
            nowWallMs = nowWall
        )

        val ongoing = CallNotificationHelper.activeCallState.value
        assertNotNull(ongoing)
        assertEquals(CallPhase.ONGOING, ongoing!!.phase)
        assertEquals("Alice", ongoing.callerName)
        assertTrue(ongoing.isVideo)
        assertEquals(95_000L, ongoing.startedAtElapsedMs)
        assertFalse(ongoing.muted)

        // Subsequent phone active update toggles muted without resetting elapsed start.
        CallNotificationHelper.markOngoingFromPhone(
            context = null,
            callUuid = "call-1",
            startedAtMs = nowWall,
            muted = true,
            nowElapsedMs = nowElapsed + 10_000L,
            nowWallMs = nowWall + 10_000L
        )
        val mutedState = CallNotificationHelper.activeCallState.value
        assertNotNull(mutedState)
        assertEquals(95_000L, mutedState!!.startedAtElapsedMs)
        assertTrue(mutedState.muted)
        assertEquals("FaceTime Audio • Muted", CallNotificationHelper.ongoingNotificationText(isTelephony = false, muted = true))
        assertEquals("Phone Call • Muted", CallNotificationHelper.ongoingNotificationText(isTelephony = true, muted = true))
        assertEquals("Group FaceTime Video • Ongoing", CallNotificationHelper.ongoingNotificationText(isTelephony = false, muted = false, isVideo = true, isGroup = true))
    }

    @Test
    fun `parseCallActivePayload parses callerName, callerAddress, isVideo, isTelephony, and isGroup`() {
        val payload = DataLayerListenerService.parseCallActivePayload(
            """{"callUuid":"call-789","startedAtMs":1700000010000,"muted":false,"callerName":"Alice + 1","callerAddress":"alice@icloud.com","isVideo":true,"isTelephony":false,"isGroup":true}"""
        )
        assertNotNull(payload)
        assertEquals("call-789", payload!!.callUuid)
        assertEquals("Alice + 1", payload.callerName)
        assertEquals("alice@icloud.com", payload.callerAddress)
        assertTrue(payload.isVideo)
        assertFalse(payload.isTelephony)
        assertTrue(payload.isGroup)
    }

    @Test
    fun `markOngoingFromPhone preserves caller name, address, and call kind from idle`() {
        CallNotificationHelper.setActiveCallStateForTest(null)
        val nowElapsed = 300_000L
        val nowWall = 1_700_000_300_000L

        CallNotificationHelper.markOngoingFromPhone(
            context = null,
            callUuid = "call-group-1",
            startedAtMs = nowWall - 5_000L,
            muted = false,
            callerName = "Team Sync",
            callerAddress = "team@icloud.com",
            isVideo = true,
            isTelephony = false,
            isGroup = true,
            nowElapsedMs = nowElapsed,
            nowWallMs = nowWall
        )

        val state = CallNotificationHelper.activeCallState.value
        assertNotNull(state)
        assertEquals("Team Sync", state!!.callerName)
        assertEquals("team@icloud.com", state.callerAddress)
        assertTrue(state.isVideo)
        assertFalse(state.isTelephony)
        assertTrue(state.isGroup)
        assertEquals(
            "Group FaceTime Video",
            CallNotificationHelper.callKindLabel(state.isVideo, state.isTelephony, state.isGroup)
        )
    }

    @Test
    fun `markOngoingFromPhone creates ONGOING state from idle when call was answered or started on phone`() {
        CallNotificationHelper.setActiveCallStateForTest(null)
        val nowElapsed = 200_000L
        val nowWall = 1_700_000_200_000L

        CallNotificationHelper.markOngoingFromPhone(
            context = null,
            callUuid = "call-idle-1",
            startedAtMs = nowWall - 12_000L,
            muted = true,
            nowElapsedMs = nowElapsed,
            nowWallMs = nowWall
        )

        val state = CallNotificationHelper.activeCallState.value
        assertNotNull(state)
        assertEquals("call-idle-1", state!!.callUuid)
        assertEquals(CallPhase.ONGOING, state.phase)
        assertTrue(state.fromPhoneRelay)
        assertEquals(188_000L, state.startedAtElapsedMs)
        assertTrue(state.muted)
    }

    @Test
    fun `transfer call audio relay constant and JSON payload match phone contract`() {
        assertEquals("/bb/transfer-call-audio", PhoneRelayClient.PATH_TRANSFER_CALL_AUDIO)

        val payloadJson = String(PhoneRelayClient.buildTransferCallAudioPayload("ft-xfer-42"))
        val parsed = JsonParser.parseString(payloadJson).asJsonObject
        assertEquals("ft-xfer-42", parsed.get("callUuid").asString)
        assertEquals("phone", parsed.get("target").asString)
    }

    @Test
    fun `tryTransferCallToPhone validates uuid and relay availability without ending ongoing call`() = runBlocking {
        val ongoing = ActiveCallState(
            callUuid = "ft-xfer-1",
            callerName = "Alice",
            callerAddress = "+15551234567",
            isVideo = false,
            fromPhoneRelay = true,
            phase = CallPhase.ONGOING
        )
        CallNotificationHelper.setActiveCallStateForTest(ongoing)

        var relayedUuid: String? = null
        assertFalse(CallNotificationHelper.tryTransferCallToPhone("", canRelay = true) { relayedUuid = it; true })
        assertNull(relayedUuid)

        assertFalse(CallNotificationHelper.tryTransferCallToPhone("ft-xfer-1", canRelay = false) { relayedUuid = it; true })
        assertNull(relayedUuid)

        assertTrue(CallNotificationHelper.tryTransferCallToPhone("ft-xfer-1", canRelay = true) { relayedUuid = it; true })
        assertEquals("ft-xfer-1", relayedUuid)
        assertEquals(ongoing, CallNotificationHelper.activeCallState.value)
    }

    @Test
    fun `applyCallNotificationFlags sets FLAG_INSISTENT only on incoming ringing notification`() {
        val baseFlags = android.app.Notification.FLAG_NO_CLEAR
        val ringingFlags = CallNotificationHelper.applyCallNotificationFlags(baseFlags, CallPhase.RINGING)
        assertTrue((ringingFlags and android.app.Notification.FLAG_INSISTENT) != 0)
        assertTrue((ringingFlags and android.app.Notification.FLAG_NO_CLEAR) != 0)

        val ongoingFlags = CallNotificationHelper.applyCallNotificationFlags(ringingFlags, CallPhase.ONGOING)
        assertEquals(0, ongoingFlags and android.app.Notification.FLAG_INSISTENT)
        assertTrue((ongoingFlags and android.app.Notification.FLAG_NO_CLEAR) != 0)
    }
}
