package com.wearbubbles.data

import com.google.gson.Gson
import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.google.gson.JsonPrimitive
import com.google.gson.reflect.TypeToken
import com.wearbubbles.api.dto.AttachmentDto
import com.wearbubbles.api.dto.LinkPreviewDto
import com.wearbubbles.api.dto.MessageDto
import com.wearbubbles.api.dto.MessageRelayDto
import com.wearbubbles.db.entities.MessageEntity
import java.net.URI

object LinkPreviewHelper {
    const val URL_BALLOON_BUNDLE_ID = "com.apple.messages.URLBalloonProvider"

    private val gson = Gson()
    private val attachmentListType = object : TypeToken<List<AttachmentDto>>() {}.type

    private val HTTP_URL_REGEX = Regex("""https?://[^\s<>"'\)\]]+""", RegexOption.IGNORE_CASE)

    fun isPluginPayloadAttachment(transferName: String?): Boolean =
        transferName?.contains("pluginPayloadAttachment", ignoreCase = true) == true

    fun serializeAttachments(attachments: List<AttachmentDto>?): String? {
        val valid = attachments?.filter { it.guid.isNotBlank() }.orEmpty()
        if (valid.isEmpty()) return null
        return gson.toJson(valid.map {
            AttachmentDto(
                guid = it.guid,
                mimeType = it.mimeType?.takeIf { m -> m.isNotBlank() },
                transferName = it.transferName?.takeIf { n -> n.isNotBlank() }
            )
        })
    }

    fun parseAttachments(
        attachmentsJson: String?,
        fallbackGuid: String? = null,
        fallbackMimeType: String? = null
    ): List<AttachmentDto> {
        if (!attachmentsJson.isNullOrBlank()) {
            try {
                val parsed: List<AttachmentDto>? = gson.fromJson(attachmentsJson, attachmentListType)
                val valid = parsed?.filter { it.guid.isNotBlank() }.orEmpty()
                if (valid.isNotEmpty()) return valid
            } catch (_: Exception) {
            }
        }
        return if (!fallbackGuid.isNullOrBlank()) {
            listOf(AttachmentDto(guid = fallbackGuid, mimeType = fallbackMimeType))
        } else {
            emptyList()
        }
    }

    fun serializeLinkPreview(preview: LinkPreviewDto?): String? {
        if (preview == null) return null
        val hasContent = !preview.title.isNullOrBlank() ||
            !preview.subtitle.isNullOrBlank() ||
            !preview.url.isNullOrBlank() ||
            !preview.site.isNullOrBlank() ||
            !preview.imageAttachmentGuid.isNullOrBlank() ||
            !preview.imageUrl.isNullOrBlank() ||
            !preview.iconUrl.isNullOrBlank()
        return if (hasContent) gson.toJson(preview) else null
    }

    fun parseLinkPreview(json: String?): LinkPreviewDto? {
        if (json.isNullOrBlank()) return null
        return try {
            gson.fromJson(json, LinkPreviewDto::class.java)
        } catch (_: Exception) {
            null
        }
    }

    fun relayDtoToEntity(dto: MessageRelayDto, fallbackChatGuid: String = ""): MessageEntity {
        val attachments = dto.attachments?.filter { it.guid.isNotBlank() }.orEmpty()
        val primaryAtt = attachments.firstOrNull { !isPluginPayloadAttachment(it.transferName) }
            ?: attachments.firstOrNull()
        val primaryGuid = dto.attachmentGuid?.takeIf { it.isNotBlank() } ?: primaryAtt?.guid
        val primaryMime = dto.attachmentMimeType?.takeIf { it.isNotBlank() } ?: primaryAtt?.mimeType
        val linkPreview = dto.linkPreview ?: extractFromPayload(
            balloonBundleId = dto.balloonBundleId,
            payloadData = null,
            attachments = attachments,
            text = dto.text
        )
        return MessageEntity(
            guid = dto.guid,
            chatGuid = dto.chatGuid.ifBlank { fallbackChatGuid },
            text = dto.text,
            isFromMe = dto.isFromMe,
            dateCreated = dto.dateCreated,
            handleAddress = dto.handleAddress,
            attachmentGuid = primaryGuid,
            attachmentMimeType = primaryMime,
            associatedMessageGuid = dto.associatedMessageGuid,
            associatedMessageType = dto.associatedMessageType,
            associatedMessageEmoji = dto.associatedMessageEmoji,
            dateDelivered = dto.dateDelivered,
            dateRead = dto.dateRead,
            translatedText = dto.translatedText?.takeIf { it.isNotBlank() },
            translationSourceLang = dto.translationSourceLang,
            translationTargetLang = dto.translationTargetLang,
            dateEdited = dto.dateEdited,
            attachmentsJson = serializeAttachments(attachments),
            balloonBundleId = dto.balloonBundleId?.takeIf { it.isNotBlank() },
            linkPreviewJson = serializeLinkPreview(linkPreview)
        )
    }

