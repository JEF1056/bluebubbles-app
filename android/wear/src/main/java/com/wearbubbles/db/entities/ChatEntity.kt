package com.wearbubbles.db.entities

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "chats")
data class ChatEntity(
    @PrimaryKey val guid: String,
    val chatIdentifier: String,
    val displayName: String?,
    val participantAddresses: String,
    val lastMessageText: String?,
    val lastMessageDate: Long,
    val lastMessageIsFromMe: Boolean,
    val hasUnreadMessage: Boolean,
    val lastMessageAttachmentGuid: String? = null,
    val lastMessageAttachmentMimeType: String? = null,
    val isPinned: Boolean = false,
    val pinIndex: Int? = null
) {
    val title: String
        get() = displayName?.takeIf { it.isNotBlank() } ?: chatIdentifier

    val isGroup: Boolean
        get() = participantAddresses.split(",").filter { it.isNotBlank() }.size > 1
}
