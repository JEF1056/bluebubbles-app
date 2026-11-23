package com.bluebubbles.messaging.services.telecom

import org.junit.Assert.assertEquals
import org.junit.Test

class FaceTimeCallForegroundServiceTest {

    @Test
    fun `callKindLabel returns expected labels for telephony, group, video, and audio`() {
        assertEquals("Phone Call", FaceTimeCallForegroundService.callKindLabel(isVideo = false, isTelephony = true, isGroup = false))
        assertEquals("Phone Call", FaceTimeCallForegroundService.callKindLabel(isVideo = true, isTelephony = true, isGroup = true))
        assertEquals("Group FaceTime Video", FaceTimeCallForegroundService.callKindLabel(isVideo = true, isTelephony = false, isGroup = true))
        assertEquals("Group FaceTime Audio", FaceTimeCallForegroundService.callKindLabel(isVideo = false, isTelephony = false, isGroup = true))
        assertEquals("FaceTime Video", FaceTimeCallForegroundService.callKindLabel(isVideo = true, isTelephony = false, isGroup = false))
        assertEquals("FaceTime Audio", FaceTimeCallForegroundService.callKindLabel(isVideo = false, isTelephony = false, isGroup = false))
    }

    @Test
    fun `resolveUpdateAction starts FGS only on first start or call change and notifies in-place otherwise`() {
        assertEquals(
            FaceTimeCallForegroundService.UpdateAction.START_FOREGROUND_SERVICE,
            FaceTimeCallForegroundService.resolveUpdateAction(
                isStarted = false,
                currentForegroundNotificationId = 0,
                targetNotificationId = 101
            )
        )
        assertEquals(
            FaceTimeCallForegroundService.UpdateAction.NOTIFY_EXISTING,
            FaceTimeCallForegroundService.resolveUpdateAction(
                isStarted = true,
                currentForegroundNotificationId = 101,
                targetNotificationId = 101
            )
        )
        assertEquals(
            FaceTimeCallForegroundService.UpdateAction.START_FOREGROUND_SERVICE,
            FaceTimeCallForegroundService.resolveUpdateAction(
                isStarted = true,
                currentForegroundNotificationId = 101,
                targetNotificationId = 202
            )
        )
    }

    @Test
    fun `resolveStopAction preserves service when another call is ongoing and defers stop before startForeground`() {
        assertEquals(
            FaceTimeCallForegroundService.StopAction.REFRESH_REMAINING_CALL,
            FaceTimeCallForegroundService.resolveStopAction(
                hasRemainingOngoingCall = true,
                isStarted = true,
                isStartPending = false
            )
        )
        assertEquals(
            FaceTimeCallForegroundService.StopAction.REFRESH_REMAINING_CALL,
            FaceTimeCallForegroundService.resolveStopAction(
                hasRemainingOngoingCall = true,
                isStarted = false,
                isStartPending = true
            )
        )
        assertEquals(
            FaceTimeCallForegroundService.StopAction.STOP_SERVICE_NOW,
            FaceTimeCallForegroundService.resolveStopAction(
                hasRemainingOngoingCall = false,
                isStarted = true,
                isStartPending = false
            )
        )
        assertEquals(
            FaceTimeCallForegroundService.StopAction.DEFER_STOP_UNTIL_STARTED,
            FaceTimeCallForegroundService.resolveStopAction(
                hasRemainingOngoingCall = false,
                isStarted = false,
                isStartPending = true
            )
        )
        assertEquals(
            FaceTimeCallForegroundService.StopAction.CANCEL_NOTIFICATION_ONLY,
            FaceTimeCallForegroundService.resolveStopAction(
                hasRemainingOngoingCall = false,
                isStarted = false,
                isStartPending = false
            )
        )
    }

    @Test
    fun `ongoing contentIntent includes openCall, audioOnly, isTelephony, and caller`() {
        val strings = mutableMapOf<String, String>()
        val bools = mutableMapOf<String, Boolean>()
        var intentType: String? = null

        FaceTimeCallForegroundService.applyOngoingContentIntentExtras(
            callUuid = "ft-ongoing-1",
            effectiveVideo = false,
            isTelephony = true,
            displayName = "Charlie",
            putString = { k, v -> strings[k] = v },
            putBoolean = { k, v -> bools[k] = v },
            setType = { intentType = it }
        )

        assertEquals("OpenCall", intentType)
        assertEquals("ft-ongoing-1", strings["callUuid"])
        assertEquals("Charlie", strings["caller"])
        assertEquals(true, bools["openCall"])
        assertEquals(true, bools["audioOnly"])
        assertEquals(true, bools["isTelephony"])
    }
}
