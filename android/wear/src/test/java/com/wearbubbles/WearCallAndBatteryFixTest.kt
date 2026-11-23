package com.wearbubbles

import com.wearbubbles.notifications.ActiveCallState
import com.wearbubbles.notifications.CallForegroundService
import com.wearbubbles.notifications.CallNotificationHelper
import com.wearbubbles.notifications.CallPhase
import com.wearbubbles.socket.SocketManager
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WearCallAndBatteryFixTest {

    @After
    fun tearDown() {
        CallNotificationHelper.cancelRingTimeout()
        CallNotificationHelper.cancelOngoingTimeout()
        CallNotificationHelper.setActiveCallStateForTest(null)
        CallNotificationHelper.clearRecentlyEndedForTest()
        CallForegroundService.isForegroundStarted = false
    }

    @Test
    fun `answerCallAudio aborts when endCall runs while answer RPC is in flight`() = runBlocking {
        val ringing = ActiveCallState(
            callUuid = "call-race-1",
            callerName = "Alice",
            callerAddress = "+15551234567",
            isVideo = false,
            fromPhoneRelay = true,
            phase = CallPhase.RINGING
        )
        CallNotificationHelper.setActiveCallStateForTest(ringing)
        val epochBefore = CallNotificationHelper.currentCallEpochForTest()

        val rpcStarted = CompletableDeferred<Unit>()
        val allowRpcFinish = CompletableDeferred<Unit>()

        val answerJob = launch {
            val result = CallNotificationHelper.answerCallAudio(
                context = null,
                callUuid = "call-race-1",
                relayAnswer = {
                    rpcStarted.complete(Unit)
                    allowRpcFinish.await()
                    true
                },
                nowElapsedMs = 5_000L
            )
            assertFalse(result)
        }

        rpcStarted.await()
        CallNotificationHelper.endCall(context = null, callUuid = "call-race-1")
        assertTrue(CallNotificationHelper.currentCallEpochForTest() > epochBefore)
        assertNull(CallNotificationHelper.activeCallState.value)

        allowRpcFinish.complete(Unit)
        answerJob.join()

        // Must stay null rather than resurrecting the ended call as ONGOING.
        assertNull(CallNotificationHelper.activeCallState.value)
    }

    @Test
    fun `answerCallAudio aborts when superseded by a newer call UUID while in flight`() = runBlocking {
        val firstCall = ActiveCallState(
            callUuid = "call-old",
            callerName = "Alice",
            callerAddress = "+15551111111",
            isVideo = false,
            fromPhoneRelay = true,
            phase = CallPhase.RINGING
        )
        CallNotificationHelper.setActiveCallStateForTest(firstCall)

        val rpcStarted = CompletableDeferred<Unit>()
        val allowRpcFinish = CompletableDeferred<Unit>()

        val answerJob = launch {
            val result = CallNotificationHelper.answerCallAudio(
                context = null,
                callUuid = "call-old",
                relayAnswer = {
                    rpcStarted.complete(Unit)
                    allowRpcFinish.await()
                    true
                },
                nowElapsedMs = 6_000L
            )
            assertFalse(result)
        }

        rpcStarted.await()
        val newerCall = firstCall.copy(callUuid = "call-new", callerName = "Bob")
        CallNotificationHelper.setActiveCallStateForTest(newerCall)

        allowRpcFinish.complete(Unit)
        answerJob.join()

        assertEquals(newerCall, CallNotificationHelper.activeCallState.value)

        // Also aborts up front if a different call UUID is already active.
        var rpcInvoked = false
        assertFalse(
            CallNotificationHelper.answerCallAudio(
                context = null,
                callUuid = "call-old",
                relayAnswer = {
                    rpcInvoked = true
                    true
                },
                nowElapsedMs = 7_000L
            )
        )
        assertFalse(rpcInvoked)
    }

    @Test
    fun `answerCallAudio commits ONGOING state when call epoch and UUID remain unchanged`() = runBlocking {
        val ringing = ActiveCallState(
            callUuid = "call-ok",
            callerName = "Alice",
            callerAddress = "+15551234567",
            isVideo = false,
            fromPhoneRelay = true,
            phase = CallPhase.RINGING
        )
        CallNotificationHelper.setActiveCallStateForTest(ringing)

        val ok = CallNotificationHelper.answerCallAudio(
            context = null,
            callUuid = "call-ok",
            relayAnswer = { true },
            nowElapsedMs = 12_345L
        )
        assertTrue(ok)
        val active = CallNotificationHelper.activeCallState.value
        assertNotNull(active)
        assertEquals("call-ok", active!!.callUuid)
        assertEquals(CallPhase.ONGOING, active.phase)
        assertEquals(12_345L, active.startedAtElapsedMs)
    }

    @Test
    fun `CallForegroundService resolveOngoingState enforces ONGOING phase and matching UUID`() {
        val ongoing = ActiveCallState(
            callUuid = "call-fgs-1",
            callerName = "Alice",
            callerAddress = "+15551234567",
            isVideo = false,
            fromPhoneRelay = true,
            phase = CallPhase.ONGOING
        )
        val ringing = ongoing.copy(phase = CallPhase.RINGING)

        assertNull(CallForegroundService.resolveOngoingState(null, "call-fgs-1"))
        assertNull(CallForegroundService.resolveOngoingState(ringing, "call-fgs-1"))
        assertNull(CallForegroundService.resolveOngoingState(ongoing, "call-other"))
        assertEquals(ongoing, CallForegroundService.resolveOngoingState(ongoing, "call-fgs-1"))
        assertEquals(ongoing, CallForegroundService.resolveOngoingState(ongoing, null))
    }

    @Test
    fun `ongoing-call safety timeout enforces 4h hard cap and cancels cleanly`() = runBlocking {
        assertEquals(4L * 60 * 60 * 1000L, CallNotificationHelper.ONGOING_HARD_CAP_MS)
        assertEquals(2L * 60 * 1000L, CallNotificationHelper.RELAY_DISCONNECT_GRACE_MS)
        assertEquals(6L, CallNotificationHelper.STANDALONE_CALL_TIMEOUT_SECONDS)

        val ongoing = ActiveCallState(
            callUuid = "call-cap-1",
            callerName = "Alice",
            callerAddress = "+1555",
            isVideo = false,
            fromPhoneRelay = false,
            phase = CallPhase.ONGOING
        )
        CallNotificationHelper.setActiveCallStateForTest(ongoing)

        val timedOut = mutableListOf<String>()
        val capJob = CallNotificationHelper.scheduleOngoingTimeout(
            callUuid = "call-cap-1",
            fromPhoneRelay = false,
            isPhoneConnected = null,
            hardCapMs = 30L,
            scope = this
        ) { timedOut.add(it) }
        capJob.join()
        assertEquals(listOf("call-cap-1"), timedOut)

        // Cancelled before hard cap -> does not fire
        val cancelledJob = CallNotificationHelper.scheduleOngoingTimeout(
            callUuid = "call-cap-1",
            fromPhoneRelay = false,
            isPhoneConnected = null,
            hardCapMs = 150L,
            scope = this
        ) { timedOut.add(it) }
        delay(20L)
        CallNotificationHelper.cancelOngoingTimeout()
        cancelledJob.join()
        assertEquals(listOf("call-cap-1"), timedOut)
    }

    @Test
    fun `ongoing-call safety timeout clears relayed calls only after sustained phone disconnect`() = runBlocking {
        val ongoingRelayed = ActiveCallState(
            callUuid = "call-relay-1",
            callerName = "Alice",
            callerAddress = "+1555",
            isVideo = false,
            fromPhoneRelay = true,
            phase = CallPhase.ONGOING
        )
        CallNotificationHelper.setActiveCallStateForTest(ongoingRelayed)

        val phoneConnected = MutableStateFlow(true)
        val timedOut = mutableListOf<String>()
        val job = CallNotificationHelper.scheduleOngoingTimeout(
            callUuid = "call-relay-1",
            fromPhoneRelay = true,
            isPhoneConnected = phoneConnected,
            hardCapMs = 10_000L,
            disconnectGraceMs = 60L,
            scope = this
        ) { timedOut.add(it) }

        // Brief disconnect (< 60ms) followed by reconnect must NOT end the call.
        phoneConnected.value = false
        delay(20L)
        phoneConnected.value = true
        delay(70L)
        assertTrue(timedOut.isEmpty())

        // Sustained disconnect (> 60ms) MUST end the call.
        phoneConnected.value = false
        job.join()
        assertEquals(listOf("call-relay-1"), timedOut)
    }

    @Test
    fun `SocketManager caps reconnection attempts to 10 and clears credentials on disconnect`() {
        assertEquals(10, SocketManager.MAX_RECONNECTION_ATTEMPTS)
        val opts = SocketManager.buildSocketOptions(
            normalizedUrl = "https://bb.example.com",
            password = "secret"
        )
        assertEquals(10, opts.reconnectionAttempts)

        val manager = SocketManager()
        manager.setCredentialsForTest(
            url = "https://bb.example.com",
            password = "secret",
            headers = mapOf("X-Test" to "1")
        )
        assertTrue(manager.hasConfiguredCredentials())

        // Regular disconnect retains credentials for NetworkCallback / onResume reconnect.
        manager.disconnect(clearCredentials = false)
        assertTrue(manager.hasConfiguredCredentials())

        // Reset disconnect clears credentials so reconnectIfConfigured is a no-op.
        manager.disconnect(clearCredentials = true)
        assertFalse(manager.hasConfiguredCredentials())
        manager.reconnectIfConfigured()
        assertFalse(manager.isConnected.value)
    }

    @Test
    fun `shouldIgnoreIncomingCall rejects duplicate incoming event for already ONGOING call`() {
        val ongoing = ActiveCallState(
            callUuid = "call-ongoing-1",
            callerName = "Alice",
            callerAddress = "+15551234567",
            isVideo = false,
            fromPhoneRelay = true,
            phase = CallPhase.ONGOING
        )
        CallNotificationHelper.setActiveCallStateForTest(ongoing)

        assertTrue(CallNotificationHelper.shouldIgnoreIncomingCall("call-ongoing-1"))
        assertFalse(CallNotificationHelper.shouldIgnoreIncomingCall("call-other-2"))

        CallNotificationHelper.setActiveCallStateForTest(ongoing.copy(phase = CallPhase.RINGING))
        assertFalse(CallNotificationHelper.shouldIgnoreIncomingCall("call-ongoing-1"))
    }

    @Test
    fun `endCall tombstones callUuid for 60s so late markOngoingFromPhone and incoming are ignored`() {
        val ongoing = ActiveCallState(
            callUuid = "call-ended-1",
            callerName = "Alice",
            callerAddress = "+15551234567",
            isVideo = false,
            fromPhoneRelay = true,
            phase = CallPhase.ONGOING
        )
        CallNotificationHelper.setActiveCallStateForTest(ongoing)
        CallNotificationHelper.endCall(context = null, callUuid = "call-ended-1")

        assertNull(CallNotificationHelper.activeCallState.value)
        assertTrue(CallNotificationHelper.shouldIgnoreIncomingCall("call-ended-1"))

        // Late call-active from phone must not resurrect the ended call.
        CallNotificationHelper.markOngoingFromPhone(
            context = null,
            callUuid = "call-ended-1",
            startedAtMs = 1_000L,
            muted = false,
            nowElapsedMs = 5_000L
        )
        assertNull(CallNotificationHelper.activeCallState.value)

        // After TTL expires, the UUID is no longer blocked.
        val pastTtl = System.currentTimeMillis() + CallNotificationHelper.RECENTLY_ENDED_TTL_MS + 1L
        assertFalse(CallNotificationHelper.isRecentlyEnded("call-ended-1", nowMs = pastTtl))
    }

    @Test
    fun `CallForegroundService isForegroundStarted flag gates premature stop`() {
        assertFalse(CallForegroundService.isForegroundStarted)
        assertFalse(CallForegroundService.shouldStopService())

        CallForegroundService.isForegroundStarted = true
        assertTrue(CallForegroundService.shouldStopService())
    }

    @Test
    fun `WearCallTonePlayer resolves alert modes and DND policy`() {
        assertEquals(
            com.wearbubbles.notifications.WearAlertMode.RING_AND_VIBRATE,
            com.wearbubbles.notifications.WearCallTonePlayer.resolveAlertMode(
                ringerMode = android.media.AudioManager.RINGER_MODE_NORMAL,
                dndAllows = true
            )
        )
        assertEquals(
            com.wearbubbles.notifications.WearAlertMode.VIBRATE_ONLY,
            com.wearbubbles.notifications.WearCallTonePlayer.resolveAlertMode(
                ringerMode = android.media.AudioManager.RINGER_MODE_VIBRATE,
                dndAllows = true
            )
        )
        assertEquals(
            com.wearbubbles.notifications.WearAlertMode.NONE,
            com.wearbubbles.notifications.WearCallTonePlayer.resolveAlertMode(
                ringerMode = android.media.AudioManager.RINGER_MODE_SILENT,
                dndAllows = true
            )
        )
        assertEquals(
            com.wearbubbles.notifications.WearAlertMode.NONE,
            com.wearbubbles.notifications.WearCallTonePlayer.resolveAlertMode(
                ringerMode = android.media.AudioManager.RINGER_MODE_NORMAL,
                dndAllows = false
            )
        )
        assertTrue(
            com.wearbubbles.notifications.WearCallTonePlayer.shouldAllowByDnd(
                android.app.NotificationManager.INTERRUPTION_FILTER_ALL,
                0,
                0
            )
        )
        assertFalse(
            com.wearbubbles.notifications.WearCallTonePlayer.shouldAllowByDnd(
                android.app.NotificationManager.INTERRUPTION_FILTER_NONE,
                0,
                0
            )
        )
    }
}
