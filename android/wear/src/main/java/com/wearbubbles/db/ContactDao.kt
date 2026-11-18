package com.wearbubbles.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import com.wearbubbles.db.entities.ContactEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface ContactDao {
    @Query("SELECT * FROM contacts")
    suspend fun getAllContacts(): List<ContactEntity>

    @Query("SELECT * FROM contacts ORDER BY displayName ASC")
    fun getAllContactsFlow(): Flow<List<ContactEntity>>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(contacts: List<ContactEntity>)

    @Query("UPDATE contacts SET avatarPath = :avatarPath WHERE normalizedAddress = :normalizedAddress")
    suspend fun updateAvatarPath(normalizedAddress: String, avatarPath: String)

    @Query("SELECT COUNT(*) FROM contacts")
    suspend fun getCount(): Int
}
