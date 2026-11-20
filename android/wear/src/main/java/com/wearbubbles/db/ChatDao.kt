package com.wearbubbles.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction
import com.wearbubbles.db.entities.ChatEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface ChatDao {
    @Query(
        "SELECT * FROM chats " +
            "ORDER BY isPinned DESC, CASE WHEN pinIndex IS NULL THEN 999999 ELSE pinIndex END ASC, lastMessageDate DESC"
    )
    fun getAllChats(): Flow<List<ChatEntity>>

    @Query(
        "SELECT * FROM chats " +
            "ORDER BY isPinned DESC, CASE WHEN pinIndex IS NULL THEN 999999 ELSE pinIndex END ASC, lastMessageDate DESC"
    )
    suspend fun getAllChatsOnce(): List<ChatEntity>

    @Query("SELECT * FROM chats WHERE guid = :guid")
    suspend fun getChat(guid: String): ChatEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(chats: List<ChatEntity>)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(chat: ChatEntity)

    @Query("UPDATE chats SET hasUnreadMessage = 0 WHERE guid = :guid")
    suspend fun markRead(guid: String)

    @Query(
        "DELETE FROM chats WHERE isPinned = 0 AND guid NOT IN " +
            "(SELECT guid FROM chats WHERE isPinned = 0 ORDER BY lastMessageDate DESC LIMIT 50)"
    )
    suspend fun pruneOld()

    @Query("DELETE FROM chats WHERE guid NOT IN (:keepGuids)")
    suspend fun deleteNotIn(keepGuids: List<String>)

    @Query("UPDATE chats SET isPinned = 0, pinIndex = NULL WHERE isPinned = 1")
    suspend fun clearAllPins()

    @Query("UPDATE chats SET isPinned = 1, pinIndex = :pinIndex WHERE guid = :guid")
    suspend fun setPinned(guid: String, pinIndex: Int)

    @Query("SELECT * FROM chats WHERE isPinned = 1")
    suspend fun getPinnedChats(): List<ChatEntity>

    @Query("DELETE FROM chats WHERE guid = :guid")
    suspend fun deleteChat(guid: String)

    @Query("SELECT COUNT(*) FROM chats")
    suspend fun getChatCount(): Int

    @Query("SELECT MAX(lastMessageDate) FROM chats")
    suspend fun getLastMessageTime(): Long?

    @Transaction
    suspend fun replaceAndPrune(chats: List<ChatEntity>, preservePins: Boolean = false) {
        val finalChats = if (preservePins) {
            mergePreservingPins(chats, getPinnedChats())
        } else {
            chats
        }
        if (finalChats.isNotEmpty()) {
            deleteNotIn(finalChats.map { it.guid })
        }
        upsertAll(finalChats)
        pruneOld()
    }

    companion object {
        // Preserve existing pin state when /chat/pinned failed and /chat/query lacked pin metadata.
        internal fun mergePreservingPins(
            incoming: List<ChatEntity>,
            existingPinned: List<ChatEntity>
        ): List<ChatEntity> {
            if (existingPinned.isEmpty()) return incoming
            val pinnedByGuid = existingPinned.associateBy { it.guid }
            val incomingGuids = HashSet<String>(incoming.size)
            val merged = incoming.map { chat ->
                incomingGuids.add(chat.guid)
                val prev = pinnedByGuid[chat.guid]
                if (prev != null && (!chat.isPinned || chat.pinIndex == null)) {
                    chat.copy(isPinned = true, pinIndex = chat.pinIndex ?: prev.pinIndex)
                } else {
                    chat
                }
            }.toMutableList()
            for (prev in existingPinned) {
                if (prev.guid !in incomingGuids) {
                    merged.add(prev)
                }
            }
            return merged
        }

        internal fun mergeIncomingChat(
            existing: ChatEntity?,
            chatGuid: String,
            defaultIdentifier: String,
            defaultParticipantAddresses: String,
            lastMessageText: String?,
            lastMessageDate: Long,
            lastMessageIsFromMe: Boolean,
            hasUnreadMessage: Boolean,
            lastMessageAttachmentGuid: String?,
            lastMessageAttachmentMimeType: String?
        ): ChatEntity {
            if (existing == null) {
                return ChatEntity(
                    guid = chatGuid,
                    chatIdentifier = defaultIdentifier,
                    displayName = null,
                    participantAddresses = defaultParticipantAddresses,
                    lastMessageText = lastMessageText,
                    lastMessageDate = lastMessageDate,
                    lastMessageIsFromMe = lastMessageIsFromMe,
                    hasUnreadMessage = hasUnreadMessage,
                    lastMessageAttachmentGuid = lastMessageAttachmentGuid,
                    lastMessageAttachmentMimeType = lastMessageAttachmentMimeType
                )
            }
            val isNewerOrEqual = lastMessageDate >= existing.lastMessageDate
            return existing.copy(
                lastMessageText = if (isNewerOrEqual) (lastMessageText ?: existing.lastMessageText) else existing.lastMessageText,
                lastMessageDate = maxOf(existing.lastMessageDate, lastMessageDate),
                lastMessageIsFromMe = if (isNewerOrEqual) lastMessageIsFromMe else existing.lastMessageIsFromMe,
                hasUnreadMessage = if (hasUnreadMessage) true else existing.hasUnreadMessage,
                lastMessageAttachmentGuid = if (isNewerOrEqual) lastMessageAttachmentGuid else existing.lastMessageAttachmentGuid,
                lastMessageAttachmentMimeType = if (isNewerOrEqual) lastMessageAttachmentMimeType else existing.lastMessageAttachmentMimeType
            )
        }
    }

    @Transaction
    suspend fun updatePinnedOrder(pinnedGuids: List<String>) {
        clearAllPins()
        pinnedGuids.forEachIndexed { index, guid ->
            setPinned(guid, index)
        }
    }

    @Transaction
    suspend fun upsertChatFromIncomingMessage(
        chatGuid: String,
        defaultIdentifier: String,
        defaultParticipantAddresses: String,
        lastMessageText: String?,
        lastMessageDate: Long,
        lastMessageIsFromMe: Boolean,
        hasUnreadMessage: Boolean,
        lastMessageAttachmentGuid: String?,
        lastMessageAttachmentMimeType: String?
    ) {
        val existingChat = getChat(chatGuid)
        val merged = mergeIncomingChat(
            existing = existingChat,
            chatGuid = chatGuid,
            defaultIdentifier = defaultIdentifier,
            defaultParticipantAddresses = defaultParticipantAddresses,
            lastMessageText = lastMessageText,
            lastMessageDate = lastMessageDate,
            lastMessageIsFromMe = lastMessageIsFromMe,
            hasUnreadMessage = hasUnreadMessage,
            lastMessageAttachmentGuid = lastMessageAttachmentGuid,
            lastMessageAttachmentMimeType = lastMessageAttachmentMimeType
        )
        upsert(merged)
    }

    @Transaction
    suspend fun updateOutgoingLastMessage(
        chatGuid: String,
        defaultIdentifier: String,
        text: String,
        date: Long
    ) {
        val existingChat = getChat(chatGuid)
        if (existingChat != null) {
            val isNewerOrEqual = date >= existingChat.lastMessageDate
            upsert(
                existingChat.copy(
                    lastMessageText = if (isNewerOrEqual) text else existingChat.lastMessageText,
                    lastMessageDate = maxOf(existingChat.lastMessageDate, date),
                    lastMessageIsFromMe = if (isNewerOrEqual) true else existingChat.lastMessageIsFromMe,
                    hasUnreadMessage = false
                )
            )
        } else {
            upsert(
                ChatEntity(
                    guid = chatGuid,
                    chatIdentifier = defaultIdentifier,
                    displayName = null,
                    participantAddresses = defaultIdentifier,
                    lastMessageText = text,
                    lastMessageDate = date,
                    lastMessageIsFromMe = true,
                    hasUnreadMessage = false
                )
            )
        }
    }
}
