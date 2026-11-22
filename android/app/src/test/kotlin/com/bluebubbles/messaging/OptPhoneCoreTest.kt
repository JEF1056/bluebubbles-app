package com.bluebubbles.messaging

import com.bluebubbles.messaging.services.backend_ui_interop.DartWorker
import com.bluebubbles.messaging.services.foreground.SocketIOForegroundService
import com.bluebubbles.messaging.services.wear.WearSyncManager
import io.socket.client.IO
import java.io.IOException
import java.net.InetAddress
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
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
        assertEquals(30_000L, DartWorker.engineIdleKeepAliveMs(hasActiveSocket = false))
    }

    @Test
    fun socketIOForegroundService_setsBackoffAndGatesOnNetwork() {
        val opts = IO.Options()
        SocketIOForegroundService.applyReconnectBackoff(opts)
        assertEquals(2_000L, opts.reconnectionDelay)
        assertEquals(60_000L, opts.reconnectionDelayMax)

        // Initial offline gating
        assertFalse(
            SocketIOForegroundService.shouldAttemptConnect(
                hasNetwork = false,
                isBeingDestroyed = false,
                hasSocket = true,
                isConnected = false,
            ),
        )
        assertTrue(
            SocketIOForegroundService.shouldAttemptConnect(
                hasNetwork = true,
                isBeingDestroyed = false,
                hasSocket = true,
                isConnected = false,
            ),
        )

        // Active network lost -> DISCONNECT
        assertEquals(
            SocketIOForegroundService.NetworkAction.DISCONNECT,
            SocketIOForegroundService.resolveNetworkAction(
                networkAvailable = false,
                isSameAsActive = true,
                hasActiveNetwork = true,
                isBeingDestroyed = false,
                hasStarted = true,
                hasSocket = true,
                isConnected = true,
            ),
        )
        // Stale onLost for a previous network -> NONE
        assertEquals(
            SocketIOForegroundService.NetworkAction.NONE,
            SocketIOForegroundService.resolveNetworkAction(
                networkAvailable = false,
                isSameAsActive = false,
                hasActiveNetwork = true,
                isBeingDestroyed = false,
                hasStarted = true,
                hasSocket = true,
                isConnected = true,
            ),
        )
        // Initial or regained network -> CONNECT
        assertEquals(
            SocketIOForegroundService.NetworkAction.CONNECT,
            SocketIOForegroundService.resolveNetworkAction(
                networkAvailable = true,
                isSameAsActive = false,
                hasActiveNetwork = false,
                isBeingDestroyed = false,
                hasStarted = true,
                hasSocket = true,
                isConnected = false,
            ),
        )
        // Direct switch to a different default network while disconnected -> RECONNECT (disconnect + connect)
        assertEquals(
            SocketIOForegroundService.NetworkAction.RECONNECT,
            SocketIOForegroundService.resolveNetworkAction(
                networkAvailable = true,
                isSameAsActive = false,
                hasActiveNetwork = true,
                isBeingDestroyed = false,
                hasStarted = true,
                hasSocket = true,
                isConnected = false,
            ),
        )
        // Already connected -> NONE
        assertEquals(
            SocketIOForegroundService.NetworkAction.NONE,
            SocketIOForegroundService.resolveNetworkAction(
                networkAvailable = true,
                isSameAsActive = true,
                hasActiveNetwork = true,
                isBeingDestroyed = false,
                hasStarted = true,
                hasSocket = true,
                isConnected = true,
            ),
        )
        // Being destroyed -> NONE
        assertEquals(
            SocketIOForegroundService.NetworkAction.NONE,
            SocketIOForegroundService.resolveNetworkAction(
                networkAvailable = true,
                isSameAsActive = false,
                hasActiveNetwork = false,
                isBeingDestroyed = true,
                hasStarted = true,
                hasSocket = true,
                isConnected = false,
            ),
        )
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

    @Test
    fun wearSyncManager_socketOptionsUsePollingFirstForceNewAndIpv4Client() {
        val headers = mapOf("CF-Access-Client-Id" to listOf("id-123"))
        val opts = WearSyncManager.buildRelaySocketOptions("my+pass/1", headers)
        val opts2 = WearSyncManager.buildRelaySocketOptions("my+pass/1", headers)
        assertTrue(opts.forceNew)
        assertTrue(opts.reconnection)
        assertEquals(2_000L, opts.reconnectionDelay)
        assertEquals(120_000L, opts.reconnectionDelayMax)
        assertArrayEquals(arrayOf("polling", "websocket"), opts.transports)
        assertEquals("guid=my%2Bpass%2F1", opts.query)
        assertEquals(headers, opts.extraHeaders)
        assertNotNull(opts.callFactory)
        assertNotNull(opts.webSocketFactory)
        assertTrue(opts.callFactory === opts.webSocketFactory)
        assertTrue(opts.callFactory === opts2.callFactory)
    }

    @Test
    fun wearSyncManager_forwardDedupAndMessageParsing() {
        WearSyncManager.clearForwardDedupForTests()
        assertTrue(WearSyncManager.shouldForwardDedup("new:msg-1", nowMs = 1_000L))
        assertFalse(WearSyncManager.shouldForwardDedup("new:msg-1", nowMs = 5_000L))
        assertTrue(WearSyncManager.shouldForwardDedup("new:msg-1", nowMs = 36_000L))
        assertTrue(WearSyncManager.shouldForwardDedup("upd:msg-1:111", nowMs = 5_000L))
        assertTrue(WearSyncManager.shouldForwardDedup("upd:msg-1:222", nowMs = 6_000L))

        val fcmPayload = """{"guid":"m-10","text":"yep","isFromMe":false,"dateCreated":1700000000,"chats":[{"guid":"iMessage;-;+16266165776"}]}"""
        val parsed = WearSyncManager.parseForwardableMessage(fcmPayload)
        assertNotNull(parsed)
        assertEquals("iMessage;-;+16266165776", parsed!!.first)
        assertEquals("m-10", parsed.second.get("guid").asString)
        assertEquals("yep", parsed.second.get("text").asString)
        assertEquals("iMessage;-;+16266165776", parsed.second.get("chatGuid").asString)
    }
}
