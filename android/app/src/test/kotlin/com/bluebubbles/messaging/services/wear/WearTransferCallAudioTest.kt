package com.bluebubbles.messaging.services.wear

import com.google.gson.JsonParser
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WearTransferCallAudioTest {

    @Test
    fun `path constant matches wire contract`() {
        assertEquals("/bb/transfer-call-audio", WearSyncManager.PATH_TRANSFER_CALL_AUDIO)
    }

    @Test
    fun `parseTransferCallAudioPayload parses valid phone and watch targets`() {
        val phonePayload = WearBridgeService.parseTransferCallAudioPayload(
            """{"callUuid":"call-123","target":"phone"}"""
        )
        assertNotNull(phonePayload)
        assertEquals("call-123", phonePayload?.callUuid)
        assertEquals("phone", phonePayload?.target)

        val watchPayload = WearBridgeService.parseTransferCallAudioPayload(
            """{"callUuid":"call-456","target":"WATCH"}"""
        )
        assertNotNull(watchPayload)
        assertEquals("call-456", watchPayload?.callUuid)
        assertEquals("watch", watchPayload?.target)

        val defaultTargetPayload = WearBridgeService.parseTransferCallAudioPayload(
            """{"callUuid":"call-789"}"""
        )
        assertNotNull(defaultTargetPayload)
        assertEquals("call-789", defaultTargetPayload?.callUuid)
        assertEquals("phone", defaultTargetPayload?.target)
    }

    @Test
    fun `parseTransferCallAudioPayload rejects blank uuid, invalid target, or malformed json`() {
        assertNull(WearBridgeService.parseTransferCallAudioPayload("""{"callUuid":"","target":"phone"}"""))
        assertNull(WearBridgeService.parseTransferCallAudioPayload("""{"target":"phone"}"""))
        assertNull(WearBridgeService.parseTransferCallAudioPayload("""{"callUuid":"call-1","target":"tablet"}"""))
        assertNull(WearBridgeService.parseTransferCallAudioPayload("not-json"))
    }

    @Test
    fun `buildCallActivePayload includes caller info and falls back to incoming meta`() {
        val explicitJson = WearSyncManager.buildCallActivePayload(
            callUuid = "call-1",
            startedAtMs = 1234L,
            muted = true,
            callerName = "Alice + 2",
            callerAddress = "alice@icloud.com",
            isVideo = true,
            isTelephony = false,
            isGroup = true,
            meta = null
        )
        val explicit = JsonParser.parseString(explicitJson).asJsonObject
        assertEquals("Alice + 2", explicit.get("callerName").asString)
        assertEquals("alice@icloud.com", explicit.get("callerAddress").asString)
        assertTrue(explicit.get("isVideo").asBoolean)
        assertFalse(explicit.get("isTelephony").asBoolean)
        assertTrue(explicit.get("isGroup").asBoolean)

        val fallbackJson = WearSyncManager.buildCallActivePayload(
            callUuid = "call-2",
            startedAtMs = 5678L,
            muted = false,
            meta = WearSyncManager.IncomingCallMeta(
                callerName = "Bob",
                callerAddress = "+15550001111",
                isVideo = false,
                isTelephony = true,
                isGroup = false
            )
        )
        val fallback = JsonParser.parseString(fallbackJson).asJsonObject
        assertEquals("Bob", fallback.get("callerName").asString)
        assertEquals("+15550001111", fallback.get("callerAddress").asString)
        assertFalse(fallback.get("isVideo").asBoolean)
        assertTrue(fallback.get("isTelephony").asBoolean)
        assertFalse(fallback.get("isGroup").asBoolean)
    }

    @Test
    fun `CallLifecycleSendQueue serializes suspending sends in FIFO order`() = runBlocking {
        val queueScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val queue = WearSyncManager.CallLifecycleSendQueue(queueScope)
            val events = mutableListOf<String>()
            val allDone = CompletableDeferred<Unit>()

            assertTrue(queue.enqueue {
                events.add("start:incoming")
                delay(60)
                events.add("end:incoming")
            })
            assertTrue(queue.enqueue {
                events.add("start:active")
                delay(10)
                events.add("end:active")
            })
            assertTrue(queue.enqueue {
                events.add("start:ended")
                events.add("end:ended")
                allDone.complete(Unit)
            })

            withTimeout(5_000L) {
                allDone.await()
            }
            assertEquals(
                listOf(
                    "start:incoming",
                    "end:incoming",
                    "start:active",
                    "end:active",
                    "start:ended",
                    "end:ended"
                ),
                events
            )
        } finally {
            queueScope.cancel()
        }
    }
}
