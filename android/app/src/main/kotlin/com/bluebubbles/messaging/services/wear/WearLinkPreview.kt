package com.bluebubbles.messaging.services.wear

import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.google.gson.JsonPrimitive
import java.net.URI

internal object WearLinkPreview {
    const val URL_BALLOON_BUNDLE_ID = "com.apple.messages.URLBalloonProvider"

    private val HTTP_URL_REGEX = Regex("""https?://[^\s<>"'\)\]]+""", RegexOption.IGNORE_CASE)

    internal fun isPluginPayloadAttachment(transferName: String?): Boolean =
        transferName?.contains("pluginPayloadAttachment", ignoreCase = true) == true

    internal fun extractFirstHttpUrl(text: String?): String? {
        if (text.isNullOrBlank()) return null
        val raw = HTTP_URL_REGEX.find(text)?.value ?: return null
        val trimmed = raw.trimEnd('.', ',', ';', ':', '!', '?')
        return trimmed.takeIf { isHttpScheme(it) && !deriveSiteHost(it).isNullOrBlank() }
    }

    internal fun deriveSiteHost(url: String?, fallbackSiteName: String? = null): String? {
        val host = url?.let {
            try {
                URI(it).host?.trim()?.removePrefix("www.")?.removePrefix("WWW.")
            } catch (_: Exception) {
                null
            }
        }?.takeIf { it.isNotBlank() }
        if (host != null) return host
        return fallbackSiteName?.trim()?.removePrefix("www.")?.takeIf { it.isNotBlank() }
    }

    internal fun extractLinkPreviewJson(msg: JsonObject, atts: JsonArray?): JsonObject? {
        val balloonId = msg.str("balloonBundleId")?.takeIf { it.isNotBlank() }
        val isUrlBalloon = balloonId == URL_BALLOON_BUNDLE_ID
        val text = msg.str("text")

        val payloadObj = parseUrlPayload(msg.get("payloadData"), isUrlBalloon)

        var title = payloadObj?.str("title")?.takeIf { it.isNotBlank() }
            ?: payloadObj?.obj("specialization")?.str("name")?.takeIf { it.isNotBlank() }
        var subtitle = payloadObj?.str("summary")?.takeIf { it.isNotBlank() }
            ?: payloadObj?.obj("specialization")?.str("album")?.takeIf { it.isNotBlank() }
        val siteName = payloadObj?.str("siteName")?.takeIf { it.isNotBlank() }
        val originalUrl = payloadObj?.obj("originalURL")?.str("NS.relative")?.takeIf { it.isNotBlank() }
        val payloadUrl = payloadObj?.obj("URL")?.str("NS.relative")?.takeIf { it.isNotBlank() }
        var imageUrl = payloadObj?.obj("imageMetadata")?.obj("URL")?.str("NS.relative")?.takeIf { it.isNotBlank() }
            ?: payloadObj?.obj("specialization")?.obj("artwork")?.str("NS.relative")?.takeIf { it.isNotBlank() }
        val iconUrl = payloadObj?.obj("iconMetadata")?.obj("URL")?.str("NS.relative")?.takeIf { it.isNotBlank() }

        val targetUrl = listOf(originalUrl, payloadUrl, extractFirstHttpUrl(text))
            .firstOrNull { !it.isNullOrBlank() && isHttpScheme(it) }

        val pluginAttGuid = findPluginAttachmentGuid(atts, isUrlBalloon)

        if (!isUrlBalloon && targetUrl == null && title == null && imageUrl == null && pluginAttGuid == null) {
            return null
        }

        val site = deriveSiteHost(targetUrl, siteName)
        if (title == null && subtitle != null) {
            // Avoid losing single-line payload text when summary exists without title.
            title = subtitle
            subtitle = null
        }

        val out = JsonObject().apply {
            title?.let { addProperty("title", it) }
            subtitle?.let { addProperty("subtitle", it) }
            targetUrl?.let { addProperty("url", it) }
            site?.let { addProperty("site", it) }
            pluginAttGuid?.let { addProperty("imageAttachmentGuid", it) }
            imageUrl?.let { addProperty("imageUrl", it) }
            iconUrl?.let { addProperty("iconUrl", it) }
        }
        return if (out.size() > 0) out else null
    }

    private fun findPluginAttachmentGuid(atts: JsonArray?, isUrlBalloon: Boolean): String? {
        if (atts == null || atts.size() == 0) return null
        var imageFallback: String? = null
        for (el in atts) {
            val obj = el.asObjOrNull() ?: continue
            val guid = obj.str("guid")?.takeIf { it.isNotBlank() } ?: continue
            if (isPluginPayloadAttachment(obj.str("transferName"))) return guid
            if (isUrlBalloon && imageFallback == null && obj.str("mimeType")?.startsWith("image/") == true) {
                imageFallback = guid
            }
        }
        return imageFallback
    }

    private fun isHttpScheme(url: String): Boolean {
        val lower = url.trim().lowercase()
        return lower.startsWith("http://") || lower.startsWith("https://")
    }

    // Paired NSKeyedArchiver decoder lives in android/wear/src/main/java/com/wearbubbles/data/LinkPreviewHelper.kt (direct-server mode).

