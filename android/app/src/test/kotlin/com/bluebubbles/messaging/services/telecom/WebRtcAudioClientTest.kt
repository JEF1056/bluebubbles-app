package com.bluebubbles.messaging.services.telecom

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WebRtcAudioClientTest {

    @Test
    fun `parseIceServerSpecsFromMaps falls back to default Google STUN when null or empty`() {
        val fromNull = WebRtcAudioClient.parseIceServerSpecsFromMaps(null)
        assertEquals(1, fromNull.size)
        assertEquals(listOf("stun:stun.l.google.com:19302"), fromNull[0].urls)
        assertNull(fromNull[0].username)
        assertNull(fromNull[0].credential)

        val fromEmpty = WebRtcAudioClient.parseIceServerSpecsFromMaps(emptyList())
        assertEquals(1, fromEmpty.size)
        assertEquals(listOf("stun:stun.l.google.com:19302"), fromEmpty[0].urls)
    }

    @Test
    fun `parseIceServerSpecsFromMaps parses STUN and TURN with string or list urls and credentials`() {
        val raw = listOf(
            mapOf("urls" to "stun:stun.l.google.com:19302"),
            mapOf(
                "urls" to listOf("turn:turn.example.com:3478", "turns:turn.example.com:5349"),
                "username" to "bbuser",
                "credential" to "bbpass"
            ),
            mapOf(
                "url" to "turn:legacy.example.com:3478",
                "username" to "  ",
                "credential" to "secret"
            ),
            mapOf("urls" to "")
        )

        val specs = WebRtcAudioClient.parseIceServerSpecsFromMaps(raw)
        assertEquals(3, specs.size)
        assertEquals(listOf("stun:stun.l.google.com:19302"), specs[0].urls)
        assertNull(specs[0].username)

        assertEquals(listOf("turn:turn.example.com:3478", "turns:turn.example.com:5349"), specs[1].urls)
        assertEquals("bbuser", specs[1].username)
        assertEquals("bbpass", specs[1].credential)

        assertEquals(listOf("turn:legacy.example.com:3478"), specs[2].urls)
        assertNull(specs[2].username)
        assertEquals("secret", specs[2].credential)

        val rtcServers = WebRtcAudioClient.buildRtcIceServers(specs)
        assertEquals(3, rtcServers.size)
        assertTrue(rtcServers[1].urls.contains("turns:turn.example.com:5349"))
        assertEquals("bbuser", rtcServers[1].username)
        assertEquals("bbpass", rtcServers[1].password)
    }

    @Test
    fun `parsePayload returns null for unsupported types`() {
        assertNull(WebRtcAudioClient.parsePayload(null))
        assertNull(WebRtcAudioClient.parsePayload(123))
    }

    @Test
    fun `buildFallbackSocketOptions uses guid query param matching server auth and preserves headers`() {
        val opts = WebRtcAudioClient.buildFallbackSocketOptions(
            authKey = "sec ret+123",
            extraHeaders = mapOf("X-Custom" to "val")
        )

        assertEquals("guid=sec+ret%2B123", opts.query)
        assertFalse(opts.query.contains("password="))
        assertTrue(opts.reconnection)
        assertTrue(opts.forceNew)
        assertArrayEquals(arrayOf("polling", "websocket"), opts.transports)
        assertEquals(listOf("val"), opts.extraHeaders["X-Custom"])
        assertNotNull(opts.callFactory)
        assertNotNull(opts.webSocketFactory)
    }

    @Test
    fun `resolveIceServersAfterConnect awaits socket connect before fetching TURN servers`() {
        var connected = false
        val events = mutableListOf<String>()
        val turnSpec = IceServerSpec(
            urls = listOf("turn:turn.example.com:3478"),
            username = "u",
            credential = "p"
        )

        val specs = WebRtcAudioClient.resolveIceServersAfterConnect(
            isConnected = { connected },
            isStopped = { false },
            awaitConnect = {
                events.add("awaitConnect")
                connected = true
                true
            },
            fetchFromConnectedSocket = {
                assertTrue("fetch must only run after socket is connected", connected)
                events.add("fetchIce")
                listOf(turnSpec)
            }
        )

        assertEquals(listOf("awaitConnect", "fetchIce"), events)
        assertEquals(listOf(turnSpec), specs)
    }

    @Test
    fun `resolveIceServersAfterConnect skips await when already connected and falls back to STUN if still disconnected or stopped`() {
        var awaitCalls = 0
        var fetchCalls = 0
        val alreadyConnected = WebRtcAudioClient.resolveIceServersAfterConnect(
            isConnected = { true },
            isStopped = { false },
            awaitConnect = {
                awaitCalls++
                true
            },
            fetchFromConnectedSocket = {
                fetchCalls++
                listOf(IceServerSpec(listOf("turn:turn.example.com:3478")))
            }
        )
        assertEquals(0, awaitCalls)
        assertEquals(1, fetchCalls)
        assertEquals(listOf("turn:turn.example.com:3478"), alreadyConnected[0].urls)

        val neverConnected = WebRtcAudioClient.resolveIceServersAfterConnect(
            isConnected = { false },
            isStopped = { false },
            awaitConnect = { false },
            fetchFromConnectedSocket = {
                error("must not fetch when socket failed to connect")
            }
        )
        assertEquals(listOf("stun:stun.l.google.com:19302"), neverConnected[0].urls)

        var stoppedMidWait = false
        val stoppedDuringWait = WebRtcAudioClient.resolveIceServersAfterConnect(
            isConnected = { false },
            isStopped = { stoppedMidWait },
            awaitConnect = {
                stoppedMidWait = true
                true
            },
            fetchFromConnectedSocket = {
                error("must not fetch when stopped mid-wait")
            }
        )
        assertEquals(listOf("stun:stun.l.google.com:19302"), stoppedDuringWait[0].urls)

        val stoppedBeforeConnect = WebRtcAudioClient.resolveIceServersAfterConnect(
            isConnected = { false },
            isStopped = { true },
            awaitConnect = { error("must not wait when already stopped") },
            fetchFromConnectedSocket = { error("must not fetch when stopped") }
        )
        assertEquals(listOf("stun:stun.l.google.com:19302"), stoppedBeforeConnect[0].urls)
    }

    @Test
    fun `CallResourceLease acquires and idempotently releases audio focus, wake lock, and wifi lock even when one throws`() {
        var audioReleases = 0
        var wakeReleases = 0
        var wifiReleases = 0

        val lease = CallResourceLease(
            acquireAudioFocus = { true },
            releaseAudioFocus = {
                audioReleases++
                throw IllegalStateException("audio focus abandon failed")
            },
            acquireWakeLock = { true },
            releaseWakeLock = { wakeReleases++ },
            acquireWifiLock = { true },
            releaseWifiLock = { wifiReleases++ }
        )

        lease.acquireAll()
        assertTrue(lease.audioFocusHeld)
        assertTrue(lease.wakeLockHeld)
        assertTrue(lease.wifiLockHeld)

        lease.releaseAll()
        lease.releaseAll()

        assertFalse(lease.audioFocusHeld)
        assertFalse(lease.wakeLockHeld)
        assertFalse(lease.wifiLockHeld)
        assertEquals(1, audioReleases)
        assertEquals(1, wakeReleases)
        assertEquals(1, wifiReleases)
    }

    @Test
    fun `CallResourceLease handles partial acquisition failures without leaking or releasing unheld locks`() {
        var audioReleases = 0
        var wakeReleases = 0
        var wifiReleases = 0

        val lease = CallResourceLease(
            acquireAudioFocus = { false },
            releaseAudioFocus = { audioReleases++ },
            acquireWakeLock = { throw SecurityException("no wake lock") },
            releaseWakeLock = { wakeReleases++ },
            acquireWifiLock = { true },
            releaseWifiLock = { wifiReleases++ }
        )

        lease.acquireAll()
        assertFalse(lease.audioFocusHeld)
        assertFalse(lease.wakeLockHeld)
        assertTrue(lease.wifiLockHeld)

        lease.releaseAll()
        assertFalse(lease.wifiLockHeld)
        assertEquals(0, audioReleases)
        assertEquals(0, wakeReleases)
        assertEquals(1, wifiReleases)
    }
}
