package com.bluebubbles.messaging.services.telecom

import android.app.NotificationManager
import android.media.AudioManager
import android.telecom.DisconnectCause
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.sqrt

class CallTonePlayerTest {

    @Test
    fun `shouldAllowByDnd allows ALL and UNKNOWN and blocks NONE and ALARMS`() {
        assertTrue(CallTonePlayer.shouldAllowByDnd(NotificationManager.INTERRUPTION_FILTER_ALL, 0, 0))
        assertTrue(CallTonePlayer.shouldAllowByDnd(NotificationManager.INTERRUPTION_FILTER_UNKNOWN, 0, 0))
        assertFalse(CallTonePlayer.shouldAllowByDnd(NotificationManager.INTERRUPTION_FILTER_NONE, 0, 0))
        assertFalse(CallTonePlayer.shouldAllowByDnd(NotificationManager.INTERRUPTION_FILTER_ALARMS, 0, 0))
    }

    @Test
    fun `shouldAllowByDnd in PRIORITY requires calls category and ANY sender`() {
        val callsCategory = NotificationManager.Policy.PRIORITY_CATEGORY_CALLS
        val sendersAny = NotificationManager.Policy.PRIORITY_SENDERS_ANY
        val sendersContacts = NotificationManager.Policy.PRIORITY_SENDERS_CONTACTS

        assertTrue(CallTonePlayer.shouldAllowByDnd(NotificationManager.INTERRUPTION_FILTER_PRIORITY, callsCategory, sendersAny))
        assertFalse(CallTonePlayer.shouldAllowByDnd(NotificationManager.INTERRUPTION_FILTER_PRIORITY, 0, sendersAny))
        assertFalse(CallTonePlayer.shouldAllowByDnd(NotificationManager.INTERRUPTION_FILTER_PRIORITY, callsCategory, sendersContacts))
    }

    @Test
    fun `resolveIncomingAlertMode handles ringer modes, DND, and active call`() {
        assertEquals(
            IncomingAlertMode.NONE,
            CallTonePlayer.resolveIncomingAlertMode(
                ringerMode = AudioManager.RINGER_MODE_NORMAL,
                dndAllows = false,
                vibrateWhenRinging = true,
                callInProgress = false
            )
        )
        assertEquals(
            IncomingAlertMode.NONE,
            CallTonePlayer.resolveIncomingAlertMode(
                ringerMode = AudioManager.RINGER_MODE_SILENT,
                dndAllows = true,
                vibrateWhenRinging = true,
                callInProgress = false
            )
        )
        assertEquals(
            IncomingAlertMode.VIBRATE_ONLY,
            CallTonePlayer.resolveIncomingAlertMode(
                ringerMode = AudioManager.RINGER_MODE_VIBRATE,
                dndAllows = true,
                vibrateWhenRinging = false,
                callInProgress = false
            )
        )
        assertEquals(
            IncomingAlertMode.RING_ONLY,
            CallTonePlayer.resolveIncomingAlertMode(
                ringerMode = AudioManager.RINGER_MODE_NORMAL,
                dndAllows = true,
                vibrateWhenRinging = false,
                callInProgress = false
            )
        )
        assertEquals(
            IncomingAlertMode.RING_AND_VIBRATE,
            CallTonePlayer.resolveIncomingAlertMode(
                ringerMode = AudioManager.RINGER_MODE_NORMAL,
                dndAllows = true,
                vibrateWhenRinging = true,
                callInProgress = false
            )
        )
        assertEquals(
            IncomingAlertMode.CALL_WAITING_TONE,
            CallTonePlayer.resolveIncomingAlertMode(
                ringerMode = AudioManager.RINGER_MODE_NORMAL,
                dndAllows = true,
                vibrateWhenRinging = true,
                callInProgress = true
            )
        )
    }

