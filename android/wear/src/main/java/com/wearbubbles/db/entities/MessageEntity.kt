package com.wearbubbles.db.entities

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

@Entity(
    tableName = "messages",
    indices = [Index(value = ["chatGuid", "dateCreated"])]
)
data class MessageEntity(
    @PrimaryKey val guid: String,
    val chatGuid: String,
    val text: String?,
    val isFromMe: Boolean,
    val dateCreated: Long,
    val handleAddress: String?,
    val attachmentGuid: String? = null,
    val attachmentMimeType: String? = null,
    val associatedMessageGuid: String? = null,
    val associatedMessageType: String? = null,
    val associatedMessageEmoji: String? = null,
    val sendFailed: Boolean = false,
    val dateDelivered: Long? = null,
    val dateRead: Long? = null,
    val translatedText: String? = null,
    val translationSourceLang: String? = null,
    val translationTargetLang: String? = null,
    val dateEdited: Long? = null,
    val attachmentsJson: String? = null,
    val balloonBundleId: String? = null,
    val linkPreviewJson: String? = null
)
