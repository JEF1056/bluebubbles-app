package com.bluebubbles.messaging.services.wear

import org.junit.Assert.assertEquals
import org.junit.Test

class WearReadReceiptGatingTest {

    @Test
    fun `watchMarkReadWorkerArgs delegates to Dart with privateMark enabled`() {
        val args = WearSyncManager.watchMarkReadWorkerArgs("iMessage;-;+15551234567")
        assertEquals("iMessage;-;+15551234567", args["chatGuid"])
        assertEquals(true, args["privateMark"])
    }
}
