package com.wearbubbles

import com.wearbubbles.notifications.ActiveCallState
import com.wearbubbles.notifications.CallNotificationHelper
import com.wearbubbles.notifications.CallPhase
import com.wearbubbles.notifications.NotificationHelper
import com.wearbubbles.relay.PhoneRelayClient
import com.wearbubbles.ui.call.ringingCallSubtitle
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationHelperTest {
    @Test
    fun `quick reply choices are populated for Wear RemoteInput`() {
        assertTrue(NotificationHelper.QUICK_REPLY_CHOICES.isNotEmpty())
        assertTrue(NotificationHelper.QUICK_REPLY_CHOICES.all { it.isNotBlank() })
    }

    @Test
    fun `setActiveChat updates activeChatGuid state`() {
        NotificationHelper.setActiveChat("iMessage;-;+15551234567")
        assertEquals("iMessage;-;+15551234567", NotificationHelper.activeChatGuid.value)
        NotificationHelper.setActiveChat(null)
        assertNull(NotificationHelper.activeChatGuid.value)
    }

    @Test
    fun `clearConversationHistory is idempotent for unknown chat`() {
        NotificationHelper.clearConversationHistory("iMessage;-;nonexistent")
        assertTrue(NotificationHelper.ACTION_DISMISS.isNotBlank())
        assertTrue(NotificationHelper.ACTION_MARK_READ.isNotBlank())
    }

    @Test
    fun `buildPersonUri formats phone and email addresses`() {
        assertEquals("tel:+15551234567", NotificationHelper.buildPersonUri("+15551234567"))
        assertEquals("mailto:alice@example.com", NotificationHelper.buildPersonUri("alice@example.com"))
        assertNull(NotificationHelper.buildPersonUri("   "))
        assertNull(NotificationHelper.buildPersonUri(null))
    }

    @Test
    fun `buildPerson uses stable address key and falls back to name`() {
        val withAddr = NotificationHelper.buildPerson(
            name = "Alice",
            address = "+15551234567"
        )
        assertEquals("Alice", withAddr.name)
        assertEquals("+15551234567", withAddr.key)
        assertEquals("tel:+15551234567", withAddr.uri)

        val fallback = NotificationHelper.buildPerson(name = "Bob", address = null)
        assertEquals("Bob", fallback.key)
        assertNull(fallback.uri)
    }

    @Test
    fun `notification grouping and call constants are distinct`() {
        assertEquals("com.wearbubbles.MESSAGES", NotificationHelper.GROUP_KEY_MESSAGES)
        assertEquals("calls", NotificationHelper.CHANNEL_CALLS)
        assertTrue(NotificationHelper.SUMMARY_NOTIFICATION_ID != NotificationHelper.CALL_NOTIFICATION_ID)
        assertTrue(NotificationHelper.SUMMARY_NOTIFICATION_ID != 1001)
        assertTrue(NotificationHelper.CALL_NOTIFICATION_ID != 1001)
    }

    @Test
    fun `call pickup relay paths and receiver actions match contract`() {
        assertEquals("/bb/incoming-call", PhoneRelayClient.PATH_INCOMING_CALL)
        assertEquals("/bb/call-ended", PhoneRelayClient.PATH_CALL_ENDED)
        assertEquals("/bb/answer-call-audio", PhoneRelayClient.PATH_ANSWER_CALL_AUDIO)
        assertEquals("/bb/decline-call", PhoneRelayClient.PATH_DECLINE_CALL)
        assertEquals("/bb/open-chat", PhoneRelayClient.PATH_OPEN_CHAT)

        assertTrue(CallNotificationHelper.ACTION_ANSWER_CALL.isNotBlank())
        assertTrue(CallNotificationHelper.ACTION_DECLINE_CALL.isNotBlank())
        assertTrue(CallNotificationHelper.ACTION_END_CALL.isNotBlank())
        assertEquals(2, CallPhase.entries.size)
    }

    @Test
    fun `shouldMarkChatReadOnIncoming requires active matching chat and non-fromMe`() {
        val chat = "iMessage;-;+15551234567"
        assertTrue(NotificationHelper.shouldMarkChatReadOnIncoming(chat, chat, isFromMe = false))
        assertFalse(NotificationHelper.shouldMarkChatReadOnIncoming(null, chat, isFromMe = false))
        assertFalse(NotificationHelper.shouldMarkChatReadOnIncoming("iMessage;-;+15550000000", chat, isFromMe = false))
        assertFalse(NotificationHelper.shouldMarkChatReadOnIncoming(chat, chat, isFromMe = true))
    }

    @Test
    fun `isAppResumedOrUnbound requires explicit resume and blocks unbound or paused`() {
        NotificationHelper.resetLifecycleForTest()
        try {
            assertFalse(NotificationHelper.isAppResumedOrUnbound())
            NotificationHelper.setAppResumed(false)
            assertFalse(NotificationHelper.isAppResumedOrUnbound())
            NotificationHelper.setAppResumed(true)
            assertTrue(NotificationHelper.isAppResumedOrUnbound())
        } finally {
            NotificationHelper.resetLifecycleForTest()
        }
    }

    @Test
    fun `shouldActivateChat blocks stale chat while another launch target is pending`() {
        val chatA = "iMessage;-;+15551111111"
        val chatB = "iMessage;-;+15552222222"
        NotificationHelper.resetLifecycleForTest()
        try {
            assertFalse(NotificationHelper.shouldActivateChat(chatA))

            NotificationHelper.setAppResumed(true)
            NotificationHelper.setPendingLaunchChatGuid(chatB)
            assertFalse(NotificationHelper.shouldActivateChat(chatA))
            assertTrue(NotificationHelper.shouldActivateChat(chatB))

            NotificationHelper.setAppResumed(false)
            assertFalse(NotificationHelper.shouldActivateChat(chatB))

            NotificationHelper.setAppResumed(true)
            NotificationHelper.setPendingLaunchChatGuid(null)
            assertTrue(NotificationHelper.shouldActivateChat(chatA))
        } finally {
            NotificationHelper.resetLifecycleForTest()
        }
    }

    @Test
    fun `telephony incoming call payload and labels propagate iPhone Call strings`() {
        val telephony = DataLayerListenerService.parseIncomingCallPayload(
            """{"callUuid":"cell-1","callerName":"Mom","callerAddress":"+15551234567","isVideo":true,"isTelephony":true}"""
        )!!
        assertEquals("cell-1", telephony.callUuid)
        assertEquals("Mom", telephony.callerName)
        assertEquals("+15551234567", telephony.callerAddress)
        assertFalse(telephony.isVideo)
        assertTrue(telephony.isTelephony)

        val state = ActiveCallState(
            callUuid = telephony.callUuid,
            callerName = telephony.callerName,
            callerAddress = telephony.callerAddress,
            isVideo = telephony.isVideo,
            fromPhoneRelay = true,
            phase = CallPhase.RINGING,
            isTelephony = telephony.isTelephony
        )
        assertTrue(state.isTelephony)
        assertEquals("Phone Call", ringingCallSubtitle(isVideo = state.isVideo, isTelephony = state.isTelephony))
        assertEquals("Incoming Phone Call", CallNotificationHelper.incomingFallbackNotificationText(isVideo = false, isTelephony = true))
        assertEquals("Phone Call • Ongoing", CallNotificationHelper.ongoingNotificationText(isTelephony = true))

        val facetimeVideo = DataLayerListenerService.parseIncomingCallPayload(
            """{"callUuid":"ft-1","callerName":"Alice","isVideo":true}"""
        )!!
        assertFalse(facetimeVideo.isTelephony)
        assertTrue(facetimeVideo.isVideo)
        assertEquals("FaceTime Video", ringingCallSubtitle(isVideo = true, isTelephony = false))
        assertEquals("FaceTime Audio", ringingCallSubtitle(isVideo = false, isTelephony = false))
        assertEquals("Group FaceTime Video", ringingCallSubtitle(isVideo = true, isTelephony = false, isGroup = true))
        assertEquals("FaceTime Audio • Ongoing", CallNotificationHelper.ongoingNotificationText(isTelephony = false))
    }

    @Test
    fun `ring timeout fires only when call is still ringing and not cancelled`() = runBlocking {
        assertEquals(60_000L, CallNotificationHelper.RING_TIMEOUT_MS)
        val timedOut = mutableListOf<String>()
        try {
            CallNotificationHelper.setActiveCallStateForTest(
                ActiveCallState("call-1", "Alice", "+1555", isVideo = false, fromPhoneRelay = true, phase = CallPhase.RINGING)
            )
            val job = CallNotificationHelper.scheduleRingTimeout("call-1", timeoutMs = 40L, scope = this) {
                timedOut.add(it)
            }
            job.join()
            assertEquals(listOf("call-1"), timedOut)

            // Cancelled before firing (e.g. answered or ended)
            val cancelledJob = CallNotificationHelper.scheduleRingTimeout("call-2", timeoutMs = 80L, scope = this) {
                timedOut.add(it)
            }
            delay(20L)
            CallNotificationHelper.cancelRingTimeout()
            cancelledJob.join()
            assertEquals(listOf("call-1"), timedOut)

            // Phase already ONGOING -> does not fire
            CallNotificationHelper.setActiveCallStateForTest(
                ActiveCallState("call-3", "Bob", "+1555", isVideo = false, fromPhoneRelay = true, phase = CallPhase.ONGOING)
            )
            val ongoingJob = CallNotificationHelper.scheduleRingTimeout("call-3", timeoutMs = 30L, scope = this) {
                timedOut.add(it)
            }
            ongoingJob.join()
            assertEquals(listOf("call-1"), timedOut)
        } finally {
            CallNotificationHelper.cancelRingTimeout()
            CallNotificationHelper.setActiveCallStateForTest(null)
        }
    }

    @Test
    fun `tryAnswerCallAudio skips standalone HTTP for telephony and requires success`() = runBlocking {
        var standaloneCalls = 0
        // Telephony relay failure must not fall back to standalone HTTP
        assertFalse(
            CallNotificationHelper.tryAnswerCallAudio(
                callUuid = "tel-1",
                isTelephony = true,
                relayAnswer = { false },
                standaloneAnswer = { standaloneCalls++; true }
            )
        )
        assertEquals(0, standaloneCalls)

        // FaceTime relay failure falls back to standalone HTTP; false if HTTP also fails
        assertFalse(
            CallNotificationHelper.tryAnswerCallAudio(
                callUuid = "ft-1",
                isTelephony = false,
                relayAnswer = { false },
                standaloneAnswer = { standaloneCalls++; false }
            )
        )
        assertEquals(1, standaloneCalls)

        // FaceTime standalone HTTP success returns true
        assertTrue(
            CallNotificationHelper.tryAnswerCallAudio(
                callUuid = "ft-2",
                isTelephony = false,
                relayAnswer = { false },
                standaloneAnswer = { standaloneCalls++; true }
            )
        )
        assertEquals(2, standaloneCalls)
    }

    @Test
    fun `tryAnswerCallAudio retries relay once and never falls back to standalone when fromPhoneRelay is true`() = runBlocking {
        var relayCalls = 0
        var standaloneCalls = 0
        // Fails first attempt, succeeds on retry
        assertTrue(
            CallNotificationHelper.tryAnswerCallAudio(
                callUuid = "relay-1",
                isTelephony = false,
                fromPhoneRelay = true,
                relayAnswer = {
                    relayCalls++
                    relayCalls == 2
                },
                standaloneAnswer = {
                    standaloneCalls++
                    true
                }
            )
        )
        assertEquals(2, relayCalls)
        assertEquals(0, standaloneCalls)

        // Fails both attempts -> returns false, still never calls standaloneAnswer
        relayCalls = 0
        assertFalse(
            CallNotificationHelper.tryAnswerCallAudio(
                callUuid = "relay-2",
                isTelephony = false,
                fromPhoneRelay = true,
                relayAnswer = {
                    relayCalls++
                    false
                },
                standaloneAnswer = {
                    standaloneCalls++
                    true
                }
            )
        )
        assertEquals(2, relayCalls)
        assertEquals(0, standaloneCalls)
    }

    @Test
    fun `answerCallAudio never falls back to standalone when fromPhoneRelay is true`() = runBlocking {
        val ringing = ActiveCallState(
            callUuid = "relay-call-1",
            callerName = "Alice",
            callerAddress = "+1555",
            isVideo = false,
            fromPhoneRelay = true,
            phase = CallPhase.RINGING
        )
        CallNotificationHelper.setActiveCallStateForTest(ringing)
        try {
            var relayCalls = 0
            var standaloneCalls = 0
            val result = CallNotificationHelper.answerCallAudio(
                context = null,
                callUuid = "relay-call-1",
                relayAnswer = {
                    relayCalls++
                    false
                },
                standaloneAnswer = {
                    standaloneCalls++
                    true
                }
            )
            assertFalse(result)
            assertEquals(2, relayCalls)
            assertEquals(0, standaloneCalls)
            assertEquals(CallPhase.RINGING, CallNotificationHelper.activeCallState.value?.phase)
        } finally {
            CallNotificationHelper.setActiveCallStateForTest(null)
        }
    }

    @Test
    fun `shouldEndCall respects onlyIfRinging for status_id 1 vs 6`() {
        val ringing = ActiveCallState("call-1", "Alice", "+1555", isVideo = false, fromPhoneRelay = false, phase = CallPhase.RINGING)
        val ongoing = ringing.copy(phase = CallPhase.ONGOING)

        // status_id == 1 (onlyIfRinging = true): ends RINGING, preserves ONGOING (answered on this watch)
        assertTrue(CallNotificationHelper.shouldEndCall(ringing, "call-1", onlyIfRinging = true))
        assertFalse(CallNotificationHelper.shouldEndCall(ongoing, "call-1", onlyIfRinging = true))
        assertFalse(CallNotificationHelper.shouldEndCall(null, "call-1", onlyIfRinging = true))

        // status_id == 6 (onlyIfRinging = false): ends both RINGING and ONGOING for matching UUID
        assertTrue(CallNotificationHelper.shouldEndCall(ringing, "call-1", onlyIfRinging = false))
        assertTrue(CallNotificationHelper.shouldEndCall(ongoing, "call-1", onlyIfRinging = false))
        assertFalse(CallNotificationHelper.shouldEndCall(ongoing, "other-uuid", onlyIfRinging = false))
    }

    @Test
    fun `shouldAcceptIncomingCall rejects incoming call when another call is ONGOING`() {
        val ongoing = ActiveCallState("call-1", "Alice", "+1555", isVideo = false, fromPhoneRelay = false, phase = CallPhase.ONGOING)
        val ringing = ActiveCallState("call-1", "Alice", "+1555", isVideo = false, fromPhoneRelay = false, phase = CallPhase.RINGING)

        // Ongoing call exists -> reject new call
        assertFalse(CallNotificationHelper.shouldAcceptIncomingCall(ongoing, "call-2", isRecentlyEnded = false))
        assertFalse(CallNotificationHelper.shouldAcceptIncomingCall(ongoing, "call-1", isRecentlyEnded = false))

        // Ringing call exists -> can accept/update
        assertTrue(CallNotificationHelper.shouldAcceptIncomingCall(ringing, "call-2", isRecentlyEnded = false))

        // No active call -> accept
        assertTrue(CallNotificationHelper.shouldAcceptIncomingCall(null, "call-2", isRecentlyEnded = false))

        // Recently ended -> reject
        assertFalse(CallNotificationHelper.shouldAcceptIncomingCall(null, "call-2", isRecentlyEnded = true))
    }
}
