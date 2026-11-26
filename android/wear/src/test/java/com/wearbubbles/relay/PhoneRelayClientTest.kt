package com.wearbubbles.relay

import com.google.android.gms.wearable.Node
import com.google.gson.JsonParser
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

class PhoneRelayClientTest {

    private class FakeNode(
        private val nodeId: String,
        private val nearby: Boolean
    ) : Node {
        override fun getId(): String = nodeId
        override fun getDisplayName(): String = nodeId
        override fun isNearby(): Boolean = nearby
    }

    @Test
    fun `selectRelayNode prefers nearby node over cloud node`() {
        val cloud = FakeNode("cloud-1", nearby = false)
        val nearby = FakeNode("bt-1", nearby = true)
        assertEquals(
            "bt-1",
            PhoneRelayClient.selectRelayNode(listOf(cloud, nearby), hasStandaloneCredentials = true)?.id
        )
        assertEquals(
            "bt-1",
            PhoneRelayClient.selectRelayNode(listOf(cloud, nearby), hasStandaloneCredentials = false)?.id
        )
    }

    @Test
    fun `selectRelayNode uses cloud node only when standalone credentials are absent`() {
        val cloud = FakeNode("cloud-1", nearby = false)
        assertEquals(
            "cloud-1",
            PhoneRelayClient.selectRelayNode(listOf(cloud), hasStandaloneCredentials = false)?.id
        )
        assertNull(
            PhoneRelayClient.selectRelayNode(listOf(cloud), hasStandaloneCredentials = true)
        )
    }

    @Test
    fun `selectRelayNode returns null for empty nodes`() {
        assertNull(PhoneRelayClient.selectRelayNode(emptyList(), hasStandaloneCredentials = false))
    }

