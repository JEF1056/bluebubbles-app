package com.bluebubbles.messaging.services.telecom

import android.media.AudioDeviceInfo
import android.telecom.CallAudioState
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.webrtc.CameraEnumerationAndroid

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

    @Test
    fun `selectCaptureSize picks 1080p30 when supported and falls back cleanly`() {
        val formats = listOf(
            CameraEnumerationAndroid.CaptureFormat(640, 480, 15, 30),
            CameraEnumerationAndroid.CaptureFormat(1280, 720, 15, 30),
            CameraEnumerationAndroid.CaptureFormat(1920, 1080, 15, 30),
            CameraEnumerationAndroid.CaptureFormat(3840, 2160, 15, 30)
        )
        assertEquals(Triple(1920, 1080, 30), WebRtcAudioClient.selectCaptureSize(formats))
        assertEquals(Triple(1920, 1080, 30), WebRtcAudioClient.selectCaptureSize(emptyList()))

        val hdOnly = listOf(
            CameraEnumerationAndroid.CaptureFormat(640, 480, 15, 30),
            CameraEnumerationAndroid.CaptureFormat(1280, 720, 15, 30)
        )
        assertEquals(Triple(1280, 720, 30), WebRtcAudioClient.selectCaptureSize(hdOnly))
    }

    @Test
    fun `buildAudioConstraints toggles noise suppression and highpass filter with voice isolation`() {
        val enabled = WebRtcAudioClient.buildAudioConstraints(true)
        assertEquals("true", enabled.mandatory.first { it.key == "googNoiseSuppression" }.value)
        assertEquals("true", enabled.mandatory.first { it.key == "googNoiseSuppression2" }.value)
        assertEquals("true", enabled.mandatory.first { it.key == "googHighpassFilter" }.value)
        assertEquals("true", enabled.mandatory.first { it.key == "googEchoCancellation" }.value)
        assertEquals("true", enabled.mandatory.first { it.key == "googAutoGainControl2" }.value)

        val disabled = WebRtcAudioClient.buildAudioConstraints(false)
        assertEquals("false", disabled.mandatory.first { it.key == "googNoiseSuppression" }.value)
        assertEquals("false", disabled.mandatory.first { it.key == "googNoiseSuppression2" }.value)
        assertEquals("false", disabled.mandatory.first { it.key == "googHighpassFilter" }.value)
        assertEquals("true", disabled.mandatory.first { it.key == "googEchoCancellation" }.value)
        assertEquals("true", disabled.mandatory.first { it.key == "googAutoGainControl2" }.value)
    }

    @Test
    fun `tuneOpusSdp configures FEC DTX bitrate and stereo for Opus and leaves non-Opus untouched`() {
        val withFmtp = listOf(
            "v=0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111 0",
            "a=rtpmap:111 opus/48000/2",
            "a=fmtp:111 minptime=20;useinbandfec=0;cbr=1",
            "a=rtpmap:0 PCMU/8000"
        ).joinToString("\r\n")
        val tuned = WebRtcAudioClient.tuneOpusSdp(withFmtp)
        assertTrue(tuned.contains("a=fmtp:111 minptime=10;useinbandfec=1;cbr=1;usedtx=1;maxaveragebitrate=48000;stereo=0"))

        val withoutFmtp = listOf(
            "v=0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=rtpmap:111 opus/48000/2"
        ).joinToString("\n")
        val inserted = WebRtcAudioClient.tuneOpusSdp(withoutFmtp)
        assertTrue(inserted.contains("a=rtpmap:111 opus/48000/2\na=fmtp:111 minptime=10;useinbandfec=1;usedtx=1;maxaveragebitrate=48000;stereo=0"))

        val noOpus = "v=0\r\nm=audio 9 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n"
        assertEquals(noOpus, WebRtcAudioClient.tuneOpusSdp(noOpus))
    }

    @Test
    fun `AdaptiveUplinkSupervisor steps down on sustained loss and respects cooldown before stepping up`() {
        val sup = AdaptiveUplinkSupervisor()
        assertEquals(1920, sup.currentRung.width)

        // Warmup (first 7 samples) ignores transient startup BWE ramp
        for (i in 0 until 7) {
            assertNull(sup.recordSample(lossFraction = 0.12, limited = false, nowMs = 1_000L + i * 2_000L))
        }

        // Post-warmup: 2 consecutive loss samples trigger step-down
        assertNull(sup.recordSample(lossFraction = 0.12, limited = false, nowMs = 15_000L))
        val dropped = sup.recordSample(lossFraction = 0.12, limited = false, nowMs = 17_000L)
        assertNotNull(dropped)
        assertEquals(1280, dropped!!.width)

        // Cooldown (4s) blocks step-up even with 2 good samples
        assertNull(sup.recordSample(lossFraction = 0.0, limited = false, nowMs = 18_000L))
        assertNull(sup.recordSample(lossFraction = 0.0, limited = false, nowMs = 20_000L))

        // After 4s cooldown, 2 good samples promote back to 1080p
        assertNull(sup.recordSample(lossFraction = 0.0, limited = false, nowMs = 22_000L))
        val promoted = sup.recordSample(lossFraction = 0.0, limited = false, nowMs = 24_000L)
        assertNotNull(promoted)
        assertEquals(1920, promoted!!.width)
    }

    @Test
    fun `AdaptiveUplinkRung maps landscape and portrait dimensions for 5-arg adaptOutputFormat`() {
        for (rung in AdaptiveUplinkSupervisor.DEFAULT_RUNGS) {
            assertTrue(rung.landscapeWidth >= rung.landscapeHeight)
            assertTrue(rung.portraitWidth <= rung.portraitHeight)
            assertEquals(rung.width, rung.landscapeWidth)
            assertEquals(rung.height, rung.landscapeHeight)
            assertEquals(rung.height, rung.portraitWidth)
            assertEquals(rung.width, rung.portraitHeight)
        }

        val portraitInput = AdaptiveUplinkRung(360, 640, 24, 300_000, 650_000)
        assertEquals(640, portraitInput.landscapeWidth)
        assertEquals(360, portraitInput.landscapeHeight)
        assertEquals(360, portraitInput.portraitWidth)
        assertEquals(640, portraitInput.portraitHeight)
    }

    @Test
    fun `FaceTimeVideoEffect parse normalizes camelCase and snake_case`() {
        assertEquals(FaceTimeVideoEffect.NONE, FaceTimeVideoEffect.parse(null))
        assertEquals(FaceTimeVideoEffect.NONE, FaceTimeVideoEffect.parse("none"))
        assertEquals(FaceTimeVideoEffect.BLUR_LIGHT, FaceTimeVideoEffect.parse("blurLight"))
        assertEquals(FaceTimeVideoEffect.BLUR_LIGHT, FaceTimeVideoEffect.parse("blur_light"))
        assertEquals(FaceTimeVideoEffect.BLUR_STRONG, FaceTimeVideoEffect.parse("blurStrong"))
        assertEquals(FaceTimeVideoEffect.BLUR_STRONG, FaceTimeVideoEffect.parse("blur_strong"))
        assertEquals(FaceTimeVideoEffect.VIRTUAL_BACKGROUND, FaceTimeVideoEffect.parse("virtualBackground"))
        assertEquals(FaceTimeVideoEffect.VIRTUAL_BACKGROUND, FaceTimeVideoEffect.parse("virtual_background"))
    }

    @Test
    fun `FaceTimeAudioRouteManager maps device types and legacy CallAudioState routes`() {
        assertEquals("earpiece", FaceTimeAudioRouteManager.mapOutputDeviceKind(AudioDeviceInfo.TYPE_BUILTIN_EARPIECE))
        assertEquals("speaker", FaceTimeAudioRouteManager.mapOutputDeviceKind(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER))
        assertEquals("bluetooth", FaceTimeAudioRouteManager.mapOutputDeviceKind(AudioDeviceInfo.TYPE_BLUETOOTH_SCO))
        assertEquals("usb", FaceTimeAudioRouteManager.mapOutputDeviceKind(AudioDeviceInfo.TYPE_USB_HEADSET))
        assertEquals("builtinMic", FaceTimeAudioRouteManager.mapInputDeviceKind(AudioDeviceInfo.TYPE_BUILTIN_MIC))
        assertEquals("wired", FaceTimeAudioRouteManager.mapInputDeviceKind(AudioDeviceInfo.TYPE_WIRED_HEADSET))

        val legacy = FaceTimeAudioRouteManager.buildLegacyOutputs(
            supportedMask = CallAudioState.ROUTE_EARPIECE or CallAudioState.ROUTE_SPEAKER or CallAudioState.ROUTE_BLUETOOTH,
            activeRoute = CallAudioState.ROUTE_BLUETOOTH,
            btNamesAndAddrs = listOf("Pixel Buds Pro" to "AA:BB:CC:DD:EE:FF"),
            activeBtAddr = "AA:BB:CC:DD:EE:FF"
        )
        assertEquals(3, legacy.size)
        val bt = legacy.first { it.kind == "bluetooth" }
        assertEquals("bt:AA:BB:CC:DD:EE:FF", bt.id)
        assertEquals("Pixel Buds Pro", bt.label)
        assertTrue(bt.isActive)
    }

    @Test
    fun `rotatedFrameSize swaps dimensions on quarter turns and preserves them on 0 or 180`() {
        assertEquals(720 to 1280, WebRtcAudioClient.rotatedFrameSize(1280, 720, 270))
        assertEquals(720 to 1280, WebRtcAudioClient.rotatedFrameSize(1280, 720, 90))
        assertEquals(1280 to 720, WebRtcAudioClient.rotatedFrameSize(1280, 720, 0))
        assertEquals(1280 to 720, WebRtcAudioClient.rotatedFrameSize(1280, 720, 180))
    }

    @Test
    fun `isAllowedMediaCodec permits hardware codecs and emulator or Google H264 codecs`() {
        assertTrue(WebRtcAudioClient.isAllowedMediaCodec("c2.exynos.h264.encoder", isHardwareAccelerated = true))
        assertTrue(WebRtcAudioClient.isAllowedMediaCodec("c2.android.avc.encoder", isHardwareAccelerated = false))
        assertTrue(WebRtcAudioClient.isAllowedMediaCodec("c2.google.avc.decoder", isHardwareAccelerated = false))
        assertTrue(WebRtcAudioClient.isAllowedMediaCodec("OMX.google.h264.encoder", isHardwareAccelerated = false))
        assertFalse(WebRtcAudioClient.isAllowedMediaCodec("c2.android.vp8.encoder", isHardwareAccelerated = false))
    }

    @Test
    fun `summarizeIceCandidate and sdpContainsH264 parse diagnostics cleanly`() {
        assertEquals(
            "host 192.168.1.50:54321",
            WebRtcAudioClient.summarizeIceCandidate("candidate:1 1 udp 2122260223 192.168.1.50 54321 typ host generation 0")
        )
        assertEquals("unknown", WebRtcAudioClient.summarizeIceCandidate(null))
        assertTrue(WebRtcAudioClient.sdpContainsH264("v=0\r\na=rtpmap:96 H264/90000\r\n"))
        assertFalse(WebRtcAudioClient.sdpContainsH264("v=0\r\na=rtpmap:96 VP8/90000\r\n"))
    }

    @Test
    fun `selectH264EncoderColorFormat and prependH264ConfigIfMissing work for fallback encoder`() {
        assertEquals(
            android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar,
            WebRtcAudioClient.selectH264EncoderColorFormat(
                intArrayOf(
                    android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar,
                    android.media.MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar
                )
            )
        )
        assertNull(WebRtcAudioClient.selectH264EncoderColorFormat(intArrayOf(0x7f000789)))

        val config = byteArrayOf(0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68)
        val idrWithoutSps = byteArrayOf(0, 0, 0, 1, 0x65, 0x11, 0x22)
        val combined = WebRtcAudioClient.prependH264ConfigIfMissing(idrWithoutSps, config, isKeyFrame = true)
        assertEquals(config.size + idrWithoutSps.size, combined.size)
        assertTrue(WebRtcAudioClient.hasH264SpsPrefix(combined))

        val idrWithSps = byteArrayOf(0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x65)
        val unchanged = WebRtcAudioClient.prependH264ConfigIfMissing(idrWithSps, config, isKeyFrame = true)
        assertEquals(idrWithSps.size, unchanged.size)

        val delta = byteArrayOf(0, 0, 0, 1, 0x61, 0x33)
        assertEquals(delta.size, WebRtcAudioClient.prependH264ConfigIfMissing(delta, config, isKeyFrame = false).size)
    }

    @Test
    fun `buildLocalVideoTexturePayload hydrates camera flags and only includes positive dimensions`() {
        val withDims = WebRtcAudioClient.buildLocalVideoTexturePayload(
            callUuid = "call-123",
            textureId = 42L,
            width = 1080,
            height = 1920,
            cameraEnabled = true,
            canFlipCamera = true,
            frontCamera = false
        )
        assertEquals("local-video-texture", withDims["phase"])
        assertEquals("call-123", withDims["call_uuid"])
        assertEquals(42L, withDims["texture_id"])
        assertEquals(1080, withDims["width"])
        assertEquals(1920, withDims["height"])
        assertEquals(true, withDims["camera_enabled"])
        assertEquals(true, withDims["can_flip_camera"])
        assertEquals(false, withDims["front_camera"])

        val withoutDims = WebRtcAudioClient.buildLocalVideoTexturePayload(
            callUuid = "call-123",
            textureId = 42L,
            width = 0,
            height = 0,
            cameraEnabled = false,
            canFlipCamera = true,
            frontCamera = true
        )
        assertFalse(withoutDims.containsKey("width"))
        assertFalse(withoutDims.containsKey("height"))
        assertEquals(false, withoutDims["camera_enabled"])
        assertEquals(true, withoutDims["can_flip_camera"])
        assertEquals(true, withoutDims["front_camera"])
    }
}
