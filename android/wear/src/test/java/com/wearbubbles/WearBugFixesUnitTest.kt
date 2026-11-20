package com.wearbubbles

import com.wearbubbles.data.ContactMemoryCache
import com.wearbubbles.db.ChatDao
import com.wearbubbles.db.ContactDao
import com.wearbubbles.db.entities.ChatEntity
import com.wearbubbles.db.entities.ContactEntity
import com.wearbubbles.ui.setup.SetupViewModel
import com.wearbubbles.worker.MessageSyncWorker
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WearBugFixesUnitTest {

    @Test
    fun `MessageSyncWorker skips connected sync only when not forced`() {
        assertTrue(MessageSyncWorker.shouldSkipSync(isSocketConnected = true, force = false))
        assertFalse(MessageSyncWorker.shouldSkipSync(isSocketConnected = true, force = true))
        assertFalse(MessageSyncWorker.shouldSkipSync(isSocketConnected = false, force = false))
    }

    @Test
    fun `SetupViewModel does not auto sync when user explicitly disconnected`() {
        assertFalse(SetupViewModel.shouldAutoSyncOnSetup(phoneConnected = true, userDisconnected = true))
        assertFalse(SetupViewModel.shouldAutoSyncOnSetup(phoneConnected = false, userDisconnected = false))
        assertTrue(SetupViewModel.shouldAutoSyncOnSetup(phoneConnected = true, userDisconnected = false))
    }

    @Test
    fun `ContactMemoryCache refreshes names and avatars when ContactDao flow emits updates`() = runBlocking {
        val dao = FakeContactDao()
        val cache = ContactMemoryCache()
        val flow = dao.getAllContactsFlow().onEach { cache.update(it) }

        flow.first()
        assertEquals("(555) 123-4567", cache.resolveDisplayName("+15551234567"))
        assertNull(cache.resolveAvatarPath("+15551234567"))

        dao.emit(
            listOf(
                ContactEntity(
                    normalizedAddress = "5551234567",
                    displayName = "Alice",
                    avatarPath = "/tmp/alice.img"
                )
            )
        )
        flow.first()
        assertEquals("Alice", cache.resolveDisplayName("+1 (555) 123-4567"))
        assertEquals("/tmp/alice.img", cache.resolveAvatarPath("+15551234567"))

        dao.emit(
            listOf(
                ContactEntity(
                    normalizedAddress = "5551234567",
                    displayName = "Alice Updated",
                    avatarPath = null
                )
            )
        )
        flow.first()
        assertEquals("Alice Updated", cache.resolveDisplayName("+15551234567"))
        assertNull(cache.resolveAvatarPath("+15551234567"))
    }

    @Test
    fun `mergeIncomingChat preserves newer preview when older message arrives concurrently`() {
        val newerExisting = ChatEntity(
            guid = "iMessage;-;+15551234567",
            chatIdentifier = "+15551234567",
            displayName = null,
            participantAddresses = "+15551234567",
            lastMessageText = "Latest message",
            lastMessageDate = 2_000L,
            lastMessageIsFromMe = true,
            hasUnreadMessage = false,
            lastMessageAttachmentGuid = "att-new",
            lastMessageAttachmentMimeType = "image/jpeg"
        )

        val merged = ChatDao.mergeIncomingChat(
            existing = newerExisting,
            chatGuid = newerExisting.guid,
            defaultIdentifier = "+15551234567",
            defaultParticipantAddresses = "+15551234567",
            lastMessageText = "Stale message",
            lastMessageDate = 1_000L,
            lastMessageIsFromMe = false,
            hasUnreadMessage = true,
            lastMessageAttachmentGuid = null,
            lastMessageAttachmentMimeType = null
        )

        assertEquals("Latest message", merged.lastMessageText)
        assertEquals(2_000L, merged.lastMessageDate)
        assertTrue(merged.lastMessageIsFromMe)
        assertEquals("att-new", merged.lastMessageAttachmentGuid)
        assertTrue(merged.hasUnreadMessage)
    }

    private class FakeContactDao : ContactDao {
        private val flow = MutableStateFlow<List<ContactEntity>>(emptyList())

        fun emit(list: List<ContactEntity>) {
            flow.value = list
        }

        override fun getAllContactsFlow(): Flow<List<ContactEntity>> = flow

        override suspend fun getAllContacts(): List<ContactEntity> = flow.value

        override suspend fun upsertAll(contacts: List<ContactEntity>) {
            flow.value = contacts
        }

        override suspend fun updateAvatarPath(normalizedAddress: String, avatarPath: String) {
            flow.value = flow.value.map {
                if (it.normalizedAddress == normalizedAddress) it.copy(avatarPath = avatarPath) else it
            }
        }

        override suspend fun getCount(): Int = flow.value.size
    }
}