    @Test
    fun `pruneDirectory evicts oldest files when exceeding maxFiles or maxBytes`() {
        val dir = Files.createTempDirectory("prune-test").toFile()
        try {
            val oldest = File(dir, "a.bin").apply {
                writeBytes(ByteArray(100))
                setLastModified(1000L)
            }
            val middle = File(dir, "b.bin").apply {
                writeBytes(ByteArray(100))
                setLastModified(2000L)
            }
            val newest = File(dir, "c.bin").apply {
                writeBytes(ByteArray(100))
                setLastModified(3000L)
            }

            // Exceeds maxFiles (3 > 2) -> evicts oldest
            PhoneRelayClient.pruneDirectory(dir, maxBytes = 1000L, maxFiles = 2)
            assertFalse(oldest.exists())
            assertTrue(middle.exists())
            assertTrue(newest.exists())

            // Exceeds maxBytes (200 > 150) -> evicts middle
            PhoneRelayClient.pruneDirectory(dir, maxBytes = 150L, maxFiles = 10)
            assertFalse(middle.exists())
            assertTrue(newest.exists())
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun `requestAttachmentDeduped sends once for concurrent callers and resolves both`() = runBlocking {
        val pending = ConcurrentHashMap<String, CompletableDeferred<File?>>()
        val sendCount = AtomicInteger(0)
        val expected = File("/tmp/att-1")

        val first = async {
            PhoneRelayClient.requestAttachmentDeduped(
                attachmentGuid = "att-1",
                pending = pending,
                cachedFile = { null },
                sendRequest = {
                    sendCount.incrementAndGet()
                    true
                }
            )
        }
        val second = async {
            PhoneRelayClient.requestAttachmentDeduped(
                attachmentGuid = "att-1",
                pending = pending,
                cachedFile = { null },
                sendRequest = {
                    sendCount.incrementAndGet()
                    true
                }
            )
        }

        while (pending["att-1"] == null) delay(5)
        pending["att-1"]?.complete(expected)

        assertEquals(expected, first.await())
        assertEquals(expected, second.await())
        assertEquals(1, sendCount.get())
        assertTrue(pending.isEmpty())
    }

    @Test
    fun `requestAttachmentDeduped fast-fails immediately when pending deferred completed with null`() = runBlocking {
        val pending = ConcurrentHashMap<String, CompletableDeferred<File?>>()
        val waiter = async {
            PhoneRelayClient.requestAttachmentDeduped(
                attachmentGuid = "att-fail",
                pending = pending,
                cachedFile = { null },
                sendRequest = { true },
                timeoutMs = 10_000L
            )
        }

        while (pending["att-fail"] == null) delay(5)
        pending.remove("att-fail")?.complete(null)

        assertNull(waiter.await())
        assertTrue(pending.isEmpty())
    }

    @Test
    fun `node connection cache reuses positive and negative state within TTL unless forced or invalidated`() = runBlocking {
        var now = 1_000L
        var fetches = 0
        var nextNode: String? = "bt-1"
        val cache = NodeConnectionCache(ttlMs = 15_000L, nowMs = { now })

        // First call fetches and caches positive result
        assertTrue(cache.getOrRefreshConnected(force = false) { fetches++; nextNode })
        assertEquals(1, fetches)

        // Within 15s TTL -> uses cached true without fetching
        now += 5_000L
        nextNode = null
        assertTrue(cache.getOrRefreshConnected(force = false) { fetches++; nextNode })
        assertEquals(1, fetches)

        // Forced check bypasses TTL and caches negative result
        assertFalse(cache.getOrRefreshConnected(force = true) { fetches++; nextNode })
        assertEquals(2, fetches)

        // Negative result is also cached within 15s TTL
        now += 10_000L
        nextNode = "bt-2"
        assertFalse(cache.getOrRefreshConnected(force = false) { fetches++; nextNode })
        assertEquals(2, fetches)

        // After TTL expires, refreshes automatically
        now += 5_000L
        assertTrue(cache.getOrRefreshConnected(force = false) { fetches++; nextNode })
        assertEquals(3, fetches)

        // Explicit invalidation clears cache immediately
        nextNode = null
        cache.invalidate()
        assertFalse(cache.getOrRefreshConnected(force = false) { fetches++; nextNode })
        assertEquals(4, fetches)
    }

    @Test
    fun `buildAnswerCallAudioPayload includes isTelephony flag`() {
        val parsedTrue = JsonParser.parseString(
            String(PhoneRelayClient.buildAnswerCallAudioPayload("cell-1", "Mom", "+15551234567", isTelephony = true))
        ).asJsonObject
        assertEquals("cell-1", parsedTrue.get("callUuid").asString)
        assertEquals("Mom", parsedTrue.get("callerName").asString)
        assertEquals("+15551234567", parsedTrue.get("callerAddress").asString)
        assertTrue(parsedTrue.get("isTelephony").asBoolean)

        val parsedFalse = JsonParser.parseString(
            String(PhoneRelayClient.buildAnswerCallAudioPayload("ft-1", "Alice", null, isTelephony = false))
        ).asJsonObject
        assertEquals("ft-1", parsedFalse.get("callUuid").asString)
        assertFalse(parsedFalse.get("isTelephony").asBoolean)
    }

    @Test
    fun `buildOpenChatPayload includes chatGuid and optional draftText`() {
        val payloadWithoutDraft = JsonParser.parseString(
            String(PhoneRelayClient.buildOpenChatPayload("chat-123"))
        ).asJsonObject
        assertEquals("chat-123", payloadWithoutDraft.get("chatGuid").asString)
        assertNull(payloadWithoutDraft.get("draftText"))

        val payloadWithDraft = JsonParser.parseString(
            String(PhoneRelayClient.buildOpenChatPayload("chat-456", "Draft message to send"))
        ).asJsonObject
        assertEquals("chat-456", payloadWithDraft.get("chatGuid").asString)
        assertEquals("Draft message to send", payloadWithDraft.get("draftText").asString)
    }
}
