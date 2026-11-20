package com.wearbubbles

import com.wearbubbles.data.NotificationReplyResult
import com.wearbubbles.data.persistOptimisticOutgoing
import com.wearbubbles.data.shouldRefreshOnResume
import com.wearbubbles.db.ChatDao
import com.wearbubbles.db.MessageDao
import com.wearbubbles.db.entities.ChatEntity
import com.wearbubbles.db.entities.MessageEntity
import com.wearbubbles.ui.messages.shouldAutoScrollOnMessageUpdate
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationReplyAndSyncTest {

    @Test
    fun `persistOptimisticOutgoing writes temp message and updates chat preview before network send`() = runBlocking {
        val chatGuid = "iMessage;-;+15551234567"
        val messageDao = FakeMessageDao()
        val chatDao = FakeChatDao(
            listOf(
                ChatEntity(
                    guid = chatGuid,
                    chatIdentifier = "+15551234567",
                    displayName = "Alice",
                    participantAddresses = "+15551234567",
                    lastMessageText = "Are you free?",
                    lastMessageDate = 1_000L,
                    lastMessageIsFromMe = false,
                    hasUnreadMessage = true
                )
            )
        )

        val temp = persistOptimisticOutgoing(
            messageDao = messageDao,
            chatDao = chatDao,
            chatGuid = chatGuid,
            text = "On my way!",
            dateCreated = 2_000L
        )

        assertTrue(MessageDao.isTempPlaceholderGuid(temp.guid))
        assertEquals(listOf(temp), messageDao.snapshot(chatGuid))
        val updatedChat = chatDao.getChat(chatGuid)
        assertNotNull(updatedChat)
        assertEquals("On my way!", updatedChat!!.lastMessageText)
        assertEquals(2_000L, updatedChat.lastMessageDate)
        assertTrue(updatedChat.lastMessageIsFromMe)
        assertFalse(updatedChat.hasUnreadMessage)
    }

    @Test
    fun `worker handoff reuses existingTempGuid and reconciles cleanly without duplicates`() = runBlocking {
        val chatGuid = "iMessage;-;+15551234567"
        val messageDao = FakeMessageDao()
        val chatDao = FakeChatDao()

        val initialTemp = persistOptimisticOutgoing(
            messageDao = messageDao,
            chatDao = chatDao,
            chatGuid = chatGuid,
            text = "Heading home",
            dateCreated = 2_000L
        )
        val workerHandoff = NotificationReplyResult.NeedsStandaloneWorker(initialTemp.guid)
        assertEquals(initialTemp.guid, workerHandoff.tempGuid)

        val reusedTemp = persistOptimisticOutgoing(
            messageDao = messageDao,
            chatDao = chatDao,
            chatGuid = chatGuid,
            text = "Heading home",
            dateCreated = 2_500L,
            existingTempGuid = workerHandoff.tempGuid
        )
        assertEquals(initialTemp.guid, reusedTemp.guid)
        assertEquals(1, messageDao.snapshot(chatGuid).size)

        val realMessage = reusedTemp.copy(guid = "p:12345", dateCreated = 2_600L)
        messageDao.replaceTempMessage(reusedTemp.guid, realMessage)

        val finalRows = messageDao.snapshot(chatGuid)
        assertEquals(1, finalRows.size)
        assertEquals("p:12345", finalRows.single().guid)
        assertFalse(MessageDao.isTempPlaceholderGuid(finalRows.single().guid))
    }

    @Test
    fun `shouldRefreshOnResume refreshes after pause and skips duplicate initial or active refreshes`() {
        // Initial ON_RESUME immediately after init() must not double-refresh.
        assertFalse(
            shouldRefreshOnResume(
                isCurrentlyRefreshing = false,
                wasPaused = false,
                lastRefreshStartedAtMs = 10_000L,
                nowMs = 10_050L,
                minIntervalMs = 2_000L
            )
        )
        // Returning from background/pause always triggers a refresh when idle, even quickly.
        assertTrue(
            shouldRefreshOnResume(
                isCurrentlyRefreshing = false,
                wasPaused = true,
                lastRefreshStartedAtMs = 10_000L,
                nowMs = 10_300L,
                minIntervalMs = 2_000L
            )
        )
        // Never overlap an in-flight refresh.
        assertFalse(
            shouldRefreshOnResume(
                isCurrentlyRefreshing = true,
                wasPaused = true,
                lastRefreshStartedAtMs = 10_000L,
                nowMs = 20_000L,
                minIntervalMs = 2_000L
            )
        )
        // After cooldown elapses, resume triggers refresh even without pause.
        assertTrue(
            shouldRefreshOnResume(
                isCurrentlyRefreshing = false,
                wasPaused = false,
                lastRefreshStartedAtMs = 10_000L,
                nowMs = 12_500L,
                minIntervalMs = 2_000L
            )
        )
    }

    @Test
    fun `shouldAutoScrollOnMessageUpdate prevents scroll jumps during temp reconciliation and reading history`() {
        // Initial load always scrolls to latest.
        assertTrue(
            shouldAutoScrollOnMessageUpdate(
                previousLatestGuid = null,
                newLatestGuid = "msg-10",
                previousCount = 0,
                newCount = 10,
                newLatestIsFromMe = false,
                isNearBottom = false
            )
        )
        // Optimistic temp-* reconciling to real GUID at same count must not jump.
        assertFalse(
            shouldAutoScrollOnMessageUpdate(
                previousLatestGuid = "temp-abc",
                newLatestGuid = "p:real-123",
                previousCount = 11,
                newCount = 11,
                newLatestIsFromMe = true,
                isNearBottom = false
            )
        )
        // Background sync bringing incoming message while user is reading older history must not yank.
        assertFalse(
            shouldAutoScrollOnMessageUpdate(
                previousLatestGuid = "msg-10",
                newLatestGuid = "msg-11",
                previousCount = 10,
                newCount = 11,
                newLatestIsFromMe = false,
                isNearBottom = false
            )
        )
        // New incoming message while user is near the bottom scrolls smoothly.
        assertTrue(
            shouldAutoScrollOnMessageUpdate(
                previousLatestGuid = "msg-10",
                newLatestGuid = "msg-11",
                previousCount = 10,
                newCount = 11,
                newLatestIsFromMe = false,
                isNearBottom = true
            )
        )
        // User sending a new message scrolls even if they had scrolled up.
        assertTrue(
            shouldAutoScrollOnMessageUpdate(
                previousLatestGuid = "msg-10",
                newLatestGuid = "temp-new",
                previousCount = 10,
                newCount = 11,
                newLatestIsFromMe = true,
                isNearBottom = false
            )
        )
        // Paginating older messages via loadMore() keeps latestGuid unchanged and must never yank to bottom.
        assertFalse(
            shouldAutoScrollOnMessageUpdate(
                previousLatestGuid = "msg-10",
                newLatestGuid = "msg-10",
                previousCount = 10,
                newCount = 30,
                newLatestIsFromMe = true,
                isNearBottom = false
            )
        )
        assertFalse(
            shouldAutoScrollOnMessageUpdate(
                previousLatestGuid = "msg-10",
                newLatestGuid = "msg-10",
                previousCount = 10,
                newCount = 30,
                newLatestIsFromMe = false,
                isNearBottom = true
            )
        )
    }

    private class FakeMessageDao : MessageDao {
        private val rows = linkedMapOf<String, MessageEntity>()
        private val flow = MutableStateFlow<List<MessageEntity>>(emptyList())

        private fun publish() {
            flow.value = rows.values.sortedBy { it.dateCreated }
        }

        fun snapshot(chatGuid: String): List<MessageEntity> =
            flow.value.filter { it.chatGuid == chatGuid }

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
                it.chatGuid == chatGuid && (it.sendFailed || it.guid.startsWith("temp-") || it.guid.startsWith("sent-temp-"))
            }

        override suspend fun existsByGuid(guid: String): Boolean = rows.containsKey(guid)

        override suspend fun countForChat(chatGuid: String): Int =
            rows.values.count { it.chatGuid == chatGuid }

        override suspend fun deleteByGuid(guid: String) {
            rows.remove(guid)
            publish()
        }

        override suspend fun deleteFailedForChat(chatGuid: String) {
            rows.values.removeAll { it.chatGuid == chatGuid && it.sendFailed }
            publish()
        }

        override suspend fun deleteMessagesForChat(chatGuid: String) {
            rows.values.removeAll { it.chatGuid == chatGuid }
            publish()
        }

        override suspend fun pruneOld() = Unit

        override suspend fun markSendFailed(guid: String): Int {
            val existing = rows[guid] ?: return 0
            rows[guid] = existing.copy(sendFailed = true)
            publish()
            return 1
        }

        override suspend fun markStalePendingFailed(chatGuid: String, olderThanMs: Long) = Unit
    }

    private class FakeChatDao(initial: List<ChatEntity> = emptyList()) : ChatDao {
        private val chats = linkedMapOf<String, ChatEntity>().apply {
            initial.forEach { put(it.guid, it) }
        }
        private val flow = MutableStateFlow(chats.values.toList())

        private fun publish() {
            flow.value = chats.values.toList()
        }

        override fun getAllChats(): Flow<List<ChatEntity>> = flow

        override suspend fun getAllChatsOnce(): List<ChatEntity> = chats.values.toList()

        override suspend fun getChat(guid: String): ChatEntity? = chats[guid]

        override suspend fun upsertAll(chats: List<ChatEntity>) {
            chats.forEach { this.chats[it.guid] = it }
            publish()
        }

        override suspend fun upsert(chat: ChatEntity) {
            chats[chat.guid] = chat
            publish()
        }

        override suspend fun markRead(guid: String) {
            chats[guid]?.let {
                chats[guid] = it.copy(hasUnreadMessage = false)
                publish()
            }
        }

        override suspend fun pruneOld() = Unit

        override suspend fun deleteNotIn(keepGuids: List<String>) {
            chats.keys.retainAll(keepGuids.toSet())
            publish()
        }

        override suspend fun clearAllPins() = Unit

        override suspend fun setPinned(guid: String, pinIndex: Int) = Unit

        override suspend fun getPinnedChats(): List<ChatEntity> = chats.values.filter { it.isPinned }

        override suspend fun deleteChat(guid: String) {
            chats.remove(guid)
            publish()
        }

        override suspend fun getChatCount(): Int = chats.size

        override suspend fun getLastMessageTime(): Long? = chats.values.maxOfOrNull { it.lastMessageDate }
    }
}