    internal fun parseUrlPayload(raw: JsonElement?, forceUrlBalloon: Boolean): JsonObject? {
        val normalized = when {
            raw == null || raw.isJsonNull -> return null
            raw.isJsonPrimitive && raw.asJsonPrimitive.isString -> try {
                JsonParser.parseString(raw.asString)
            } catch (_: Exception) {
                return null
            }
            else -> raw
        }
        return when {
            normalized.isJsonObject -> {
                val obj = normalized.asJsonObject
                val urlData = obj.arr("urlData")
                if (urlData != null && urlData.size() > 0) {
                    urlData[0].asObjOrNull()
                } else if (obj.has("title") || obj.has("URL") || obj.has("originalURL") || obj.has("specialization")) {
                    obj
                } else null
            }
            normalized.isJsonArray -> decodeNsKeyedArchiverUrl(normalized.asJsonArray, forceUrlBalloon)
            else -> null
        }
    }

    private fun decodeNsKeyedArchiverUrl(arr: JsonArray, forceUrlBalloon: Boolean): JsonObject? {
        for (entry in arr) {
            val sanitized = stripDollarKeys(entry).asObjOrNull() ?: continue
            val objects = sanitized.arr("objects") ?: continue
            if (objects.size() <= 2) continue
            val obj1 = objects[1].asObjOrNull()
            if (!forceUrlBalloon && obj1 != null && obj1.has("NS.keys")) continue
            val resolved = extractUids(objects[2], objects, HashSet()).asObjOrNull()
            if (resolved != null) return resolved
        }
        return null
    }

    private fun stripDollarKeys(el: JsonElement, isValue: Boolean = false): JsonElement = when {
        el.isJsonArray -> JsonArray().apply {
            for (item in el.asJsonArray) add(stripDollarKeys(item, isValue = true))
        }
        el.isJsonObject -> JsonObject().apply {
            for ((k, v) in el.asJsonObject.entrySet()) {
                val cleanKey = if (k.startsWith("$")) k.substring(1) else k
                add(cleanKey, stripDollarKeys(v, isValue = true))
            }
        }
        el.isJsonPrimitive && !isValue && el.asJsonPrimitive.isString -> {
            val s = el.asString
            JsonPrimitive(if (s.startsWith("$")) s.substring(1) else s)
        }
        else -> el
    }

    private fun extractUids(el: JsonElement, objects: JsonArray, visited: MutableSet<Int>): JsonElement = when {
        el.isJsonArray -> JsonArray().apply {
            for (item in el.asJsonArray) add(extractUids(item, objects, visited))
        }
        el.isJsonObject -> {
            val obj = el.asJsonObject
            val uid = obj.int("UID") ?: obj.int("CF\$UID")
            if (uid != null) {
                if (uid in 0 until objects.size() && visited.add(uid)) {
                    val target = objects[uid]
                    val resolved = if (target.isJsonObject || target.isJsonArray) {
                        extractUids(target, objects, visited)
                    } else target
                    visited.remove(uid)
                    resolved
                } else {
                    JsonObject()
                }
            } else if (obj.str("archiver") == "NSKeyedArchiver") {
                val nestedObjs = obj.arr("objects") ?: return JsonObject()
                val root = if (nestedObjs.size() > 1) nestedObjs[1].asObjOrNull() else null
                if (root != null && root.has("NS.keys") && root.has("NS.objects")) {
                    extractNsDictionary(root, nestedObjs, HashSet())
                } else JsonObject()
            } else if (obj.has("NS.keys") && obj.has("NS.objects")) {
                extractNsDictionary(obj, objects, visited)
            } else {
                JsonObject().apply {
                    for ((k, v) in obj.entrySet()) {
                        add(k, if (v.isJsonObject || v.isJsonArray) extractUids(v, objects, visited) else v)
                    }
                }
            }
        }
        else -> el
    }

    private fun extractNsDictionary(obj: JsonObject, objects: JsonArray, visited: MutableSet<Int>): JsonObject {
        val out = JsonObject()
        for ((k, v) in obj.entrySet()) {
            if (k != "NS.keys" && k != "NS.objects") {
                out.add(k, if (v.isJsonObject || v.isJsonArray) extractUids(v, objects, visited) else v)
            }
        }
        val keys = obj.arr("NS.keys") ?: return out
        val vals = obj.arr("NS.objects") ?: return out
        val count = minOf(keys.size(), vals.size())
        for (i in 0 until count) {
            val kUid = keys[i].asObjOrNull()?.let { it.int("UID") ?: it.int("CF\$UID") } ?: continue
            val vUid = vals[i].asObjOrNull()?.let { it.int("UID") ?: it.int("CF\$UID") } ?: continue
            if (kUid !in 0 until objects.size() || vUid !in 0 until objects.size()) continue
            val keyStr = objects[kUid].takeIf { it.isJsonPrimitive }?.asString ?: continue
            val valEl = objects[vUid]
            val resolvedVal = if (visited.add(vUid)) {
                val r = extractUids(valEl, objects, visited)
                visited.remove(vUid)
                r
            } else valEl
            out.add(keyStr, resolvedVal)
        }
        return out
    }

    private fun JsonElement?.asObjOrNull(): JsonObject? = this?.takeIf { it.isJsonObject }?.asJsonObject
    private fun JsonObject.obj(key: String): JsonObject? = get(key)?.takeIf { it.isJsonObject }?.asJsonObject
    private fun JsonObject.arr(key: String): JsonArray? = get(key)?.takeIf { it.isJsonArray }?.asJsonArray
    private fun JsonObject.str(key: String): String? = get(key)?.takeIf { it.isJsonPrimitive }?.asString
    private fun JsonObject.int(key: String): Int? = try {
        get(key)?.takeIf { it.isJsonPrimitive }?.asInt
    } catch (_: Exception) {
        null
    }
}
