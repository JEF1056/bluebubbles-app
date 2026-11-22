package com.wearbubbles.ui.messages

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.unit.dp
import com.wearbubbles.api.dto.TapbackType
import com.wearbubbles.db.MessageDao
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.abs

const val BUBBLE_OUTER_RADIUS_DP = 24
const val BUBBLE_INNER_RADIUS_DP = 24
const val BUBBLE_GROUP_GAP_MS = 2 * 60 * 1000L
const val TIMESTAMP_BREAK_MS = 15 * 60 * 1000L

enum class BubblePosition {
    SINGLE,
    FIRST,
    MIDDLE,
    LAST
}

data class BubbleCornerRadii(
    val topStartDp: Int,
    val topEndDp: Int,
    val bottomStartDp: Int,
    val bottomEndDp: Int
) {
    fun toShape(): RoundedCornerShape = RoundedCornerShape(
        topStart = topStartDp.dp,
        topEnd = topEndDp.dp,
        bottomStart = bottomStartDp.dp,
        bottomEnd = bottomEndDp.dp
    )
}

data class BubbleGroupKey(
    val isFromMe: Boolean,
    val senderKey: String,
    val dateCreated: Long,
    val sendFailed: Boolean = false
)

data class GroupedMessageMeta(
    val position: BubblePosition,
    val connectUpper: Boolean,
    val connectLower: Boolean,
    val showTimestampHeader: Boolean,
    val showSenderName: Boolean,
    val corners: BubbleCornerRadii
)

fun bubbleCornerRadii(
    isFromMe: Boolean,
    connectUpper: Boolean,
    connectLower: Boolean
): BubbleCornerRadii = if (isFromMe) {
    BubbleCornerRadii(
        topStartDp = BUBBLE_OUTER_RADIUS_DP,
        topEndDp = if (connectUpper) BUBBLE_INNER_RADIUS_DP else BUBBLE_OUTER_RADIUS_DP,
        bottomStartDp = BUBBLE_OUTER_RADIUS_DP,
        bottomEndDp = if (connectLower) BUBBLE_INNER_RADIUS_DP else BUBBLE_OUTER_RADIUS_DP
    )
} else {
    BubbleCornerRadii(
        topStartDp = if (connectUpper) BUBBLE_INNER_RADIUS_DP else BUBBLE_OUTER_RADIUS_DP,
        topEndDp = BUBBLE_OUTER_RADIUS_DP,
        bottomStartDp = if (connectLower) BUBBLE_INNER_RADIUS_DP else BUBBLE_OUTER_RADIUS_DP,
        bottomEndDp = BUBBLE_OUTER_RADIUS_DP
    )
}

fun MessageUi.toBubbleGroupKey(): BubbleGroupKey {
    val resolvedSender = when {
        isFromMe -> "__ME__"
        !handleAddress.isNullOrBlank() -> handleAddress.trim().lowercase(Locale.ROOT)
        !senderName.isNullOrBlank() -> senderName.trim().lowercase(Locale.ROOT)
        else -> "__OTHER__"
    }
    return BubbleGroupKey(
        isFromMe = isFromMe,
        senderKey = resolvedSender,
        dateCreated = dateCreated,
        sendFailed = sendFailed
    )
}

fun computeBubbleGrouping(
    items: List<BubbleGroupKey>,
    hasSenderLabel: (Int) -> Boolean = { false },
    zoneId: ZoneId = ZoneId.systemDefault(),
    maxGroupGapMs: Long = BUBBLE_GROUP_GAP_MS,
    timestampBreakMs: Long = TIMESTAMP_BREAK_MS
): List<GroupedMessageMeta> {
    if (items.isEmpty()) return emptyList()

    val showHeader = BooleanArray(items.size)
    for (i in items.indices) {
        val curr = items[i]
        if (curr.dateCreated <= 0L) {
            showHeader[i] = false
        } else if (i == 0) {
            showHeader[i] = true
        } else {
            val prev = items[i - 1]
            showHeader[i] = shouldShowTimestampBreak(
                prevEpochMs = prev.dateCreated,
                currEpochMs = curr.dateCreated,
                zoneId = zoneId,
                timestampBreakMs = timestampBreakMs
            )
        }
    }

    fun groupsTogether(prevIdx: Int, currIdx: Int): Boolean {
        if (showHeader[currIdx]) return false
        val prev = items[prevIdx]
        val curr = items[currIdx]
        if (prev.isFromMe != curr.isFromMe) return false
        if (prev.sendFailed != curr.sendFailed) return false
        if (prev.senderKey != curr.senderKey) return false
        if (prev.dateCreated > 0L && curr.dateCreated > 0L) {
            if (abs(curr.dateCreated - prev.dateCreated) > maxGroupGapMs) return false
        }
        return true
    }

    return List(items.size) { i ->
        val connectUpper = i > 0 && groupsTogether(i - 1, i)
        val connectLower = i < items.lastIndex && groupsTogether(i, i + 1)
        val position = when {
            connectUpper && connectLower -> BubblePosition.MIDDLE
            !connectUpper && connectLower -> BubblePosition.FIRST
            connectUpper && !connectLower -> BubblePosition.LAST
            else -> BubblePosition.SINGLE
        }
        val corners = bubbleCornerRadii(
            isFromMe = items[i].isFromMe,
            connectUpper = connectUpper,
            connectLower = connectLower
        )
        GroupedMessageMeta(
            position = position,
            connectUpper = connectUpper,
            connectLower = connectLower,
            showTimestampHeader = showHeader[i],
            showSenderName = !items[i].isFromMe && !connectUpper && hasSenderLabel(i),
            corners = corners
        )
    }
}

