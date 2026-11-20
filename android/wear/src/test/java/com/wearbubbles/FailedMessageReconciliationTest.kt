package com.wearbubbles

import com.google.gson.Gson
import com.wearbubbles.api.dto.ChatDto
import com.wearbubbles.api.dto.MessageDto
import com.wearbubbles.api.dto.MessageRelayDto
import com.wearbubbles.api.dto.TapbackUtils
import com.wearbubbles.data.MessageRepository
import com.wearbubbles.db.MessageDao
import com.wearbubbles.db.entities.MessageEntity
import com.wearbubbles.relay.PhoneRelayClient
import com.wearbubbles.relay.SendResultPayload
import com.wearbubbles.socket.SocketManager
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FailedMessageReconciliationTest {

    private val chat = "iMessage;-;+15551234567"

    private fun msg(
        guid: String,
        text: String? = "Hello",
        isFromMe: Boolean = true,
        dateCreated: Long = 1_000_000L,
        sendFailed: Boolean = false,
        chatGuid: String = chat,
        attachmentMimeType: String? = null,
        associatedMessageType: String? = null
    ) = MessageEntity(
        guid = guid,
        chatGuid = chatGuid,
        text = text,
        isFromMe = isFromMe,
        dateCreated = dateCreated,
        handleAddress = null,
        attachmentMimeType = attachmentMimeType,
        associatedMessageType = associatedMessageType,
        sendFailed = sendFailed
    )

    @Test
    fun `exact tempGuid reconciles failed temp row without touching other failed rows`() {
        val local = listOf(
            msg("temp-1", text = "Hello", dateCreated = 1_000_000L, sendFailed = true),
            msg("temp-2", text = "Hello", dateCreated = 1_005_000L, sendFailed = true)
        )
        val real = msg("real-1", text = "Hello", dateCreated = 1_500_000L)

        val matched = MessageDao.findReconciledTempGuids(local, listOf(real to "temp-1"))
        assertEquals(setOf("temp-1"), matched)
    }

    @Test
    fun `sync fallback reconciles matching text, audio, and sent-temp rows within window`() {
        val local = listOf(
            msg("temp-text", text = "On my way", dateCreated = 1_000_000L, sendFailed = true),
            msg("temp-audio-1", text = null, dateCreated = 1_020_000L, sendFailed = true, attachmentMimeType = "audio/mp4"),
            msg("sent-temp-2", text = "Done", dateCreated = 1_040_000L, sendFailed = false),
            msg("temp-unconfirmed", text = "Never sent", dateCreated = 1_050_000L, sendFailed = true)
        )
        val incoming = listOf(
            msg("real-text", text = "On my way", dateCreated = 1_135_000L) to null,
            msg("real-audio", text = null, dateCreated = 1_030_000L, attachmentMimeType = "audio/x-m4a") to null,
            msg("real-done", text = "Done", dateCreated = 1_042_000L) to null
        )

        val matched = MessageDao.findReconciledTempGuids(local, incoming)
        assertEquals(setOf("temp-text", "temp-audio-1", "sent-temp-2"), matched)
    }

    @Test
    fun `does not falsely clear newly failed message using older already-sent message`() {
        val failedLater = msg("temp-new", text = "ok", dateCreated = 2_000_000L, sendFailed = true)
        val sentEarlier = msg("real-old", text = "ok", dateCreated = 1_900_000L)

        val matched = MessageDao.findReconciledTempGuids(listOf(failedLater), listOf(sentEarlier to null))
        assertTrue(matched.isEmpty())
    }

    @Test
    fun `matches one-to-one picking closest timestamp`() {
        val local = listOf(
            msg("temp-far", text = "ok", dateCreated = 1_000_000L, sendFailed = true),
            msg("temp-near", text = "ok", dateCreated = 1_050_000L, sendFailed = true)
        )
        val real = msg("real-1", text = "ok", dateCreated = 1_052_000L)

        val matched = MessageDao.findReconciledTempGuids(local, listOf(real to null))
        assertEquals(setOf("temp-near"), matched)
    }

    @Test
    fun `ignores incoming peer messages and temp reactions`() {
        val local = listOf(
            msg("temp-1", text = "Hey", dateCreated = 1_000_000L, sendFailed = true),
            msg("temp-react-1", text = null, dateCreated = 1_000_000L, associatedMessageType = "2000")
        )
        val incoming = listOf(
            msg("real-peer", text = "Hey", isFromMe = false, dateCreated = 1_001_000L) to null
        )

        val matched = MessageDao.findReconciledTempGuids(local, incoming)
        assertTrue(matched.isEmpty())
        assertFalse(MessageDao.isTempPlaceholderGuid("temp-react-1"))
        assertTrue(MessageDao.isTempPlaceholderGuid("temp-1"))
        assertTrue(MessageDao.isTempPlaceholderGuid("sent-temp-1"))
    }

    @Test
    fun `late orphaned send result reconciles Room for success and failure`() = runBlocking {
        val dao = FakeMessageDao()
        dao.upsert(msg("temp-ok", text = "Hi", dateCreated = 1000L, sendFailed = true))
        dao.upsert(msg("temp-ok-nomsg", text = "Bye", dateCreated = 1001L, sendFailed = false))
        dao.upsert(msg("temp-fail", text = "Oops", dateCreated = 1002L, sendFailed = false))

        PhoneRelayClient.reconcileOrphanedSendResult(
            SendResultPayload(
                requestId = "req-1",
                tempGuid = "temp-ok",
                success = true,
                message = MessageRelayDto(
                    guid = "real-ok",
                    chatGuid = chat,
                    text = "Hi",
                    isFromMe = true,
                    dateCreated = 1005L
                )
            ),
            dao
        )
        PhoneRelayClient.reconcileOrphanedSendResult(
            SendResultPayload(requestId = "req-2", tempGuid = "temp-ok-nomsg", success = true, message = null),
            dao
        )
        PhoneRelayClient.reconcileOrphanedSendResult(
            SendResultPayload(requestId = "req-3", tempGuid = "temp-fail", success = false, error = "boom"),
            dao
        )

        assertFalse(dao.rows.containsKey("temp-ok"))
        assertTrue(dao.rows.containsKey("real-ok"))
        assertFalse(dao.rows["real-ok"]!!.sendFailed)
        assertFalse(dao.rows.containsKey("temp-ok-nomsg"))
        assertTrue(dao.rows["temp-fail"]!!.sendFailed)
    }

    @Test
    fun `upsertAndReconcileBatch removes confirmed temp rows and marks stale pending failed`() = runBlocking {
        val dao = FakeMessageDao()
        dao.upsert(msg("temp-confirmed", text = "Hello", dateCreated = 1_000_000L, sendFailed = true))
        dao.upsert(msg("temp-stale", text = "Stuck", dateCreated = 800_000L, sendFailed = false))
        dao.upsert(msg("temp-active", text = "Just sent", dateCreated = 1_050_000L, sendFailed = false))

        val incoming = listOf(msg("real-hello", text = "Hello", dateCreated = 1_002_000L))
        dao.upsertAndReconcileBatch(chat, incoming, stalePendingCutoffMs = 950_000L)

        assertFalse(dao.rows.containsKey("temp-confirmed"))
        assertTrue(dao.rows.containsKey("real-hello"))
        assertTrue(dao.rows["temp-stale"]!!.sendFailed)
        assertFalse(dao.rows["temp-active"]!!.sendFailed)
    }

    @Test
    fun `dtos deserialize tempGuid from socket and relay json`() {
        val gson = Gson()
        val serverDto = gson.fromJson(
            """{"guid":"real-1","tempGuid":"temp-1","text":"hi","isFromMe":true,"dateCreated":100}""",
            MessageDto::class.java
        )
        val relayDto = gson.fromJson(
            """{"guid":"real-1","chatGuid":"$chat","tempGuid":"temp-1","text":"hi","isFromMe":true,"dateCreated":100}""",
            MessageRelayDto::class.java
        )
        assertEquals("temp-1", serverDto.tempGuid)
        assertEquals("temp-1", relayDto.tempGuid)
    }

    @Test
    fun `temp-react row reconciles on real tapback despite clock skew so removal leaves no ghost badge`() = runBlocking {
        val dao = FakeMessageDao()
        val targetGuid = "target-msg-1"
        // Watch clock is 20s ahead of Mac server clock.
        dao.upsert(
            MessageEntity(
                guid = "temp-react-add",
                chatGuid = chat,
                text = null,
                isFromMe = true,
                dateCreated = 2_020_000L,
                handleAddress = null,
                associatedMessageGuid = "p:0/$targetGuid",
                associatedMessageType = "2000"
            )
        )

        val realAdd = MessageEntity(
            guid = "real-react-add",
            chatGuid = chat,
            text = null,
            isFromMe = true,
            dateCreated = 2_000_000L,
            handleAddress = null,
            associatedMessageGuid = "p:0/$targetGuid",
            associatedMessageType = "2000"
        )
        dao.upsertAndReconcile(realAdd)
        assertFalse(dao.rows.containsKey("temp-react-add"))
        assertTrue(dao.rows.containsKey("real-react-add"))

        // Removing the tapback at Mac time 2_010_000L (earlier than watch's 2_020_000L) must yield 0 badges.
        val realRemove = MessageEntity(
            guid = "real-react-remove",
            chatGuid = chat,
            text = null,
            isFromMe = true,
            dateCreated = 2_010_000L,
            handleAddress = null,
            associatedMessageGuid = "p:0/$targetGuid",
            associatedMessageType = "3000"
        )
        dao.upsertAndReconcile(realRemove)

        val badges = TapbackUtils.computeReactions(dao.rows.values.toList())[targetGuid].orEmpty()
        assertTrue(badges.isEmpty())
    }

    @Test
    fun `upsertAndReconcileBatch cleans matching and stale temp-react rows`() = runBlocking {
        val dao = FakeMessageDao()
        val targetGuid = "target-msg-2"
        dao.upsert(
            MessageEntity(
                guid = "temp-react-match",
                chatGuid = chat,
                text = null,
                isFromMe = true,
                dateCreated = 1_000_000L,
                handleAddress = null,
                associatedMessageGuid = "p:0/$targetGuid",
                associatedMessageType = "2001"
            )
        )
        dao.upsert(
            MessageEntity(
                guid = "temp-react-stale",
                chatGuid = chat,
                text = null,
                isFromMe = true,
                dateCreated = 500_000L,
                handleAddress = null,
                associatedMessageGuid = "p:0/$targetGuid",
                associatedMessageType = "2002"
            )
        )

        val incoming = listOf(
            MessageEntity(
                guid = "real-like",
                chatGuid = chat,
                text = null,
                isFromMe = true,
                dateCreated = 1_003_000L,
                handleAddress = null,
                associatedMessageGuid = "bp:0/$targetGuid",
                associatedMessageType = "2001"
            )
        )
        dao.upsertAndReconcileBatch(chat, incoming, stalePendingCutoffMs = 800_000L)

        assertFalse(dao.rows.containsKey("temp-react-match"))
        assertFalse(dao.rows.containsKey("temp-react-stale"))
        assertTrue(dao.rows.containsKey("real-like"))
    }

    @Test
    fun `late orphaned temp-react failure deletes temp row instead of marking sendFailed`() = runBlocking {
        val dao = FakeMessageDao()
        dao.upsert(
            MessageEntity(
                guid = "temp-react-fail",
                chatGuid = chat,
                text = null,
                isFromMe = true,
                dateCreated = 1_000_000L,
                handleAddress = null,
                associatedMessageGuid = "p:0/msg-1",
                associatedMessageType = "2000"
            )
        )

        PhoneRelayClient.reconcileOrphanedSendResult(
            SendResultPayload(requestId = "req-react", tempGuid = "temp-react-fail", success = false, error = "timeout"),
            dao
        )

        assertFalse(dao.rows.containsKey("temp-react-fail"))
    }

    @Test
    fun `notification reply wait window fits inside goAsync and distinguishes timeout from failure`() {
        assertTrue(MessageRepository.NOTIFICATION_REPLY_WAIT_MS in 5_000L..8_500L)

        val timedOut = PhoneRelayClient.orTimedOutResult(
            result = null,
            requestId = "req-notif",
            tempGuid = "temp-notif"
        )
        assertTrue(timedOut.timedOut)
        assertFalse(timedOut.success)

        val serverFailure = SendResultPayload(
            requestId = "req-notif-2",
            tempGuid = "temp-notif-2",
            success = false,
            error = "HTTP 500"
        )
        assertFalse(serverFailure.timedOut)
    }

    @Test
    fun `extractDmRecipientIfNewChatError matches DM missing-chat errors and skips group or unrelated errors`() {
        assertEquals(
            "+15551234567",
            MessageRepository.extractDmRecipientIfNewChatError("iMessage;-;+15551234567", 404, null)
        )
        assertEquals(
            "+15551234567",
            MessageRepository.extractDmRecipientIfNewChatError(
                "SMS;-;+15551234567",
                400,
                """{"status":400,"error":{"message":"Chat does not exist"}}"""
            )
        )
        assertEquals(
            "alice@example.com",
            MessageRepository.extractDmRecipientIfNewChatError(
                "iMessage;-;alice@example.com",
                500,
                "Chat does not exist"
            )
        )
        assertNull(
            MessageRepository.extractDmRecipientIfNewChatError("iMessage;+;chat123456", 404, "Chat does not exist")
        )
        assertNull(
            MessageRepository.extractDmRecipientIfNewChatError("iMessage;-;+15551234567", 401, "Unauthorized")
        )
        assertNull(
            MessageRepository.extractDmRecipientIfNewChatError("iMessage;-;+15551234567", 400, "Message text blank")
        )
        assertNull(
            MessageRepository.extractDmRecipientIfNewChatError("iMessage;-;", 404, "Chat does not exist")
        )
    }

    @Test
    fun `hasMoreRelayedMessages treats timeout sentinel as maybe more and checks 40-page threshold`() {
        assertTrue(MessageRepository.hasMoreRelayedMessages(-1))
        assertFalse(MessageRepository.hasMoreRelayedMessages(0))
        assertFalse(MessageRepository.hasMoreRelayedMessages(39))
        assertTrue(MessageRepository.hasMoreRelayedMessages(40))
    }

    @Test
    fun `chat dto deserializes messages list from chat new response`() {
        val dto = Gson().fromJson(
            """{"guid":"SMS;-;+15551234567","chatIdentifier":"+15551234567","messages":[{"guid":"real-first","text":"Hey","isFromMe":true,"dateCreated":12345}]}""",
            ChatDto::class.java
        )
        assertEquals("SMS;-;+15551234567", dto.guid)
        assertEquals(1, dto.messages?.size)
        assertEquals("real-first", dto.messages?.firstOrNull()?.guid)
    }

    @Test
    fun `socket message-send-error payload parses and marks matching local row failed without failing unknown guids`() = runBlocking {
        val payload =
            """{"guid":"srv-err-1","tempGuid":"temp-err-1","text":"hi","isFromMe":true,"dateCreated":1000,"chats":[{"guid":"$chat"}]}"""
        val parsed = SocketManager.parseMessageDto(payload)
        assertEquals("srv-err-1", parsed?.guid)
        assertEquals("temp-err-1", parsed?.tempGuid)

        val wrappedPayload =
            """{"data":{"guid":"srv-err-2","tempGuid":"temp-err-2","text":"hi2","isFromMe":true,"dateCreated":1001}}"""
        val parsedWrapped = SocketManager.parseMessageDto(wrappedPayload)
        assertEquals("srv-err-2", parsedWrapped?.guid)
        assertEquals("temp-err-2", parsedWrapped?.tempGuid)

        val dao = FakeMessageDao()
        dao.upsert(msg("sent-temp-err-1", text = "hi", dateCreated = 1000L, sendFailed = false))
        assertTrue(dao.markSendFailedFirstMatch(listOf("temp-err-1", "sent-temp-err-1", "srv-err-1")))
        assertTrue(dao.rows["sent-temp-err-1"]?.sendFailed == true)

        assertFalse(dao.markSendFailedFirstMatch(listOf("other-device-temp", "other-device-srv")))
    }

    private class FakeMessageDao : MessageDao {
        val rows = linkedMapOf<String, MessageEntity>()
        private val flow = MutableStateFlow<List<MessageEntity>>(emptyList())

        private fun publish() {
            flow.value = rows.values.sortedBy { it.dateCreated }
        }

        override fun getMessagesForChat(chatGuid: String): Flow<List<MessageEntity>> =
            flow.map { list -> list.filter { it.chatGuid == chatGuid } }

        override suspend fun upsertAll(messages: List<MessageEntity>) {
            messages.forEach { rows[it.guid] = it }
            publish()
        }

        override suspend fun upsert(message: MessageEntity) {
            rows[message.guid] = message
            publish()
        }

        override suspend fun getOldestMessageDate(chatGuid: String): Long? =
            rows.values.filter { it.chatGuid == chatGuid }.minOfOrNull { it.dateCreated }

        override suspend fun getRecentImageMessages(limit: Int): List<MessageEntity> = emptyList()

        override suspend fun getPendingOrFailedForChat(chatGuid: String): List<MessageEntity> =
            rows.values.filter {
                it.chatGuid == chatGuid &&
                    (it.sendFailed || it.guid.startsWith("temp-") || it.guid.startsWith("sent-temp-"))
            }

        override suspend fun existsByGuid(guid: String): Boolean = rows.containsKey(guid)

        override suspend fun countForChat(chatGuid: String): Int =
            rows.values.count { it.chatGuid == chatGuid }

        override suspend fun deleteByGuid(guid: String) {
            rows.remove(guid)
            publish()
        }

        override suspend fun deleteFailedForChat(chatGuid: String) {
            rows.entries.removeIf { it.value.chatGuid == chatGuid && it.value.sendFailed }
            publish()
        }

        override suspend fun deleteMessagesForChat(chatGuid: String) {
            rows.entries.removeIf { it.value.chatGuid == chatGuid }
            publish()
        }

        override suspend fun pruneOld() = Unit

        override suspend fun markSendFailed(guid: String): Int {
            val existing = rows[guid] ?: return 0
            rows[guid] = existing.copy(sendFailed = true)
            publish()
            return 1
        }

        override suspend fun markStalePendingFailed(chatGuid: String, olderThanMs: Long) {
            rows.entries.forEach { (guid, entity) ->
                if (entity.chatGuid == chatGuid &&
                    !entity.sendFailed &&
                    guid.startsWith("temp-") &&
                    !guid.startsWith("temp-react-") &&
                    entity.dateCreated < olderThanMs
                ) {
                    rows[guid] = entity.copy(sendFailed = true)
                }
            }
            publish()
        }
    }
}
