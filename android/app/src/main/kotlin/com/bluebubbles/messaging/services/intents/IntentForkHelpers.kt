package com.bluebubbles.messaging.services.intents

import android.app.Notification
import android.net.Uri
import com.bluebubbles.messaging.Constants

private val REACTION_ACTION_TITLES = setOf("Like", "Love", "Un-Like", "Un-Love", "Sending...", "Error - Retry")

internal fun resolveFirstDataResult(dataResults: Map<String, Uri>?): Pair<String, Uri>? =
    dataResults?.entries?.firstOrNull { it.key.isNotBlank() }?.let { it.key to it.value }

internal fun extensionForMime(mimeType: String): String = when {
    mimeType.contains("png", ignoreCase = true) -> "png"
    mimeType.contains("gif", ignoreCase = true) -> "gif"
    mimeType.contains("webp", ignoreCase = true) -> "webp"
    else -> "jpg"
}

internal fun reactionButtonTitle(reactionType: String, reactionSent: Boolean): String = when {
    reactionType == "love" && reactionSent -> "Un-Love"
    reactionType == "love" -> "Love"
    reactionType == "like" && reactionSent -> "Un-Like"
    else -> "Like"
}

internal fun matchesMessageNotification(tag: String?, id: Int, targetId: Int): Boolean =
    tag == Constants.newMessageNotificationTag && id == targetId

internal fun isReactionAction(title: String?, semanticAction: Int?): Boolean =
    semanticAction == Notification.Action.SEMANTIC_ACTION_THUMBS_UP ||
        (title != null && title in REACTION_ACTION_TITLES)

internal fun <T> replaceReactionAction(
    actions: List<T>,
    newReactionAction: T,
    predicate: (T) -> Boolean
): List<T> {
    var replaced = false
    val result = actions.map { action ->
        if (!replaced && predicate(action)) {
            replaced = true
            newReactionAction
        } else {
            action
        }
    }
    return if (replaced) result else result + newReactionAction
}

/**
 * ADB-only provisioning receiver (manifest-gated by android.permission.DUMP,
 * which is signature|privileged|development and granted only to system/shell).
 * Updates customHeaders in FlutterSharedPreferences, syncs to paired Wear OS
 * watch, and refreshes the foreground socket without logging secret values.
 */
class AdbProvisionReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(context: android.content.Context?, intent: android.content.Intent?) {
        if (context == null || intent?.action != "com.bluebubbles.messaging.ADB_SET_CUSTOM_HEADERS") return
        val b64 = intent.getStringExtra("headers_b64") ?: return
        try {
            val raw = String(android.util.Base64.decode(b64, android.util.Base64.DEFAULT), Charsets.UTF_8)
            val obj = org.json.JSONObject(raw)
            val clean = org.json.JSONObject()
            val keys = mutableListOf<String>()
            obj.keys().forEach { k ->
                val v = obj.optString(k, "").trim()
                if (k.isNotBlank() && v.isNotEmpty()) {
                    clean.put(k.trim(), v)
                    keys.add(k.trim())
                }
            }
            val prefs = context.getSharedPreferences("FlutterSharedPreferences", android.content.Context.MODE_PRIVATE)
            prefs.edit().putString("customHeaders", clean.toString()).commit()
            com.bluebubbles.messaging.services.wear.WearSyncManager.syncCredentials(context.applicationContext)
            if (prefs.getBoolean("keepAppAlive", false)) {
                val restart = android.content.Intent(
                    context,
                    com.bluebubbles.messaging.services.foreground.SocketIOForegroundService::class.java
                )
                context.stopService(restart)
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                    context.startForegroundService(restart)
                } else {
                    context.startService(restart)
                }
            }
            com.bluebubbles.messaging.utils.PersistentLog.i(
                context, Constants.logTag, "Provisioned customHeaders keys=${keys.joinToString(",")}"
            )
        } catch (e: Exception) {
            com.bluebubbles.messaging.utils.PersistentLog.e(
                context, Constants.logTag, "AdbProvisionReceiver failed: ${e.javaClass.simpleName}"
            )
        }
    }
}