data class MessageRowItem(
    val message: MessageUi,
    val meta: GroupedMessageMeta,
    val prevHadReactions: Boolean
)

/**
 * Snapshots messages together with their precomputed grouping and previous-row reaction spacing so
 * ScalingLazyColumn item lambdas never index live Compose state delegates across list mutations.
 */
fun buildMessageRows(messages: List<MessageUi>): List<MessageRowItem> {
    if (messages.isEmpty()) return emptyList()
    val grouping = computeBubbleGrouping(
        items = messages.map { it.toBubbleGroupKey() },
        hasSenderLabel = { idx -> !messages[idx].senderName.isNullOrBlank() }
    )
    return List(messages.size) { index ->
        MessageRowItem(
            message = messages[index],
            meta = grouping[index],
            prevHadReactions = index > 0 && messages[index - 1].reactions.isNotEmpty()
        )
    }
}

fun shouldShowTimestampBreak(
    prevEpochMs: Long,
    currEpochMs: Long,
    zoneId: ZoneId = ZoneId.systemDefault(),
    timestampBreakMs: Long = TIMESTAMP_BREAK_MS
): Boolean {
    if (currEpochMs <= 0L) return false
    if (prevEpochMs <= 0L) return true
    if (abs(currEpochMs - prevEpochMs) >= timestampBreakMs) return true
    val prevDate = Instant.ofEpochMilli(prevEpochMs).atZone(zoneId).toLocalDate()
    val currDate = Instant.ofEpochMilli(currEpochMs).atZone(zoneId).toLocalDate()
    return prevDate != currDate
}

fun formatMessageTimestampHeader(
    epochMs: Long,
    @Suppress("UNUSED_PARAMETER") nowMs: Long = System.currentTimeMillis(),
    zoneId: ZoneId = ZoneId.systemDefault(),
    locale: Locale = Locale.getDefault()
): String {
    if (epochMs <= 0L) return ""
    return Instant.ofEpochMilli(epochMs)
        .atZone(zoneId)
        .format(DateTimeFormatter.ofPattern("M/d/yy", locale))
}

fun formatReceiptTime(
    epochMs: Long,
    zoneId: ZoneId = ZoneId.systemDefault(),
    locale: Locale = Locale.getDefault()
): String {
    if (epochMs <= 0L) return ""
    return Instant.ofEpochMilli(epochMs)
        .atZone(zoneId)
        .format(DateTimeFormatter.ofPattern("h:mm a", locale))
}

fun formatDetailTimestamp(
    epochMs: Long,
    nowMs: Long = System.currentTimeMillis(),
    zoneId: ZoneId = ZoneId.systemDefault(),
    locale: Locale = Locale.getDefault()
): String {
    if (epochMs <= 0L) return ""
    val elapsedMs = (nowMs - epochMs).coerceAtLeast(0L)
    if (elapsedMs < 60_000L) return "Now"
    if (elapsedMs < 3_600_000L) return "${elapsedMs / 60_000L} min"
    val target = Instant.ofEpochMilli(epochMs).atZone(zoneId)
    val targetDate = target.toLocalDate()
    val today = Instant.ofEpochMilli(nowMs).atZone(zoneId).toLocalDate()
    val timePart = target.format(DateTimeFormatter.ofPattern("h:mm a", locale))
    val elapsedDays = elapsedMs / 86_400_000L
    return when {
        targetDate == today -> timePart
        elapsedDays <= 7L -> "${target.format(DateTimeFormatter.ofPattern("EEE", locale))} $timePart"
        elapsedDays <= 365L -> "${target.format(DateTimeFormatter.ofPattern("MMM d", locale))}, $timePart"
        else -> target.format(DateTimeFormatter.ofPattern("M/d/yy", locale))
    }
}

