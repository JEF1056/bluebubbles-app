package com.bluebubbles.messaging

import com.bluebubbles.messaging.services.backend_ui_interop.DartWorker
import com.bluebubbles.messaging.services.foreground.SocketIOForegroundService
import com.bluebubbles.messaging.services.wear.WearSyncManager
import java.io.IOException
import java.net.InetAddress
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OptPhoneCoreTest {
    @Test
    fun socketErrorAndDisconnectParsing_handlesUnexpectedTypes() {
        assertEquals("boom", SocketIOForegroundService.parseConnectErrorMessage(IllegalStateException("boom")))
        val nested = RuntimeException(
            "xhr poll error",
            IOException("Failed to connect to bb.jessfan.com", IOException("ENETUNREACH")),
        )
        assertEquals(
            "xhr poll error (caused by IOException: Failed to connect to bb.jessfan.com -> IOException: ENETUNREACH)",
            SocketIOForegroundService.parseConnectErrorMessage(nested),
        )
        assertEquals("raw-str", SocketIOForegroundService.parseConnectErrorMessage("raw-str"))
        assertEquals("Unknown error", SocketIOForegroundService.parseConnectErrorMessage(null))

        val ipv6 = InetAddress.getByAddress("bb.jessfan.com", ByteArray(16).apply { this[15] = 1 })
        val ipv4 = InetAddress.getByAddress("bb.jessfan.com", byteArrayOf(104, 21, 27, -12))
        assertEquals(listOf(ipv4, ipv6), SocketIOForegroundService.orderIpv4First(listOf(ipv6, ipv4)))
        assertEquals(listOf(ipv6), SocketIOForegroundService.orderIpv4First(listOf(ipv6)))

        assertEquals("io server disconnect", SocketIOForegroundService.parseDisconnectReason("io server disconnect"))
        assertEquals("42", SocketIOForegroundService.parseDisconnectReason(42))
        assertEquals("unknown", SocketIOForegroundService.parseDisconnectReason(null))

        assertTrue(SocketIOForegroundService.shouldReconnectOnDisconnect("io server disconnect"))
        assertFalse(SocketIOForegroundService.shouldReconnectOnDisconnect("io client disconnect"))
    }

    @Test
    fun dartWorkerIdleKeepAlive_extendsWhenSocketActive() {
        assertEquals(60_000L, DartWorker.engineIdleKeepAliveMs(hasActiveSocket = true))
        assertEquals(5_000L, DartWorker.engineIdleKeepAliveMs(hasActiveSocket = false))
    }

    @Test
    fun wearSyncManager_validatesSocketOriginAndCapsAvatarsAndHashes() {
        assertTrue(WearSyncManager.isValidSocketOrigin("https://example.com:1234"))
        assertTrue(WearSyncManager.isValidSocketOrigin("http://192.168.1.10"))
        assertFalse(WearSyncManager.isValidSocketOrigin(""))
        assertFalse(WearSyncManager.isValidSocketOrigin("not a uri"))
        assertFalse(WearSyncManager.isValidSocketOrigin("ftp://example.com"))

        assertTrue(WearSyncManager.shouldPushContactAvatar(0))
        assertTrue(WearSyncManager.shouldPushContactAvatar(79))
        assertFalse(WearSyncManager.shouldPushContactAvatar(80))

        assertEquals(
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
            WearSyncManager.sha256Hex("hello".toByteArray())
        )
    }
}
