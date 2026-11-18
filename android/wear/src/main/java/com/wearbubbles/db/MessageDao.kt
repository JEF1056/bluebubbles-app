package com.wearbubbles.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction
import com.wearbubbles.db.entities.MessageEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface MessageDao {
    @Query("SELECT * FROM messages WHERE chatGuid = :chatGuid ORDER BY dateCreated ASC")
    fun getMessagesForChat(chatGuid: String): Flow<List<MessageEntity>>

    @Query("SELECT * FROM messages WHERE chatGuid = :chatGuid ORDER BY dateCreated ASC")
    suspend fun getMessagesForChatOnce(chatGuid: String): List<MessageEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(messages: List<MessageEntity>)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(message: MessageEntity)

    @Query("SELECT MIN(dateCreated) FROM messages WHERE chatGuid = :chatGuid")
    suspend fun getOldestMessageDate(chatGuid: String): Long?

    @Query("SELECT attachmentGuid, attachmentMimeType FROM messages WHERE chatGuid = :chatGuid AND attachmentGuid IS NOT NULL ORDER BY dateCreated DESC LIMIT 1")
    suspend fun getLatestAttachment(chatGuid: String): AttachmentInfo?

    @Query("SELECT * FROM messages WHERE attachmentGuid IS NOT NULL AND attachmentMimeType LIKE 'image/%' ORDER BY dateCreated DESC LIMIT :limit")
    suspend fun getRecentImageMessages(limit: Int): List<MessageEntity>

    @Query("DELETE FROM messages WHERE guid = :guid")
    suspend fun deleteByGuid(guid: String)

    @Query("DELETE FROM messages WHERE chatGuid = :chatGuid")
    suspend fun deleteMessagesForChat(chatGuid: String)

    @Query("DELETE FROM messages WHERE guid NOT IN (SELECT guid FROM messages ORDER BY dateCreated DESC LIMIT 500)")
    suspend fun pruneOld()

    @Transaction
    suspend fun upsertAndPrune(messages: List<MessageEntity>) {
        upsertAll(messages)
        pruneOld()
    }

    @Transaction
    suspend fun replaceTempMessage(tempGuid: String, realMessage: MessageEntity) {
        deleteByGuid(tempGuid)
        upsert(realMessage)
    }

    @Query("DELETE FROM messages WHERE guid = :guid AND sendFailed = 1")
    suspend fun deleteFailedMessage(guid: String)

    @Query("UPDATE messages SET sendFailed = 1 WHERE guid = :guid")
    suspend fun markSendFailed(guid: String)
}

data class AttachmentInfo(
    val attachmentGuid: String?,
    val attachmentMimeType: String?
)
