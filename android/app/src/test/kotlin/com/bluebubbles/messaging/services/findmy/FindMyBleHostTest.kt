package com.bluebubbles.messaging.services.findmy

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FindMyBleHostTest {
    @Test
    fun parseGoogleFmdnServiceData_parses20ByteAnd32ByteFrames() {
        val eid20 = ByteArray(20) { (it + 1).toByte() }
        val frame21 = byteArrayOf(0x40.toByte()) + eid20
        val parsed20 = FindMyBleHost.parseGoogleFmdnServiceData(frame21)
        assertNotNull(parsed20)
        assertEquals(0x40, parsed20!!.frameType)
        assertEquals(20, parsed20.eidByteLength)
        assertEquals("0102030405060708090a0b0c0d0e0f1011121314", parsed20.eidHex)

        val eid32 = ByteArray(32) { (0xA0 + it).toByte() }
        val frame33 = byteArrayOf(0x41.toByte()) + eid32
        val parsed32 = FindMyBleHost.parseGoogleFmdnServiceData(frame33)
        assertNotNull(parsed32)
        assertEquals(32, parsed32!!.eidByteLength)

        // Wrong frame header
        assertNull(FindMyBleHost.parseGoogleFmdnServiceData(byteArrayOf(0x10) + eid20))
        // Too short
        assertNull(FindMyBleHost.parseGoogleFmdnServiceData(byteArrayOf(0x40, 0x01, 0x02)))
    }

    @Test
    fun parseSamsungSmartTagServiceData_extractsPrivacyIdUwbAndBattery() {
        val data = ByteArray(20)
        // state: battery bits (bits 5..6) = 2 -> 0x40
        data[0] = 0x40.toByte()
        // aging counter = 0x010203
        data[1] = 0x01
        data[2] = 0x02
        data[3] = 0x03
        // privacyId = 1122334455667788
        for (i in 0 until 8) {
            data[4 + i] = ((i + 1) * 0x11).toByte()
        }
        // flags: UWB bit (0x04) set
        data[12] = 0x04

        val parsed = FindMyBleHost.parseSamsungSmartTagServiceData(data)
        assertNotNull(parsed)
        assertEquals(0x010203, parsed!!.agingCounter)
        assertEquals("1122334455667788", parsed.privacyIdHex)
        assertTrue(parsed.uwbCapable)
        assertEquals(2, parsed.batteryLevel)

        // Short frame rejected
        assertNull(FindMyBleHost.parseSamsungSmartTagServiceData(ByteArray(19)))
    }

    @Test
    fun buildGoogleRingPacket_builds14ByteHmacVector() {
        val challenge9 = byteArrayOf(
            0x01,
            0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        )
        val ringKey = ByteArray(16) { (it + 0x20).toByte() }
        val packet = FindMyBleHost.buildGoogleRingPacket(
            challenge9 = challenge9,
            ringKey = ringKey,
            stateMask = FindMyBleHost.stateMaskForComponent(stop = false, component = null),
        )

        assertEquals(14, packet.size)
        assertEquals(0x05.toByte(), packet[0])
        assertEquals(0x0C.toByte(), packet[1])
        assertEquals(0xFF.toByte(), packet[10]) // all components
        assertEquals(0x02.toByte(), packet[11]) // 600s hi
        assertEquals(0x58.toByte(), packet[12]) // 600s lo
        assertEquals(0x00.toByte(), packet[13]) // volume

        // Independent HMAC verification
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(ringKey, "HmacSHA256"))
        val expectedMac8 = mac.doFinal(
            challenge9 + byteArrayOf(0x05, 0x0C, 0xFF.toByte(), 0x02, 0x58, 0x00),
        ).copyOfRange(0, 8)
        assertArrayEquals(expectedMac8, packet.copyOfRange(2, 10))

        assertEquals(0x00, FindMyBleHost.stateMaskForComponent(stop = true, component = "right"))
        assertEquals(0x01, FindMyBleHost.stateMaskForComponent(stop = false, component = "R"))
        assertEquals(0x02, FindMyBleHost.stateMaskForComponent(stop = false, component = "left"))
        assertEquals(0x04, FindMyBleHost.stateMaskForComponent(stop = false, component = "case"))
    }

    @Test
    fun rssiDistanceZoneAndTrend_computeExpectedValues() {
        val closeMeters = FindMyBleHost.estimateDistanceMeters(-55.0)
        assertTrue(closeMeters < 1.2)
        assertEquals("here", FindMyBleHost.zoneForDistance(closeMeters))
        assertEquals("near", FindMyBleHost.zoneForDistance(2.0))
        assertEquals("not_far", FindMyBleHost.zoneForDistance(6.0))
        assertEquals("far", FindMyBleHost.zoneForDistance(15.0))

        assertEquals("stronger", FindMyBleHost.computeTrend(-70.0, -67.0))
        assertEquals("weaker", FindMyBleHost.computeTrend(-67.0, -70.0))
        assertEquals("steady", FindMyBleHost.computeTrend(-67.0, -66.5))
        assertEquals("steady", FindMyBleHost.computeTrend(null, -66.5))
    }
}
