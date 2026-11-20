package com.wearbubbles.ui.messages

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MessageDetailAttachmentUrlTest {

    @Test
    fun `tethered hides direct url when relay has not failed`() {
        assertFalse(
            shouldExposeDirectAttachmentUrl(
                isPhoneConnected = true,
                attachmentGuid = "att-1",
                failedRelayGuids = emptySet(),
                serverUrl = "https://bb.example.com",
                password = "secret"
            )
        )
    }

    @Test
    fun `tethered exposes direct url only after relay failure`() {
        assertTrue(
            shouldExposeDirectAttachmentUrl(
                isPhoneConnected = true,
                attachmentGuid = "att-1",
                failedRelayGuids = setOf("att-1"),
                serverUrl = "https://bb.example.com",
                password = "secret"
            )
        )
        assertFalse(
            shouldExposeDirectAttachmentUrl(
                isPhoneConnected = true,
                attachmentGuid = "att-2",
                failedRelayGuids = setOf("att-1"),
                serverUrl = "https://bb.example.com",
                password = "secret"
            )
        )
    }

    @Test
    fun `untethered exposes direct url when credentials and guid are present`() {
        assertTrue(
            shouldExposeDirectAttachmentUrl(
                isPhoneConnected = false,
                attachmentGuid = "att-1",
                failedRelayGuids = emptySet(),
                serverUrl = "https://bb.example.com",
                password = "secret"
            )
        )
    }

    @Test
    fun `missing guid or credentials never exposes direct url`() {
        assertFalse(
            shouldExposeDirectAttachmentUrl(
                isPhoneConnected = false,
                attachmentGuid = null,
                failedRelayGuids = setOf("att-1"),
                serverUrl = "https://bb.example.com",
                password = "secret"
            )
        )
        assertFalse(
            shouldExposeDirectAttachmentUrl(
                isPhoneConnected = false,
                attachmentGuid = " ",
                failedRelayGuids = emptySet(),
                serverUrl = "https://bb.example.com",
                password = "secret"
            )
        )
        assertFalse(
            shouldExposeDirectAttachmentUrl(
                isPhoneConnected = false,
                attachmentGuid = "att-1",
                failedRelayGuids = setOf("att-1"),
                serverUrl = "",
                password = "secret"
            )
        )
        assertFalse(
            shouldExposeDirectAttachmentUrl(
                isPhoneConnected = false,
                attachmentGuid = "att-1",
                failedRelayGuids = setOf("att-1"),
                serverUrl = "https://bb.example.com",
                password = "  "
            )
        )
    }
}
