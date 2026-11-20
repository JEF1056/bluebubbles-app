package com.wearbubbles.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction
import com.wearbubbles.api.dto.TapbackUtils
import com.wearbubbles.db.entities.MessageEntity
import kotlinx.coroutines.flow.Flow
import kotlin.math.abs

@Dao
interface MessageDao {
    @Query("SELECT * FROM messages WHERE chatGuid = :chatGuid ORDER BY dateCreated ASC")
    fun getMessagesForChat(chatGuid: String): Flow<List<MessageEntity>>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(messages: List<MessageEntity>)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(message: MessageEntity)

    @Query("SELECT MIN(dateCreated) FROM messages WHERE chatGuid = :chatGuid")
    suspend fun getOldestMessageDate(chatGuid: String): Long?

    @Query("SELECT * FROM messages WHERE attachmentGuid IS NOT NULL AND attachmentMimeType LIKE 'image/%' ORDER BY dateCreated DESC LIMIT :limit")
    suspend fun getRecentImageMessages(limit: Int): List<MessageEntity>

    @Query("SELECT * FROM messages WHERE chatGuid = :chatGuid AND (sendFailed = 1 OR guid LIKE 'temp-%' OR guid LIKE 'sent-temp-%')")
    suspend fun getPendingOrFailedForChat(chatGuid: String): List<MessageEntity>

    @Query("SELECT EXISTS(SELECT 1 FROM messages WHERE guid = :guid)")
    suspend fun existsByGuid(guid: String): Boolean

    @Query("SELECT COUNT(*) FROM messages WHERE chatGuid = :chatGuid")
    suspend fun countForChat(chatGuid: String): Int

    @Query("DELETE FROM messages WHERE guid = :guid")
    suspend fun deleteByGuid(guid: String)

    @Query("DELETE FROM messages WHERE chatGuid = :chatGuid AND sendFailed = 1")
    suspend fun deleteFailedForChat(chatGuid: String)

    @Query("DELETE FROM messages WHERE chatGuid = :chatGuid")
    suspend fun deleteMessagesForChat(chatGuid: String)

    @Query(
        "DELETE FROM messages WHERE sendFailed = 0 AND guid NOT LIKE 'temp-%' AND guid NOT LIKE 'sent-temp-%' " +
            "AND guid NOT IN (SELECT guid FROM messages ORDER BY dateCreated DESC LIMIT 500)"
    )
    suspend fun pruneOld()

    @Transaction
    suspend fun upsertAndPrune(messages: List<MessageEntity>) {
        upsertAll(messages)
        pruneOld()
    }

    @Transaction
    suspend fun replaceTempMessage(tempGuid: String, realMessage: MessageEntity) {
        if (realMessage.guid == "sent-$tempGuid") {
            if (!existsByGuid(tempGuid)) return
            deleteByGuid(tempGuid)
            upsert(realMessage)
        } else {
            deleteByGuid(tempGuid)
            deleteByGuid("sent-$tempGuid")
            upsert(realMessage)
        }
    }

    @Query("UPDATE messages SET sendFailed = 1 WHERE guid = :guid")
    suspend fun markSendFailed(guid: String)

    @Query("UPDATE messages SET sendFailed = 1 WHERE chatGuid = :chatGuid AND sendFailed = 0 AND guid LIKE 'temp-%' AND guid NOT LIKE 'temp-react-%' AND dateCreated < :olderThanMs")
    suspend fun markStalePendingFailed(chatGuid: String, olderThanMs: Long)

    @Transaction
    suspend fun upsertAndReconcile(message: MessageEntity, tempGuid: String? = null) {
        if (!tempGuid.isNullOrBlank() && tempGuid != message.guid) {
            deleteByGuid(tempGuid)
            deleteByGuid("sent-$tempGuid")
        } else if (message.isFromMe) {
            val local = getPendingOrFailedForChat(message.chatGuid)
            if (local.isNotEmpty()) {
                val incoming = listOf(message to null)
                for (guid in findReconciledTempGuids(local, incoming)) {
                    deleteByGuid(guid)
                }
                for (guid in findReconciledTempReactionGuids(local, incoming)) {
                    deleteByGuid(guid)
                }
            }
        }
        upsert(message)
    }

    @Transaction
    suspend fun upsertAndReconcileBatch(
        chatGuid: String,
        messages: List<MessageEntity>,
        stalePendingCutoffMs: Long
    ) {
        val local = getPendingOrFailedForChat(chatGuid)
        if (local.isNotEmpty()) {
            val pairs = messages.map { it to null }
            val matched = if (messages.isNotEmpty()) {
                findReconciledTempGuids(local, pairs) + findReconciledTempReactionGuids(local, pairs)
            } else {
                emptySet()
            }
            for (guid in matched) {
                deleteByGuid(guid)
            }
            // Remove leaked temp-react-* placeholders that never received a final result.
            for (row in local) {
                if (row.guid !in matched &&
                    row.guid.startsWith("temp-react-") &&
                    row.dateCreated < stalePendingCutoffMs
                ) {
                    deleteByGuid(row.guid)
                }
            }
        }
        markStalePendingFailed(chatGuid, stalePendingCutoffMs)
        if (messages.isNotEmpty()) {
            upsertAll(messages)
            pruneOld()
        }
    }

