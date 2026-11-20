package com.bluebubbles.messaging

import com.bluebubbles.messaging.services.intents.InternalIntentReceiver
import com.bluebubbles.messaging.services.network.HttpService
import com.bluebubbles.messaging.services.notifications.CreateIncomingMessageNotification
import com.bluebubbles.messaging.services.notifications.MediaControllerCallback
import com.bluebubbles.messaging.services.wear.WearSyncManager
import com.bluebubbles.messaging.utils.FilesystemUtils
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class OptPhoneNetTest {

    // --- P-06: InternalIntentReceiver & CreateIncomingMessageNotification ---

    @Test
    fun `matchesMessageNotification requires matching tag and id`() {
        assertTrue(
            InternalIntentReceiver.matchesMessageNotification(
                Constants.newMessageNotificationTag,
                42,
                42
            )
        )
        assertFalse(
            InternalIntentReceiver.matchesMessageNotification(
                Constants.newFaceTimeNotificationTag,
                42,
                42
            )
        )
        assertFalse(
            InternalIntentReceiver.matchesMessageNotification(
                null,
                42,
                42
            )
        )
        assertFalse(
            InternalIntentReceiver.matchesMessageNotification(
                Constants.newMessageNotificationTag,
                42,
                43
            )
        )
    }

    @Test
    fun `resolveNotificationId avoids summary id 0`() {
        assertEquals(7, CreateIncomingMessageNotification.resolveNotificationId(7, "iMessage;-;+1555"))
        val zeroId = CreateIncomingMessageNotification.resolveNotificationId(0, "iMessage;-;+1555")
        val nullId = CreateIncomingMessageNotification.resolveNotificationId(null, "iMessage;-;+1555")
        assertNotEquals(0, zeroId)
        assertTrue(zeroId > 0)
        assertEquals(zeroId, nullId)
    }

    // --- P-07: UnifiedPushReceiver, NotificationListener, FilesystemUtils ---

    @Test
    fun `unifiedPush parsePayload handles malformed json and primitive extras`() {
        assertNull(UnifiedPushReceiver.parsePayload(""))
        assertNull(UnifiedPushReceiver.parsePayload("{not valid json"))
        assertNull(UnifiedPushReceiver.parsePayload("{\"data\":\"missing-type\"}"))
        assertNull(UnifiedPushReceiver.parsePayload("{\"type\":123}"))

        val parsed = UnifiedPushReceiver.parsePayload(
            """{"type":"new-message","count":3,"urgent":true,"nested":{"a":1}}"""
        )
        assertNotNull(parsed)
        val (type, map) = parsed!!
        assertEquals("new-message", type)
        assertEquals(3L, map["count"])
        assertEquals(true, map["urgent"])

        val extras = UnifiedPushReceiver.toTaskerExtras(map).toMap()
        assertEquals("new-message", extras["type"])
        assertEquals(3L, extras["count"])
        assertEquals(true, extras["urgent"])
        assertTrue(extras["nested"] is String)
        assertEquals("net.dinglisch.android.taskerm.BB_EVENT", UnifiedPushReceiver.TASKER_EVENT_ACTION)
    }

    @Test
    fun `computeScaledDimensions caps longest edge at 256px without upscaling`() {
        assertEquals(0 to 0, MediaControllerCallback.computeScaledDimensions(0, 100))
        assertEquals(128 to 128, MediaControllerCallback.computeScaledDimensions(128, 128))
        assertEquals(256 to 128, MediaControllerCallback.computeScaledDimensions(1024, 512))
        assertEquals(128 to 256, MediaControllerCallback.computeScaledDimensions(512, 1024))
        assertEquals(256 to 1, MediaControllerCallback.computeScaledDimensions(5000, 1))
    }

    @Test
    fun `sanitizeCacheFileName blocks path traversal and empty names`() {
        assertNull(FilesystemUtils.sanitizeCacheFileName(null))
        assertNull(FilesystemUtils.sanitizeCacheFileName("   "))
        assertNull(FilesystemUtils.sanitizeCacheFileName(".."))
        assertNull(FilesystemUtils.sanitizeCacheFileName("."))
        assertNull(FilesystemUtils.sanitizeCacheFileName("/"))
        assertEquals("passwd", FilesystemUtils.sanitizeCacheFileName("../../etc/passwd"))
        assertEquals("secret.xml", FilesystemUtils.sanitizeCacheFileName("..\\..\\shared_prefs\\secret.xml"))
        assertEquals("photo.jpg", FilesystemUtils.sanitizeCacheFileName("photo.jpg"))
    }

    // --- P-08: HttpService shared pool & log redaction ---

    @Test
    fun `httpService shares connection pool and redacts guid and password only in logs`() {
        val logs = mutableListOf<String>()
        val clientA = HttpService.buildOkHttpClient(
            timeoutMs = 15000L,
            headersProvider = { mapOf("X-Test" to "1") },
            logger = { logs.add(it) }
        )
        val clientB = HttpService.buildOkHttpClient(
            timeoutMs = 45000L,
            headersProvider = { emptyMap() },
            logger = { logs.add(it) }
        )

        assertSame(HttpService.sharedClient.connectionPool, clientA.connectionPool)
        assertSame(clientA.connectionPool, clientB.connectionPool)
        assertSame(clientA.dispatcher, clientB.dispatcher)
        assertEquals(15000, clientA.connectTimeoutMillis)
        assertEquals(45000, clientB.connectTimeoutMillis)

        var observedOutgoingUrl: String? = null
        val mockedClient = clientA.newBuilder()
            .addInterceptor { chain ->
                val req = chain.request()
                observedOutgoingUrl = req.url.toString()
                assertEquals("super-secret-guid", req.url.queryParameter("guid"))
                assertEquals("pw-123", req.url.queryParameter("password"))
                assertEquals("keep", req.url.queryParameter("other"))
                Response.Builder()
                    .request(req)
                    .protocol(Protocol.HTTP_1_1)
                    .code(200)
                    .message("OK")
                    .body("{}".toResponseBody("application/json".toMediaType()))
                    .build()
            }
            .build()

        val request = Request.Builder()
            .url("https://bb.example.com/api/v1/ping?guid=super-secret-guid&password=pw-123&other=keep")
            .build()
        mockedClient.newCall(request).execute().close()

        assertTrue(observedOutgoingUrl!!.contains("guid=super-secret-guid"))
        assertTrue(logs.isNotEmpty())
        assertTrue(logs.none { it.contains("super-secret-guid") || it.contains("pw-123") })
        assertTrue(logs.any { it.contains("guid=REDACTED") && it.contains("password=REDACTED") && it.contains("other=keep") })

        val redacted = HttpService.redactUrl("https://bb.example.com/api/v1/ping?GUID=abc&other=1".toHttpUrl())
        assertFalse(redacted.contains("abc"))
        assertTrue(redacted.contains("REDACTED"))
        assertTrue(redacted.contains("other=1"))
    }

    @Test
    fun `push allowlist accepts remote events and rejects local-only or unknown types`() {
        assertTrue(UnifiedPushReceiver.isAllowedPushType("new-message"))
        assertTrue(UnifiedPushReceiver.isAllowedPushType("updated-message"))
        assertTrue(UnifiedPushReceiver.isAllowedPushType("chat-read-status-changed"))
        assertTrue(UnifiedPushReceiver.isAllowedPushType("incoming-facetime"))
        assertTrue(UnifiedPushReceiver.isAllowedPushType("ft-call-status-changed"))

        assertFalse(UnifiedPushReceiver.isAllowedPushType(null))
        assertFalse(UnifiedPushReceiver.isAllowedPushType(""))
        assertFalse(UnifiedPushReceiver.isAllowedPushType("NewServerUrl"))
        assertFalse(UnifiedPushReceiver.isAllowedPushType("ReplyChat"))
        assertFalse(UnifiedPushReceiver.isAllowedPushType("MarkChatRead"))
        assertFalse(UnifiedPushReceiver.isAllowedPushType("MuteChat"))
        assertFalse(UnifiedPushReceiver.isAllowedPushType("unifiedpush-settings"))
        assertFalse(UnifiedPushReceiver.isAllowedPushType("socket-event"))
        assertFalse(UnifiedPushReceiver.isAllowedPushType("answer-facetime"))
        assertFalse(UnifiedPushReceiver.isAllowedPushType("arbitrary-handler"))
    }

    @Test
    fun `wearSyncManager custom headers interceptor scopes headers to configured server origin`() {
        val observedHeaders = mutableListOf<String?>()
        val client = WearSyncManager.buildOkHttpClient(
            timeoutMs = 15_000L,
            serverOrigin = "https://bb.example.com:8443",
            headersProvider = { mapOf("CF-Access-Client-Secret" to "top-secret") },
        ).newBuilder()
            .addInterceptor { chain ->
                val req = chain.request()
                observedHeaders.add(req.header("CF-Access-Client-Secret"))
                Response.Builder()
                    .request(req)
                    .protocol(Protocol.HTTP_1_1)
                    .code(200)
                    .message("OK")
                    .body("{}".toResponseBody("application/json".toMediaType()))
                    .build()
            }
            .build()

        client.newCall(Request.Builder().url("https://BB.EXAMPLE.COM:8443/api/v1/ping").build()).execute().close()
        client.newCall(Request.Builder().url("https://evil.example.com:8443/img.png").build()).execute().close()
        client.newCall(Request.Builder().url("http://bb.example.com:8443/api/v1/ping").build()).execute().close()
        client.newCall(Request.Builder().url("https://bb.example.com:9443/api/v1/ping").build()).execute().close()

        assertEquals(listOf("top-secret", null, null, null), observedHeaders)

        val unconfiguredClient = WearSyncManager.buildOkHttpClient(
            timeoutMs = 15_000L,
            serverOrigin = "",
            headersProvider = { mapOf("CF-Access-Client-Secret" to "top-secret") },
        )
        assertFalse(WearSyncManager.shouldAttachCustomHeaders("https://bb.example.com/ping".toHttpUrl(), null))
        assertNotNull(unconfiguredClient)
    }
}
