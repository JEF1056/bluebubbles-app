package com.bluebubbles.messaging.services.system

import android.content.ActivityNotFoundException
import com.bluebubbles.messaging.Constants
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StartGoogleDuoRequestHandlerTest {

    @Test
    fun `normalizeDialNumber formats phone numbers and rejects emails or blanks`() {
        assertEquals("+15551234567", StartGoogleDuoRequestHandler.normalizeDialNumber("+1 (555) 123-4567"))
        assertEquals("5551234567", StartGoogleDuoRequestHandler.normalizeDialNumber("555-123-4567"))
        assertNull(StartGoogleDuoRequestHandler.normalizeDialNumber("alice@example.com"))
        assertNull(StartGoogleDuoRequestHandler.normalizeDialNumber("   "))
        assertNull(StartGoogleDuoRequestHandler.normalizeDialNumber(null))
    }

    @Test
    fun `buildIntentSpec sets tachyon package, CALL action, tel ssp, video extra, and new-task flag`() {
        val spec = StartGoogleDuoRequestHandler.buildIntentSpec(
            rawNumber = "+1 (555) 123-4567",
            addNewTaskFlag = true,
        )!!
        assertEquals("${Constants.googleDuoPackageName}.action.CALL", spec.action)
        assertEquals(Constants.googleDuoPackageName, spec.packageName)
        assertEquals("tel", spec.dataScheme)
        assertEquals("+15551234567", spec.dataSsp)
        assertEquals("${Constants.googleDuoPackageName}.extra.IS_AUDIO_ONLY", spec.isAudioOnlyExtraKey)
        assertFalse(spec.isAudioOnly)
        assertTrue(spec.addNewTaskFlag)

        val activitySpec = StartGoogleDuoRequestHandler.buildIntentSpec(
            rawNumber = "+15551234567",
            addNewTaskFlag = false,
        )!!
        assertFalse(activitySpec.addNewTaskFlag)
    }

    @Test
    fun `dispatchMeetCall returns true when Meet launches without fallback`() {
        var launchedSpec: MeetCallIntentSpec? = null
        var fallbackUri: String? = null

        val result = StartGoogleDuoRequestHandler.dispatchMeetCall(
            rawNumber = "+1 555-123-4567",
            isActivityContext = false,
            launchMeet = { launchedSpec = it },
            launchPlayStoreFallback = { uri, _ -> fallbackUri = uri },
        )

        assertTrue(result)
        assertEquals("+15551234567", launchedSpec?.dataSsp)
        assertTrue(launchedSpec?.addNewTaskFlag == true)
        assertNull(fallbackUri)
    }

    @Test
    fun `dispatchMeetCall falls back to Play Store market then web URL when Meet is missing`() {
        val fallbackCalls = mutableListOf<Pair<String, Boolean>>()

        val marketResult = StartGoogleDuoRequestHandler.dispatchMeetCall(
            rawNumber = "+15551234567",
            isActivityContext = false,
            launchMeet = { throw ActivityNotFoundException("no meet") },
            launchPlayStoreFallback = { uri, newTask -> fallbackCalls.add(uri to newTask) },
        )

        assertFalse(marketResult)
        assertEquals(
            listOf(StartGoogleDuoRequestHandler.marketFallbackUri to true),
            fallbackCalls,
        )

        fallbackCalls.clear()
        val webResult = StartGoogleDuoRequestHandler.dispatchMeetCall(
            rawNumber = "+15551234567",
            isActivityContext = true,
            launchMeet = { throw ActivityNotFoundException("no meet") },
            launchPlayStoreFallback = { uri, newTask ->
                fallbackCalls.add(uri to newTask)
                if (uri.startsWith("market://")) {
                    throw ActivityNotFoundException("no play store")
                }
            },
        )

        assertFalse(webResult)
        assertEquals(
            listOf(
                StartGoogleDuoRequestHandler.marketFallbackUri to false,
                StartGoogleDuoRequestHandler.webPlayFallbackUri to false,
            ),
            fallbackCalls,
        )
    }

    @Test
    fun `dispatchMeetCall returns false for email address without launching anything`() {
        var meetCalled = false
        var fallbackCalled = false

        val result = StartGoogleDuoRequestHandler.dispatchMeetCall(
            rawNumber = "alice@icloud.com",
            isActivityContext = true,
            launchMeet = { meetCalled = true },
            launchPlayStoreFallback = { _, _ -> fallbackCalled = true },
        )

        assertFalse(result)
        assertFalse(meetCalled)
        assertFalse(fallbackCalled)
    }
}
