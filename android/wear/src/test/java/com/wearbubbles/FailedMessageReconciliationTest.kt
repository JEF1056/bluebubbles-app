package com.wearbubbles

import com.google.gson.Gson
import com.wearbubbles.api.dto.MessageDto
import com.wearbubbles.api.dto.MessageRelayDto
import com.wearbubbles.db.MessageDao
import com.wearbubbles.db.entities.MessageEntity
import com.wearbubbles.relay.PhoneRelayClient
import com.wearbubbles.relay.SendResultPayload
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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

        override suspend fun markSendFailed(guid: String) {
            rows[guid]?.let { rows[guid] = it.copy(sendFailed = true) }
            publish()
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
