package com.wearbubbles.api.dto

import com.google.gson.JsonElement
import com.google.gson.annotations.SerializedName

data class ApiResponse<T>(
    val status: Int,
    val message: String,
    val data: T?
)

data class PingResponse(
    val server_version: String? = null
)

data class ICloudContactDto(
    val account_name: String? = null,
    val name: String? = null,
    val display_name: String? = null,
    val first_name: String? = null,
    val last_name: String? = null,
    val apple_id: String? = null,
    val active_alias: String? = null,
    val avatar: String? = null
) {
    fun resolvedName(): String =
        display_name?.takeIf { it.isNotBlank() }
            ?: account_name?.takeIf { it.isNotBlank() }
            ?: name?.takeIf { it.isNotBlank() }
            ?: listOfNotNull(
                first_name?.takeIf { it.isNotBlank() },
                last_name?.takeIf { it.isNotBlank() }
            ).joinToString(" ")

    fun resolvedHandle(): String =
        active_alias?.takeIf { it.isNotBlank() }
            ?: apple_id?.takeIf { it.isNotBlank() }
            ?: ""
}

data class ChatQueryRequest(
    val limit: Int = 30,
    val offset: Int = 0,
    val with: List<String> = listOf("lastMessage", "participants", "sms"),
    val sort: String = "lastmessage"
)

data class MessageQueryRequest(
    val chatGuid: String,
    val limit: Int = 40,
    val offset: Int = 0,
    val sort: String = "DESC",
    val with: List<String> = listOf("handle", "attachment", "attributedBody"),
    val where: List<WhereClause> = emptyList()
)

data class WhereClause(
    val statement: String,
    val args: Map<String, Any>
)

data class SendMessageRequest(
    val chatGuid: String,
    val tempGuid: String,
    val message: String,
    val method: String? = null
)

data class CreateChatRequest(
    val addresses: List<String>,
    val message: String,
    val tempGuid: String? = null,
    val method: String? = null
)

data class ReactRequest(
    val chatGuid: String,
    val selectedMessageGuid: String,
    val reaction: String,
    val partIndex: Int = 0
)

data class ChatDto(
    val guid: String,
    val chatIdentifier: String? = null,
    val displayName: String? = null,
    val participants: List<HandleDto>? = null,
    val lastMessage: MessageDto? = null,
    val messages: List<MessageDto>? = null,
    val hasUnreadMessage: Boolean? = null,
    val isArchived: Boolean? = null,
    val dateDeleted: Long? = null,
    val isPinned: Boolean? = null,
    val pinIndex: Int? = null
)

data class PinnedChatsResponse(
    val pinnedChatGuids: List<String> = emptyList()
)

data class HandleDto(
    val address: String? = null,
    val originalROWID: Long? = null
)

data class MessageTranslationDto(
    val text: String? = null,
    val sourceLanguage: String? = null,
    val targetLanguage: String? = null,
    val provider: String? = null,
    val autoTranslated: Boolean? = null,
    val dateTranslated: Long? = null
)

data class MessageDto(
    val guid: String,
    val tempGuid: String? = null,
    val text: String? = null,
    val isFromMe: Boolean = false,
    val dateCreated: Long = 0,
    val dateDelivered: Long? = null,
    val dateRead: Long? = null,
    val dateEdited: Long? = null,
    val handle: HandleDto? = null,
    val chats: List<ChatRefDto>? = null,
    val attachments: List<AttachmentDto>? = null,
    val associatedMessageGuid: String? = null,
    val associatedMessageType: String? = null,
    val associatedMessageEmoji: String? = null,
    val attributedBody: JsonElement? = null,
    val translation: MessageTranslationDto? = null,
    val balloonBundleId: String? = null,
    val payloadData: JsonElement? = null
)

data class ChatRefDto(
    val guid: String
)

data class AttachmentDto(
    val guid: String,
    val mimeType: String? = null,
    val transferName: String? = null
)

data class ContactDto(
    val firstName: String? = null,
    val lastName: String? = null,
    val displayName: String? = null,
    val phoneNumbers: List<ContactAddressDto>? = null,
    val emails: List<ContactAddressDto>? = null,
    val avatar: String? = null
)

data class ContactAddressDto(
    val address: String? = null
)

// --- Phone Relay DTOs ---

data class ChatRelayDto(
    val guid: String,
    val chatIdentifier: String,
    val displayName: String? = null,
    val participantAddresses: List<String> = emptyList(),
    val lastMessageText: String? = null,
    val lastMessageDate: Long = 0L,
    val lastMessageIsFromMe: Boolean = false,
    val hasUnreadMessage: Boolean = false,
    val lastMessageAttachmentGuid: String? = null,
    val lastMessageAttachmentMimeType: String? = null,
    val isPinned: Boolean = false,
    val pinIndex: Int? = null
)

data class LinkPreviewDto(
    val title: String? = null,
    val subtitle: String? = null,
    val url: String? = null,
    val site: String? = null,
    val imageAttachmentGuid: String? = null,
    val imageUrl: String? = null,
    val iconUrl: String? = null
)

data class MessageRelayDto(
    val guid: String,
    val chatGuid: String,
    val tempGuid: String? = null,
    val text: String? = null,
    val isFromMe: Boolean = false,
    val dateCreated: Long = 0L,
    val dateDelivered: Long? = null,
    val dateRead: Long? = null,
    val dateEdited: Long? = null,
    val handleAddress: String? = null,
    val attachmentGuid: String? = null,
    val attachmentMimeType: String? = null,
    val attachments: List<AttachmentDto>? = null,
    val balloonBundleId: String? = null,
    val linkPreview: LinkPreviewDto? = null,
    val associatedMessageGuid: String? = null,
    val associatedMessageType: String? = null,
    val associatedMessageEmoji: String? = null,
    val translatedText: String? = null,
    val translationSourceLang: String? = null,
    val translationTargetLang: String? = null
)