    fun messageDtoToEntity(dto: MessageDto, chatGuid: String): MessageEntity {
        val attachments = dto.attachments?.filter { it.guid.isNotBlank() }.orEmpty()
        val primaryAtt = attachments.firstOrNull { !isPluginPayloadAttachment(it.transferName) }
            ?: attachments.firstOrNull()
        val linkPreview = extractFromPayload(
            balloonBundleId = dto.balloonBundleId,
            payloadData = dto.payloadData,
            attachments = attachments,
            text = dto.text
        )
        return MessageEntity(
            guid = dto.guid,
            chatGuid = chatGuid,
            text = dto.text,
            isFromMe = dto.isFromMe,
            dateCreated = dto.dateCreated,
            handleAddress = dto.handle?.address,
            attachmentGuid = primaryAtt?.guid,
            attachmentMimeType = primaryAtt?.mimeType,
            associatedMessageGuid = dto.associatedMessageGuid,
            associatedMessageType = dto.associatedMessageType,
            associatedMessageEmoji = dto.associatedMessageEmoji,
            dateDelivered = dto.dateDelivered,
            dateRead = dto.dateRead,
            translatedText = dto.translation?.text?.takeIf { it.isNotBlank() },
            translationSourceLang = dto.translation?.sourceLanguage,
            translationTargetLang = dto.translation?.targetLanguage,
            dateEdited = dto.dateEdited,
            attachmentsJson = serializeAttachments(attachments),
            balloonBundleId = dto.balloonBundleId?.takeIf { it.isNotBlank() },
            linkPreviewJson = serializeLinkPreview(linkPreview)
        )
    }

    fun extractFirstHttpUrl(text: String?): String? {
        if (text.isNullOrBlank()) return null
        val raw = HTTP_URL_REGEX.find(text)?.value ?: return null
        val trimmed = raw.trimEnd('.', ',', ';', ':', '!', '?')
        return trimmed.takeIf { isHttpScheme(it) && !deriveSiteHost(it).isNullOrBlank() }
    }

    fun deriveSiteHost(url: String?, fallbackSiteName: String? = null): String? {
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

    fun showsSiteLine(title: String?, site: String?): Boolean {
        val s = site?.trim()?.takeIf { it.isNotEmpty() } ?: return false
        val t = title?.trim()?.takeIf { it.isNotEmpty() } ?: return true
        return !t.equals(s, ignoreCase = true)
    }

    fun shouldHideBareUrlText(text: String?, linkUrl: String?): Boolean {
        val trimmed = text?.trim()?.takeIf { it.isNotEmpty() } ?: return false
        val url = linkUrl?.trim()?.takeIf { it.isNotEmpty() } ?: return false
        return trimmed == url || trimmed.trimEnd('/') == url.trimEnd('/')
    }

    fun extractFromPayload(
        balloonBundleId: String?,
        payloadData: JsonElement?,
        attachments: List<AttachmentDto>?,
        text: String?
    ): LinkPreviewDto? {
        val isUrlBalloon = balloonBundleId == URL_BALLOON_BUNDLE_ID
        val payloadObj = parseUrlPayload(payloadData, isUrlBalloon)

        var title = payloadObj?.str("title")?.takeIf { it.isNotBlank() }
            ?: payloadObj?.obj("specialization")?.str("name")?.takeIf { it.isNotBlank() }
        var subtitle = payloadObj?.str("summary")?.takeIf { it.isNotBlank() }
            ?: payloadObj?.obj("specialization")?.str("album")?.takeIf { it.isNotBlank() }
        val siteName = payloadObj?.str("siteName")?.takeIf { it.isNotBlank() }
        val originalUrl = payloadObj?.obj("originalURL")?.str("NS.relative")?.takeIf { it.isNotBlank() }
        val payloadUrl = payloadObj?.obj("URL")?.str("NS.relative")?.takeIf { it.isNotBlank() }
        val imageUrl = payloadObj?.obj("imageMetadata")?.obj("URL")?.str("NS.relative")?.takeIf { it.isNotBlank() }
            ?: payloadObj?.obj("specialization")?.obj("artwork")?.str("NS.relative")?.takeIf { it.isNotBlank() }
        val iconUrl = payloadObj?.obj("iconMetadata")?.obj("URL")?.str("NS.relative")?.takeIf { it.isNotBlank() }

        val targetUrl = listOf(originalUrl, payloadUrl, extractFirstHttpUrl(text))
            .firstOrNull { !it.isNullOrBlank() && isHttpScheme(it) }

        val pluginAttGuid = attachments?.firstOrNull { isPluginPayloadAttachment(it.transferName) }?.guid
            ?.takeIf { it.isNotBlank() }
            ?: if (isUrlBalloon) {
                attachments?.firstOrNull { it.mimeType?.startsWith("image/") == true }?.guid?.takeIf { it.isNotBlank() }
            } else null

        if (!isUrlBalloon && targetUrl == null && title == null && imageUrl == null && pluginAttGuid == null) {
            return null
        }

        val site = deriveSiteHost(targetUrl, siteName)
        if (title == null && subtitle != null) {
            title = subtitle
            subtitle = null
        }

        val dto = LinkPreviewDto(
            title = title,
            subtitle = subtitle,
            url = targetUrl,
            site = site,
            imageAttachmentGuid = pluginAttGuid,
            imageUrl = imageUrl,
            iconUrl = iconUrl
        )
        return if (serializeLinkPreview(dto) != null) dto else null
    }

    private fun isHttpScheme(url: String): Boolean {
        val lower = url.trim().lowercase()
        return lower.startsWith("http://") || lower.startsWith("https://")
    }

    // Paired NSKeyedArchiver decoder lives in android/app/src/main/kotlin/com/bluebubbles/messaging/services/wear/WearLinkPreview.kt (phone relay).
    private fun parseUrlPayload(raw: JsonElement?, forceUrlBalloon: Boolean): JsonObject? {
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
