package com.wearbubbles

import com.wearbubbles.api.ApiClient
import com.wearbubbles.data.ChatRepository
import com.wearbubbles.data.MessageRepository
import com.wearbubbles.relay.PhoneRelayClient
import com.wearbubbles.socket.SocketManager
import com.wearbubbles.ui.conversations.ConversationListViewModel
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class OptWearDataTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    @Test
    fun `notification reply wait and ceiling stay within broadcast timeout`() {
        assertEquals(5_000L, MessageRepository.NOTIFICATION_REPLY_WAIT_MS)
        assertTrue(MessageRepository.NOTIFICATION_REPLY_CEILING_MS <= 10_000L)
        assertTrue(MessageRepository.NOTIFICATION_REPLY_CEILING_MS > MessageRepository.NOTIFICATION_REPLY_WAIT_MS)
    }

    @Test
    fun `phone relay cache and prune throttle constants are configured`() {
        assertEquals(15_000L, PhoneRelayClient.NODE_CACHE_TTL_MS)
        assertEquals(30_000L, PhoneRelayClient.PRUNE_INTERVAL_MS)
        assertEquals(20, PhoneRelayClient.PRUNE_WRITE_THRESHOLD)
    }

    @Test
    fun `timed out relay send result is marked timedOut without failing`() {
        val result = PhoneRelayClient.orTimedOutResult(
            result = null,
            requestId = "req-x01",
            tempGuid = "temp-x01"
        )
        assertTrue(result.timedOut)
        assertFalse(result.success)
        assertEquals("temp-x01", result.tempGuid)
    }

    @Test
    fun `pruneDirectory evicts oldest files above count or size cap`() {
        val dir = tempFolder.newFolder("avatars")
        val f1 = dir.resolve("a.img").apply { writeBytes(ByteArray(10)); setLastModified(1_000L) }
        val f2 = dir.resolve("b.img").apply { writeBytes(ByteArray(10)); setLastModified(2_000L) }
        val f3 = dir.resolve("c.img").apply { writeBytes(ByteArray(10)); setLastModified(3_000L) }

        PhoneRelayClient.pruneDirectory(dir, maxBytes = 25L, maxFiles = 2)

        assertFalse(f1.exists())
        assertTrue(f2.exists())
        assertTrue(f3.exists())
    }

    @Test
    fun `standalone read receipt gating remains strictly opt-in`() {
        assertTrue(ChatRepository.shouldSendStandaloneReadReceipt(privateMarkChatAsRead = true))
        assertFalse(ChatRepository.shouldSendStandaloneReadReceipt(privateMarkChatAsRead = false))
    }

    @Test
    fun `relayed message paging sentinel and page size match contract`() {
        assertTrue(MessageRepository.hasMoreRelayedMessages(-1))
        assertTrue(MessageRepository.hasMoreRelayedMessages(40))
        assertFalse(MessageRepository.hasMoreRelayedMessages(12))
    }

    @Test
    fun `apiClient custom headers interceptor scopes headers to configured server origin`() {
        assertTrue(ApiClient.okHttpClient.dns === SocketManager.ipv4FirstDns)
        val observedSecrets = mutableListOf<String?>()
        val observedNgrok = mutableListOf<String?>()
        val testClient = ApiClient.okHttpClient.newBuilder()
            .addInterceptor { chain ->
                val req = chain.request()
                observedSecrets.add(req.header("CF-Access-Client-Secret"))
                observedNgrok.add(req.header("ngrok-skip-browser-warning"))
                Response.Builder()
                    .request(req)
                    .protocol(Protocol.HTTP_1_1)
                    .code(200)
                    .message("OK")
                    .body("{}".toResponseBody("application/json".toMediaType()))
                    .build()
            }
            .build()

        ApiClient.reset()
        try {
            ApiClient.configureHeaders(
                "https://my-watch.ngrok-free.app",
                mapOf("CF-Access-Client-Secret" to "top-secret")
            )
            testClient.newCall(Request.Builder().url("https://MY-WATCH.NGROK-FREE.APP/api/v1/ping").build()).execute().close()
            testClient.newCall(Request.Builder().url("https://evil.example.com/avatar.png").build()).execute().close()
            testClient.newCall(Request.Builder().url("http://my-watch.ngrok-free.app/api/v1/ping").build()).execute().close()
            testClient.newCall(Request.Builder().url("https://my-watch.ngrok-free.app:8443/api/v1/ping").build()).execute().close()

            ApiClient.reset()
            testClient.newCall(Request.Builder().url("https://my-watch.ngrok-free.app/api/v1/ping").build()).execute().close()

            assertEquals(listOf("top-secret", null, null, null, null), observedSecrets)
            assertEquals(listOf("true", null, null, null, null), observedNgrok)
        } finally {
            ApiClient.reset()
        }
    }

    @Test
    fun `shouldPrefetchOnLaunch runs only when standalone and unmetered`() {
        assertTrue(ConversationListViewModel.shouldPrefetchOnLaunch(metered = false, phoneConnected = false))
        assertFalse(ConversationListViewModel.shouldPrefetchOnLaunch(metered = true, phoneConnected = false))
        assertFalse(ConversationListViewModel.shouldPrefetchOnLaunch(metered = false, phoneConnected = true))
        assertFalse(ConversationListViewModel.shouldPrefetchOnLaunch(metered = true, phoneConnected = true))
    }
}
