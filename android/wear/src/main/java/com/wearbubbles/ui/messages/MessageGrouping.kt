package com.wearbubbles.ui.messages

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.unit.dp
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
