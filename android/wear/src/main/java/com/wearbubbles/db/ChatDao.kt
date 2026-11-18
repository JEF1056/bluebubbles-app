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

    @Query("DELETE FROM chats WHERE guid = :guid")
    suspend fun deleteChat(guid: String)

    @Query("SELECT COUNT(*) FROM chats")
    suspend fun getChatCount(): Int

    @Query("SELECT COUNT(*) FROM chats WHERE hasUnreadMessage = 1")
    suspend fun getUnreadCount(): Int

    @Query("SELECT MAX(lastMessageDate) FROM chats")
    suspend fun getLastMessageTime(): Long?

    @Transaction
    suspend fun replaceAndPrune(chats: List<ChatEntity>) {
        if (chats.isNotEmpty()) {
            deleteNotIn(chats.map { it.guid })
        }
        upsertAll(chats)
        pruneOld()
    }

    @Transaction
    suspend fun updatePinnedOrder(pinnedGuids: List<String>) {
        clearAllPins()
        pinnedGuids.forEachIndexed { index, guid ->
            setPinned(guid, index)
        }
    }
}
