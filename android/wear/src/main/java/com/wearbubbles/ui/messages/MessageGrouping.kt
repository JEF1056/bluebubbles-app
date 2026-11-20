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
    return when (targetDate) {
        today -> timePart
        today.minusDays(1) -> "Yesterday $timePart"
        else -> "${target.format(DateTimeFormatter.ofPattern("MMM d", locale))}, $timePart"
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
        msg.isLatestOutgoing ||
            msg.isLastReadOutgoing ||
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
    RECEIVED
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
    val dateRead: Long
)

data class MessageReceiptFlags(
    val latestOutgoingGuid: String?,
    val lastReadOutgoingGuid: String?,
    val latestIncomingGuid: String?
)

fun computeMessageReceiptFlags(items: List<MessageReceiptCandidate>): MessageReceiptFlags =
    MessageReceiptFlags(
        latestOutgoingGuid = items.lastOrNull { it.isFromMe }?.guid,
        lastReadOutgoingGuid = items.lastOrNull {
            it.isFromMe && !it.sendFailed && !it.isPending && it.dateRead > 0L
        }?.guid,
        latestIncomingGuid = items.lastOrNull {
            !it.isFromMe && !it.sendFailed && !it.isPending
        }?.guid
    )

fun resolveMessageDetailStatus(
    isFromMe: Boolean,
    sendFailed: Boolean,
    isPending: Boolean,
    dateCreated: Long,
    dateDelivered: Long,
    dateRead: Long,
    isLatestOutgoing: Boolean,
    isLastReadOutgoing: Boolean,
    isLatestIncoming: Boolean,
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
    if (isFromMe) {
        if (isPending) {
            return if (isLatestOutgoing) {
                MessageDetailStatus(
                    kind = MessageDetailKind.SENDING,
                    label = "Sending…",
                    showAlways = true
                )
            } else {
                null
            }
        }
        return when {
            dateRead > 0L -> {
                val time = formatDetailTimestamp(dateRead, nowMs, zoneId, locale)
                MessageDetailStatus(
                    kind = MessageDetailKind.READ,
                    label = if (time.isNotBlank()) "Read · $time" else "Read",
                    showAlways = isLatestOutgoing || isLastReadOutgoing
                )
            }
            dateDelivered > 0L -> {
                val time = formatDetailTimestamp(dateDelivered, nowMs, zoneId, locale)
                MessageDetailStatus(
                    kind = MessageDetailKind.DELIVERED,
                    label = if (time.isNotBlank()) "Delivered · $time" else "Delivered",
                    showAlways = isLatestOutgoing
                )
            }
            else -> {
                val time = formatDetailTimestamp(dateCreated, nowMs, zoneId, locale)
                MessageDetailStatus(
                    kind = MessageDetailKind.SENT,
                    label = if (time.isNotBlank()) "Sent · $time" else "Sent",
                    showAlways = isLatestOutgoing
                )
            }
        }
    }
    val time = formatDetailTimestamp(dateCreated, nowMs, zoneId, locale)
    return MessageDetailStatus(
        kind = MessageDetailKind.RECEIVED,
        label = if (time.isNotBlank()) "Received · $time" else "Received",
        showAlways = isLatestIncoming
    )
}