    @Test
    fun `shouldPlayCallEndedTone only plays for dialing or active non-canceled disconnect causes`() {
        assertFalse(CallTonePlayer.shouldPlayCallEndedTone(wasDialingOrActive = false, DisconnectCause.REMOTE))
        assertFalse(CallTonePlayer.shouldPlayCallEndedTone(wasDialingOrActive = false, DisconnectCause.MISSED))
        assertFalse(CallTonePlayer.shouldPlayCallEndedTone(wasDialingOrActive = false, DisconnectCause.REJECTED))

        assertTrue(CallTonePlayer.shouldPlayCallEndedTone(wasDialingOrActive = true, DisconnectCause.REMOTE))
        assertTrue(CallTonePlayer.shouldPlayCallEndedTone(wasDialingOrActive = true, DisconnectCause.LOCAL))
        assertTrue(CallTonePlayer.shouldPlayCallEndedTone(wasDialingOrActive = true, DisconnectCause.ERROR))
        assertTrue(CallTonePlayer.shouldPlayCallEndedTone(wasDialingOrActive = true, DisconnectCause.BUSY))
        assertTrue(CallTonePlayer.shouldPlayCallEndedTone(wasDialingOrActive = true, DisconnectCause.MISSED))

        assertFalse(CallTonePlayer.shouldPlayCallEndedTone(wasDialingOrActive = true, DisconnectCause.CANCELED))
        assertFalse(CallTonePlayer.shouldPlayCallEndedTone(wasDialingOrActive = true, DisconnectCause.REJECTED))
    }

    @Test
    fun `synthesizeRingbackPcm produces 6s buffer with 250ms lead-in, 2s tone, and 3_75s silence`() {
        val sampleRate = 16_000
        val pcm = CallTonePlayer.synthesizeRingbackPcm(sampleRate)
        assertEquals(sampleRate * 6, pcm.size)

        val leadInEnd = 4_000
        val toneEnd = leadInEnd + sampleRate * 2
        for (i in 0 until leadInEnd) {
            assertEquals("lead-in sample $i should be zero", 0, pcm[i].toInt())
        }
        for (i in toneEnd until pcm.size) {
            assertEquals("trailing silence sample $i should be zero", 0, pcm[i].toInt())
        }

        val maxExpected = (0.18 * Short.MAX_VALUE).toInt() + 1
        var maxPeak = 0
        var activeEnergy = 0.0
        for (i in leadInEnd until toneEnd) {
            val v = pcm[i].toInt()
            val av = abs(v)
            if (av > maxPeak) maxPeak = av
            activeEnergy += v.toDouble() * v.toDouble()
        }
        assertTrue("peak $maxPeak should be <= $maxExpected", maxPeak in 1000..maxExpected)
        assertTrue("active window should have strong signal", sqrt(activeEnergy / (sampleRate * 2)) > 500.0)
        assertEquals(0, pcm[leadInEnd].toInt())
        assertEquals(0, pcm[toneEnd - 1].toInt())
    }

    @Test
    fun `synthesizeCallEndedPcm produces two decaying tones separated by silence`() {
        val sampleRate = 16_000
        val pcm = CallTonePlayer.synthesizeCallEndedPcm(sampleRate)
        val note1Len = (sampleRate * 0.130).toInt()
        val gapLen = (sampleRate * 0.030).toInt()
        val note2Len = (sampleRate * 0.180).toInt()
        assertEquals(note1Len + gapLen + note2Len, pcm.size)

        val maxExpected = (0.15 * Short.MAX_VALUE).toInt() + 1
        var peak = 0
        for (s in pcm) {
            val av = abs(s.toInt())
            if (av > peak) peak = av
        }
        assertTrue("peak $peak should be <= $maxExpected", peak in 500..maxExpected)

        for (i in note1Len until (note1Len + gapLen)) {
            assertEquals("gap sample $i should be zero", 0, pcm[i].toInt())
        }

        fun rms(start: Int, end: Int): Double {
            var sum = 0.0
            for (i in start until end) {
                val v = pcm[i].toDouble()
                sum += v * v
            }
            return sqrt(sum / (end - start))
        }

        assertTrue("note 1 decays over time", rms(160, note1Len / 2) > rms(note1Len / 2, note1Len))
        val note2Start = note1Len + gapLen
        assertTrue("note 2 decays over time", rms(note2Start + 160, note2Start + note2Len / 2) > rms(note2Start + note2Len / 2, pcm.size))
    }
}