fun nextDetailTimestampTickDelayMs(
    epochMs: Long,
    nowMs: Long = System.currentTimeMillis()
): Long? {
    if (epochMs <= 0L) return null
    val elapsedMs = (nowMs - epochMs).coerceAtLeast(0L)
    if (elapsedMs >= 3_600_000L) return null
    val nextBoundaryElapsedMs = (elapsedMs / 60_000L + 1L) * 60_000L
    return (nextBoundaryElapsedMs - elapsedMs).coerceAtLeast(1L)
}

internal fun nextDisplayedTimestampTickDelayMs(
    messages: List<MessageUi>,
    expandedMessageGuid: String?,
    nowMs: Long = System.currentTimeMillis()
): Long? = messages.asSequence()
    .filter { msg ->
        msg.isLastReadOutgoing ||
            msg.isLastDeliveredOutgoing ||
            msg.isLastSentOutgoing ||
            msg.isLatestOutgoing ||
            msg.isLatestIncoming ||
            msg.guid == expandedMessageGuid
    }
    .filterNot { it.sendFailed || MessageDao.isTempPlaceholderGuid(it.guid) }
    .mapNotNull { msg ->
        val ts = when {
            msg.dateRead > 0L -> msg.dateRead
            msg.dateDelivered > 0L -> msg.dateDelivered
            else -> msg.dateCreated
        }
        nextDetailTimestampTickDelayMs(ts, nowMs)
    }
    .minOrNull()

enum class MessageDetailKind {
    FAILED,
    SENDING,
    READ,
    DELIVERED,
    SENT,
    RECEIVED,
    EDITED
}

data class MessageDetailStatus(
    val kind: MessageDetailKind,
    val label: String,
    val showAlways: Boolean
)

data class MessageReceiptCandidate(
    val guid: String,
    val isFromMe: Boolean,
    val sendFailed: Boolean,
    val isPending: Boolean,
    val dateRead: Long,
    val dateDelivered: Long = 0L,
    val dateCreated: Long = 0L
)

data class MessageReceiptFlags(
    val latestOutgoingGuid: String?,
    val lastReadOutgoingGuid: String?,
    val lastDeliveredOutgoingGuid: String? = null,
    val lastSentOutgoingGuid: String? = null,
    val latestIncomingGuid: String?
)

private fun isReceiptWinnerNewer(
    candidateDate: Long,
    candidateCreated: Long,
    candidateIndex: Int,
    currentDate: Long,
    currentCreated: Long,
    currentIndex: Int
): Boolean {
    if (candidateDate != currentDate) return candidateDate > currentDate
    if (candidateCreated != currentCreated) return candidateCreated > currentCreated
    return candidateIndex > currentIndex
}

private fun isMessageNewerThan(
    aCreated: Long,
    aIndex: Int,
    bCreated: Long,
    bIndex: Int
): Boolean = if (aCreated != bCreated) aCreated > bCreated else aIndex > bIndex