data class ContactRelayDto(
    val normalizedAddress: String,
    val displayName: String,
    val rawAddress: String = normalizedAddress,
    val hasAvatar: Boolean = false
)

// --- Tapbacks & Address Helpers ---

enum class TapbackType(
    val apiName: String,
    val addCode: String,
    val removeCode: String,
    val emoji: String,
    val label: String
) {
    LOVE("love", "2000", "3000", "❤️", "Love"),
    LIKE("like", "2001", "3001", "👍", "Like"),
    DISLIKE("dislike", "2002", "3002", "👎", "Dislike"),
    LAUGH("laugh", "2003", "3003", "😂", "Haha"),
    EMPHASIZE("emphasize", "2004", "3004", "‼️", "Exclaim"),
    QUESTION("question", "2005", "3005", "❓", "Question"),
    EMOJI("emoji", "2006", "3006", "😀", "Emoji");

    companion object {
        val pickerEntries: List<TapbackType>
            get() = listOf(LOVE, LIKE, DISLIKE, LAUGH, EMPHASIZE, QUESTION)

        fun fromAddCode(code: String?): TapbackType? {
            val normalized = code?.trim()?.lowercase() ?: return null
            return entries.firstOrNull { it.addCode == normalized || it.apiName == normalized }
        }

        fun fromRemoveCode(code: String?): TapbackType? {
            val normalized = code?.trim()?.lowercase() ?: return null
            return entries.firstOrNull { it.removeCode == normalized || "-${it.apiName}" == normalized }
        }

        fun isTapbackCode(code: String?): Boolean =
            fromAddCode(code) != null || fromRemoveCode(code) != null
    }
}

data class ReactionBadge(
    val type: TapbackType,
    val count: Int,
    val isFromMe: Boolean,
    val customEmoji: String? = null
) {
    val displayEmoji: String
        get() = customEmoji?.takeIf { it.isNotBlank() } ?: type.emoji
}

object TapbackUtils {
    private val prefixRegex = Regex("^b?p:(?:\\d+/)?")

    fun isTapbackCode(code: String?): Boolean = TapbackType.isTapbackCode(code)

    fun extractTargetGuid(associatedMessageGuid: String?): String? {
        if (associatedMessageGuid.isNullOrBlank()) return null
        return associatedMessageGuid.replace(prefixRegex, "").ifBlank { null }
    }

    /**
     * Folds chronological reaction messages into active ReactionBadges per target message GUID.
     */
    fun computeReactions(reactionMessages: List<com.wearbubbles.db.entities.MessageEntity>): Map<String, List<ReactionBadge>> {
        // Track per (senderKey, TapbackType, emojiGlyph?) -> isFromMe
        val byTarget = linkedMapOf<String, LinkedHashMap<Triple<String, TapbackType, String?>, Boolean>>()
        for (msg in reactionMessages.sortedBy { it.dateCreated }) {
            val target = extractTargetGuid(msg.associatedMessageGuid) ?: continue
            val code = msg.associatedMessageType ?: continue
            val senderKey = if (msg.isFromMe) "__me__" else (msg.handleAddress ?: msg.guid)

            val addType = TapbackType.fromAddCode(code)
            val removeType = TapbackType.fromRemoveCode(code)
            val map = byTarget.getOrPut(target) { linkedMapOf() }

            if (addType != null) {
                val emojiGlyph = if (addType == TapbackType.EMOJI) {
                    msg.associatedMessageEmoji?.takeIf { it.isNotBlank() }
                } else null
                map[Triple(senderKey, addType, emojiGlyph)] = msg.isFromMe
            } else if (removeType != null) {
                val emojiGlyph = if (removeType == TapbackType.EMOJI) {
                    msg.associatedMessageEmoji?.takeIf { it.isNotBlank() }
                } else null
                if (removeType == TapbackType.EMOJI && emojiGlyph == null) {
                    map.keys.removeAll { it.first == senderKey && it.second == TapbackType.EMOJI }
                } else {
                    map.remove(Triple(senderKey, removeType, emojiGlyph))
                }
            }
        }

        return byTarget.mapValues { (_, entries) ->
            val counts = linkedMapOf<Pair<TapbackType, String?>, Int>()
            val fromMeSet = hashSetOf<Pair<TapbackType, String?>>()
            for ((key, isMe) in entries) {
                val badgeKey = key.second to key.third
                counts[badgeKey] = (counts[badgeKey] ?: 0) + 1
                if (isMe) fromMeSet.add(badgeKey)
            }
            counts.map { (badgeKey, count) ->
                ReactionBadge(
                    type = badgeKey.first,
                    count = count,
                    isFromMe = badgeKey in fromMeSet,
                    customEmoji = badgeKey.second
                )
            }
        }
    }
}

object AddressNormalizer {
    fun normalize(address: String): String {
        val trimmed = address.trim()
        if (trimmed.contains("@")) return trimmed.lowercase()
        val digits = trimmed.filter { it.isDigit() }
        return if (digits.length > 10) digits.takeLast(10) else digits
    }

    fun format(address: String): String {
        val trimmed = address.trim()
        if (trimmed.contains("@")) return trimmed
        val digits = trimmed.filter { it.isDigit() }
        val ten = if (digits.length == 11 && digits.startsWith("1")) digits.substring(1) else digits
        if (ten.length == 10) {
            return "(${ten.substring(0, 3)}) ${ten.substring(3, 6)}-${ten.substring(6)}"
        }
        return trimmed
    }
}
