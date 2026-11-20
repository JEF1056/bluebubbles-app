package com.bluebubbles.messaging.services.notifications

import androidx.core.app.Person
import androidx.core.graphics.drawable.IconCompat
import java.util.Locale

internal fun resolveDismissedChatGuid(
    notificationChatGuid: String?,
    fallbackChatGuid: String?
): String? = notificationChatGuid?.takeIf { it.isNotEmpty() }
    ?: fallbackChatGuid?.takeIf { it.isNotEmpty() }

internal fun computeInboxSummary(
    childLines: List<String>,
    maxLines: Int = 5
): Pair<Int, List<String>> =
    childLines.size to childLines.filter { it.isNotBlank() }.takeLast(maxLines)

internal fun matchesNotification(
    sbnTag: String?,
    sbnId: Int,
    targetId: Int,
    targetTag: String?
): Boolean = sbnId == targetId && (targetTag == null || sbnTag == targetTag)

internal fun resolveTargetChannelId(
    baseChannelId: String,
    convChannelId: String?,
    convId: String?,
    chatGuid: String
): String = if (!convChannelId.isNullOrEmpty() && convId == chatGuid) {
    convChannelId
} else {
    baseChannelId
}

internal fun buildPerson(
    name: String,
    icon: IconCompat?,
    uri: String?,
    key: String?,
    isImportant: Boolean
): Person = Person.Builder()
    .setName(name)
    .setImportant(isImportant)
    .apply {
        if (icon != null) setIcon(icon)
        if (!uri.isNullOrEmpty()) setUri(uri)
        if (!key.isNullOrEmpty()) setKey(key)
    }
    .build()

internal fun buildSummaryLines(
    existingLines: List<String>,
    newLine: String,
    maxLines: Int = 5
): List<String> = buildList {
    existingLines.filterTo(this) { it.isNotBlank() }
    if (newLine.isNotBlank()) add(newLine)
}.takeLast(maxLines)

internal fun shouldOnlyAlertOnce(
    messageIsFromMe: Boolean,
    isReaction: Boolean,
    isEdit: Boolean,
    explicitOnlyAlertOnce: Boolean
): Boolean = messageIsFromMe || isReaction || isEdit || explicitOnlyAlertOnce

internal fun sortKeyForTimestamp(timestampMs: Long): String =
    String.format(Locale.US, "%019d", Long.MAX_VALUE - timestampMs.coerceAtLeast(0L))

internal fun shouldShowPhoneMuteAction(showReactionAction: Boolean): Boolean = !showReactionAction

internal fun resolveNotificationId(chatId: Int?, chatGuid: String): Int {
    if (chatId != null && chatId != 0) return chatId
    return (chatGuid.hashCode() and 0x7fffffff).let { if (it == 0) 1 else it }
}
