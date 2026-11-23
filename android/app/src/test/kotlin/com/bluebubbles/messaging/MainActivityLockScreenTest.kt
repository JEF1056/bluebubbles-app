package com.bluebubbles.messaging

import android.os.Build
import android.view.WindowManager
import com.bluebubbles.messaging.services.telecom.FaceTimeConnectionService
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MainActivityLockScreenTest {

    @Test
    fun `shouldShowOverLockScreenForIncomingCall allows active incoming FaceTime intents only`() {
        // Explicit incoming FaceTime extra
        assertTrue(
            LockScreenCallPolicy.shouldShowOverLockScreenForIncomingCall(
                intentType = "OpenSummary",
                hasIncomingFaceTimeExtra = true,
                incomingFaceTimeExtra = true,
                callUuid = "ft-call-1",
                answerExtra = false,
                launchedFromHistory = false,
                isCallPendingEnded = false
            )
        )
        // Legacy/Watch AnswerFaceTime without explicit extra
        assertTrue(
            LockScreenCallPolicy.shouldShowOverLockScreenForIncomingCall(
                intentType = "AnswerFaceTime",
                hasIncomingFaceTimeExtra = false,
                incomingFaceTimeExtra = false,
                callUuid = "ft-call-2",
                answerExtra = true,
                launchedFromHistory = false,
                isCallPendingEnded = false
            )
        )
        // Normal launcher / no extras
        assertFalse(
            LockScreenCallPolicy.shouldShowOverLockScreenForIncomingCall(
                intentType = null,
                hasIncomingFaceTimeExtra = false,
                incomingFaceTimeExtra = false,
                callUuid = null,
                answerExtra = false,
                launchedFromHistory = false,
                isCallPendingEnded = false
            )
        )
        // Message notification summary uses type OpenSummary without callUuid
        assertFalse(
            LockScreenCallPolicy.shouldShowOverLockScreenForIncomingCall(
                intentType = "OpenSummary",
                hasIncomingFaceTimeExtra = false,
                incomingFaceTimeExtra = false,
                callUuid = null,
                answerExtra = false,
                launchedFromHistory = false,
                isCallPendingEnded = false
            )
        )
        // Ongoing foreground-service notification uses OpenCall
        assertFalse(
            LockScreenCallPolicy.shouldShowOverLockScreenForIncomingCall(
                intentType = "OpenCall",
                hasIncomingFaceTimeExtra = false,
                incomingFaceTimeExtra = false,
                callUuid = "ft-call-3",
                answerExtra = false,
                launchedFromHistory = false,
                isCallPendingEnded = false
            )
        )
        // Explicit ongoing FaceTime update sets incomingFaceTimeExtra = false
        assertFalse(
            LockScreenCallPolicy.shouldShowOverLockScreenForIncomingCall(
                intentType = "OpenSummary",
                hasIncomingFaceTimeExtra = true,
                incomingFaceTimeExtra = false,
                callUuid = "ft-call-4",
                answerExtra = false,
                launchedFromHistory = false,
                isCallPendingEnded = false
            )
        )
        // Relaunched from Recents must never bypass lock screen
        assertFalse(
            LockScreenCallPolicy.shouldShowOverLockScreenForIncomingCall(
                intentType = "AnswerFaceTime",
                hasIncomingFaceTimeExtra = true,
                incomingFaceTimeExtra = true,
                callUuid = "ft-call-5",
                answerExtra = true,
                launchedFromHistory = true,
                isCallPendingEnded = false
            )
        )
        // Already ended call must not show over lock screen
        assertFalse(
            LockScreenCallPolicy.shouldShowOverLockScreenForIncomingCall(
                intentType = "AnswerFaceTime",
                hasIncomingFaceTimeExtra = true,
                incomingFaceTimeExtra = true,
                callUuid = "ft-call-6",
                answerExtra = true,
                launchedFromHistory = false,
                isCallPendingEnded = true
            )
        )
    }

    @Test
    fun `shouldShowOverLockScreenForIncomingCall respects FaceTimeConnectionService pending ended state`() {
        val callUuid = "lockscreen-ended-uuid"
        assertFalse(FaceTimeConnectionService.endCall(callUuid, onlyIfRinging = false, recordIfPending = true))
        assertTrue(FaceTimeConnectionService.isCallPendingEnded(callUuid))
        assertFalse(
            LockScreenCallPolicy.shouldShowOverLockScreenForIncomingCall(
                intentType = "AnswerFaceTime",
                hasIncomingFaceTimeExtra = true,
                incomingFaceTimeExtra = true,
                callUuid = callUuid,
                answerExtra = true,
                launchedFromHistory = false
            )
        )
    }

    @Test
    @Suppress("DEPRECATION")
    fun `applyLockScreenFlags sets and explicitly clears both Activity and Window flags`() {
        val expectedLegacyFlags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
            WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON

        var showWhenLocked: Boolean? = null
        var turnScreenOn: Boolean? = null
        var addedFlags = 0
        var clearedFlags = 0

        // API 27+ enable
        LockScreenCallPolicy.applyLockScreenFlags(
            sdkInt = Build.VERSION_CODES.O_MR1,
            enabled = true,
            setShowWhenLocked = { showWhenLocked = it },
            setTurnScreenOn = { turnScreenOn = it },
            addWindowFlags = { addedFlags = addedFlags or it },
            clearWindowFlags = { clearedFlags = clearedFlags or it }
        )
        assertEquals(true, showWhenLocked)
        assertEquals(true, turnScreenOn)
        assertEquals(0, addedFlags)
        assertEquals(0, clearedFlags)

        // API 27+ explicit clear
        LockScreenCallPolicy.applyLockScreenFlags(
            sdkInt = Build.VERSION_CODES.O_MR1,
            enabled = false,
            setShowWhenLocked = { showWhenLocked = it },
            setTurnScreenOn = { turnScreenOn = it },
            addWindowFlags = { addedFlags = addedFlags or it },
            clearWindowFlags = { clearedFlags = clearedFlags or it }
        )
        assertEquals(false, showWhenLocked)
        assertEquals(false, turnScreenOn)
        assertEquals(expectedLegacyFlags, clearedFlags)

        // API 26 enable and clear
        showWhenLocked = null
        turnScreenOn = null
        addedFlags = 0
        clearedFlags = 0
        LockScreenCallPolicy.applyLockScreenFlags(
            sdkInt = Build.VERSION_CODES.O,
            enabled = true,
            setShowWhenLocked = { showWhenLocked = it },
            setTurnScreenOn = { turnScreenOn = it },
            addWindowFlags = { addedFlags = addedFlags or it },
            clearWindowFlags = { clearedFlags = clearedFlags or it }
        )
        assertEquals(null, showWhenLocked)
        assertEquals(null, turnScreenOn)
        assertEquals(expectedLegacyFlags, addedFlags)

        LockScreenCallPolicy.applyLockScreenFlags(
            sdkInt = Build.VERSION_CODES.O,
            enabled = false,
            setShowWhenLocked = { showWhenLocked = it },
            setTurnScreenOn = { turnScreenOn = it },
            addWindowFlags = { addedFlags = addedFlags or it },
            clearWindowFlags = { clearedFlags = clearedFlags or it }
        )
        assertEquals(expectedLegacyFlags, clearedFlags)
    }

    @Test
    fun `dismissIncomingFaceTimeNotification cancels by callUuid even when notificationId is 0`() {
        var stoppedUuid: String? = null
        var cancelledUuid: String? = null
        var cancelledId: Int? = null

        LockScreenCallPolicy.dismissIncomingFaceTimeNotification(
            intentType = "AnswerFaceTime",
            answerExtra = true,
            callUuid = "ft-answer-1",
            notificationId = 0,
            stopRing = { stoppedUuid = it },
            cancelByCallUuid = { cancelledUuid = it },
            cancelByNotificationId = { cancelledId = it }
        )

        assertEquals("ft-answer-1", stoppedUuid)
        assertEquals("ft-answer-1", cancelledUuid)
        assertEquals(null, cancelledId)
    }
}
