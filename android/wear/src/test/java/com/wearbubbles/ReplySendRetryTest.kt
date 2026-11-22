package com.wearbubbles

import com.wearbubbles.worker.shouldRetrySend
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import retrofit2.HttpException
import retrofit2.Response
import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLHandshakeException

class ReplySendRetryTest {

    @Test
    fun `shouldRetrySend retries transient pre-request network failures under attempt cap`() {
        assertTrue(shouldRetrySend(UnknownHostException("unable to resolve host"), 0))
        assertTrue(shouldRetrySend(UnknownHostException("unable to resolve host"), 3))
        assertTrue(shouldRetrySend(ConnectException("failed to connect"), 0))
        assertTrue(shouldRetrySend(NoRouteToHostException("no route to host"), 1))
        assertTrue(shouldRetrySend(SSLHandshakeException("handshake failed"), 2))
        assertTrue(shouldRetrySend(SocketTimeoutException("connect timed out"), 0))
        assertTrue(shouldRetrySend(SocketTimeoutException("Failed to connect to /1.2.3.4:443"), 1))
        assertTrue(shouldRetrySend(RuntimeException("wrapped", UnknownHostException("dns")), 0))
    }

    @Test
    fun `shouldRetrySend does not retry read timeouts HTTP errors or attempt 4 and above`() {
        // Read timeouts and HTTP errors risk double-sending if the server already processed the request.
        assertFalse(shouldRetrySend(SocketTimeoutException("timeout"), 0))
        assertFalse(shouldRetrySend(SocketTimeoutException("Read timed out"), 0))
        assertFalse(shouldRetrySend(InterruptedIOException("timeout"), 0))

        val http500 = HttpException(Response.error<Any>(500, "err".toResponseBody(null)))
        assertFalse(shouldRetrySend(http500, 0))
        assertFalse(shouldRetrySend(IllegalStateException("Relay send failed"), 0))
        assertFalse(shouldRetrySend(null, 0))

        // Attempt cap (>= 4) stops retrying even for transient errors.
        assertFalse(shouldRetrySend(UnknownHostException("dns"), 4))
        assertFalse(shouldRetrySend(ConnectException("refused"), 5))
    }
}