    companion object {
        // Slightly above PhoneRelayClient.SEND_TIMEOUT_MS (130s) so active sends aren't flagged early.
        internal const val STALE_PENDING_TIMEOUT_MS = 145_000L
        private const val RECONCILE_CLOCK_SKEW_MS = 15_000L
        private const val RECONCILE_FORWARD_WINDOW_MS = 5 * 60_000L

        internal fun isTempPlaceholderGuid(guid: String): Boolean =
            (guid.startsWith("temp-") || guid.startsWith("sent-temp-")) &&
                !guid.startsWith("temp-react-")

        /**
         * Returns local pending/failed temp GUIDs confirmed by incoming real server messages,
         * matching exact tempGuid first, then 1-to-1 by outgoing content within the send window.
         */
        internal fun findReconciledTempGuids(
            localTempOrFailed: List<MessageEntity>,
            incoming: List<Pair<MessageEntity, String?>>
        ): Set<String> {
            val matched = linkedSetOf<String>()
            val remainingLocal = localTempOrFailed
                .filter { isTempPlaceholderGuid(it.guid) && !TapbackUtils.isTapbackCode(it.associatedMessageType) }
                .toMutableList()
            val remainingIncoming = incoming
                .filter { (msg, _) ->
                    !msg.sendFailed &&
                        !isTempPlaceholderGuid(msg.guid) &&
                        !TapbackUtils.isTapbackCode(msg.associatedMessageType)
                }
                .toMutableList()

            // Pass 1: exact tempGuid from socket echo.
            val incomingIter = remainingIncoming.iterator()
            while (incomingIter.hasNext()) {
                val (real, tempGuid) = incomingIter.next()
                if (tempGuid.isNullOrBlank() || tempGuid == real.guid) continue
                val idx = remainingLocal.indexOfFirst { it.guid == tempGuid }
                if (idx >= 0) {
                    matched.add(remainingLocal.removeAt(idx).guid)
                    incomingIter.remove()
                }
            }

            // Pass 2: 1-to-1 content + timestamp fallback for /message/query sync (no tempGuid in chat.db).
            val candidates = mutableListOf<Triple<Long, MessageEntity, MessageEntity>>()
            for (local in remainingLocal) {
                if (!local.isFromMe) continue
                for ((real, _) in remainingIncoming) {
                    if (!real.isFromMe || real.chatGuid != local.chatGuid) continue
                    val delta = real.dateCreated - local.dateCreated
                    if (delta < -RECONCILE_CLOCK_SKEW_MS || delta > RECONCILE_FORWARD_WINDOW_MS) continue
                    if (matchesTempContent(local, real)) {
                        candidates.add(Triple(abs(delta), local, real))
                    }
                }
            }
            candidates.sortBy { it.first }
            val usedLocal = hashSetOf<String>()
            val usedReal = hashSetOf<String>()
            for ((_, local, real) in candidates) {
                if (usedLocal.add(local.guid) && usedReal.add(real.guid)) {
                    matched.add(local.guid)
                }
            }
            return matched
        }

        private fun matchesTempContent(local: MessageEntity, real: MessageEntity): Boolean {
            val localIsAudio = local.guid.startsWith("temp-audio-") ||
                local.attachmentMimeType?.startsWith("audio/") == true
            if (localIsAudio) {
                return real.attachmentMimeType?.startsWith("audio/") == true
            }
            val localText = local.text?.trim()
            val realText = real.text?.trim()
            return !localText.isNullOrBlank() && localText == realText
        }

        internal fun findReconciledTempReactionGuids(
            localTempOrFailed: List<MessageEntity>,
            incoming: List<Pair<MessageEntity, String?>>
        ): Set<String> {
            val remainingLocal = localTempOrFailed
                .filter {
                    it.guid.startsWith("temp-react-") &&
                        it.isFromMe &&
                        TapbackUtils.isTapbackCode(it.associatedMessageType)
                }
                .toMutableList()
            if (remainingLocal.isEmpty()) return emptySet()

            val remainingIncoming = incoming
                .filter { (msg, _) ->
                    !msg.sendFailed &&
                        !msg.guid.startsWith("temp-react-") &&
                        !isTempPlaceholderGuid(msg.guid) &&
                        msg.isFromMe &&
                        TapbackUtils.isTapbackCode(msg.associatedMessageType)
                }
                .toMutableList()
            if (remainingIncoming.isEmpty()) return emptySet()

            val matched = linkedSetOf<String>()
            val incomingIter = remainingIncoming.iterator()
            while (incomingIter.hasNext()) {
                val (real, tempGuid) = incomingIter.next()
                if (tempGuid.isNullOrBlank() || tempGuid == real.guid) continue
                val idx = remainingLocal.indexOfFirst { it.guid == tempGuid }
                if (idx >= 0) {
                    matched.add(remainingLocal.removeAt(idx).guid)
                    incomingIter.remove()
                }
            }

            val candidates = mutableListOf<Triple<Long, MessageEntity, MessageEntity>>()
            for (local in remainingLocal) {
                val localTarget = TapbackUtils.extractTargetGuid(local.associatedMessageGuid) ?: continue
                for ((real, _) in remainingIncoming) {
                    if (real.chatGuid != local.chatGuid) continue
                    if (real.associatedMessageType != local.associatedMessageType) continue
                    val realTarget = TapbackUtils.extractTargetGuid(real.associatedMessageGuid) ?: continue
                    if (realTarget != localTarget) continue
                    val absDelta = abs(real.dateCreated - local.dateCreated)
                    if (absDelta <= RECONCILE_FORWARD_WINDOW_MS) {
                        candidates.add(Triple(absDelta, local, real))
                    }
                }
            }
            candidates.sortBy { it.first }
            val usedLocal = hashSetOf<String>()
            val usedReal = hashSetOf<String>()
            for ((_, local, real) in candidates) {
                if (usedLocal.add(local.guid) && usedReal.add(real.guid)) {
                    matched.add(local.guid)
                }
            }
            return matched
        }
    }
}