fun computeMessageReceiptFlags(items: List<MessageReceiptCandidate>): MessageReceiptFlags {
    var readIdx = -1
    var deliveredIdx = -1
    var sentIdx = -1
    var incomingIdx = -1

    items.forEachIndexed { index, item ->
        if (item.sendFailed || item.isPending) return@forEachIndexed
        if (!item.isFromMe) {
            if (incomingIdx < 0 || isMessageNewerThan(item.dateCreated, index, items[incomingIdx].dateCreated, incomingIdx)) {
                incomingIdx = index
            }
            return@forEachIndexed
        }
        when {
            item.dateRead > 0L -> {
                if (readIdx < 0 || isReceiptWinnerNewer(
                        item.dateRead, item.dateCreated, index,
                        items[readIdx].dateRead, items[readIdx].dateCreated, readIdx
                    )
                ) {
                    readIdx = index
                }
            }
            item.dateDelivered > 0L -> {
                if (deliveredIdx < 0 || isReceiptWinnerNewer(
                        item.dateDelivered, item.dateCreated, index,
                        items[deliveredIdx].dateDelivered, items[deliveredIdx].dateCreated, deliveredIdx
                    )
                ) {
                    deliveredIdx = index
                }
            }
            else -> {
                if (sentIdx < 0 || isMessageNewerThan(item.dateCreated, index, items[sentIdx].dateCreated, sentIdx)) {
                    sentIdx = index
                }
            }
        }
    }

    // Match Flutter MessagesService._recomputeDeliveredIndicators: a newer Read
    // supersedes an older Delivered; a newer Read or Delivered supersedes Sent.
    if (deliveredIdx >= 0 && readIdx >= 0 &&
        isMessageNewerThan(items[readIdx].dateCreated, readIdx, items[deliveredIdx].dateCreated, deliveredIdx)
    ) {
        deliveredIdx = -1
    }
    if (sentIdx >= 0) {
        val supersededByRead = readIdx >= 0 &&
            isMessageNewerThan(items[readIdx].dateCreated, readIdx, items[sentIdx].dateCreated, sentIdx)
        val supersededByDelivered = deliveredIdx >= 0 &&
            isMessageNewerThan(items[deliveredIdx].dateCreated, deliveredIdx, items[sentIdx].dateCreated, sentIdx)
        if (supersededByRead || supersededByDelivered) {
            sentIdx = -1
        }
    }

    return MessageReceiptFlags(
        latestOutgoingGuid = items.lastOrNull { it.isFromMe }?.guid,
        lastReadOutgoingGuid = items.getOrNull(readIdx)?.guid,
        lastDeliveredOutgoingGuid = items.getOrNull(deliveredIdx)?.guid,
        lastSentOutgoingGuid = items.getOrNull(sentIdx)?.guid,
        latestIncomingGuid = items.getOrNull(incomingIdx)?.guid
    )
}

fun resolveMessageDetailStatus(
    isFromMe: Boolean,
    sendFailed: Boolean,
    isPending: Boolean,
    dateCreated: Long,
    dateDelivered: Long,
    dateRead: Long,
    isLatestOutgoing: Boolean = false,
    isLastReadOutgoing: Boolean = false,
    isLastDeliveredOutgoing: Boolean = false,
    isLastSentOutgoing: Boolean = false,
    isLatestIncoming: Boolean = false,
    dateEdited: Long = 0L,
    isExpanded: Boolean = false,
    nowMs: Long = System.currentTimeMillis(),
    zoneId: ZoneId = ZoneId.systemDefault(),
    locale: Locale = Locale.getDefault()
): MessageDetailStatus? {
    if (sendFailed) {
        return MessageDetailStatus(
            kind = MessageDetailKind.FAILED,
            label = "Not sent · Tap",
            showAlways = true
        )
    }
    if (isFromMe && isPending) {
        return MessageDetailStatus(
            kind = MessageDetailKind.SENDING,
            label = "Sending…",
            showAlways = true
        )
    }

    val isEdited = dateEdited > 0L
    val base = if (isFromMe) {
        when {
            dateRead > 0L -> {
                val time = formatDetailTimestamp(dateRead, nowMs, zoneId, locale)
                MessageDetailStatus(
                    kind = MessageDetailKind.READ,
                    label = if (time.isNotBlank()) "Read · $time" else "Read",
                    showAlways = isLastReadOutgoing
                )
            }
            dateDelivered > 0L -> {
                val time = formatDetailTimestamp(dateDelivered, nowMs, zoneId, locale)
                MessageDetailStatus(
                    kind = MessageDetailKind.DELIVERED,
                    label = if (time.isNotBlank()) "Delivered · $time" else "Delivered",
                    showAlways = isLastDeliveredOutgoing
                )
            }
            else -> {
                val time = formatDetailTimestamp(dateCreated, nowMs, zoneId, locale)
                MessageDetailStatus(
                    kind = MessageDetailKind.SENT,
                    label = if (time.isNotBlank()) "Sent · $time" else "Sent",
                    showAlways = isLastSentOutgoing
                )
            }
        }
    } else {
        val time = formatDetailTimestamp(dateCreated, nowMs, zoneId, locale)
        MessageDetailStatus(
            kind = MessageDetailKind.RECEIVED,
            label = if (time.isNotBlank()) "Received · $time" else "Received",
            showAlways = isLatestIncoming
        )
    }

    if (!isEdited) return base
    return if (base.showAlways || isExpanded) {
        base.copy(label = "Edited · ${base.label}", showAlways = true)
    } else {
        MessageDetailStatus(
            kind = MessageDetailKind.EDITED,
            label = "Edited",
            showAlways = true
        )
    }
}
