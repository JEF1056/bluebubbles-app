package com.bluebubbles.messaging.services

import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.common.StandardMethodCodec
import org.junit.Assert.assertTrue
import org.junit.Test

class MethodResultErrorDetailsTest {

    @Test(expected = IllegalArgumentException::class)
    fun `StandardMessageCodec rejects raw Exception as errorDetails`() {
        StandardMessageCodec.INSTANCE.encodeMessage(IllegalStateException("not allowed"))
    }

    @Test
    fun `StandardMethodCodec accepts stackTraceToString as errorDetails`() {
        val err = IllegalStateException("not allowed")
        val buffer = StandardMethodCodec.INSTANCE.encodeErrorEnvelope(
            "START_FOREGROUND_SERVICE_ERROR",
            err.message,
            err.stackTraceToString(),
        )
        assertTrue(buffer.position() > 0)
    }
}
