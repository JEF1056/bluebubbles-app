package com.bluebubbles.messaging.services.system

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.ContactsContract
import androidx.core.app.Person
import androidx.core.content.ContextCompat
import androidx.core.content.LocusIdCompat
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.MainActivity
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import com.bluebubbles.messaging.utils.PersistentLog
import com.bluebubbles.messaging.utils.Utils
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/// Create android share sheet targets
class PushShareTargetsHandler: MethodCallHandlerImpl() {
    companion object {
        const val tag = "push-share-targets"
        private const val LOOKUP_CACHE_TTL_MS = 10 * 60 * 1000L
        private const val LOOKUP_CACHE_MAX_SIZE = 256

        private data class CachedLookup(val uri: String?, val expiresAtMs: Long)

        private val contactLookupCache = ConcurrentHashMap<String, CachedLookup>()
        private val pushedShortcutFingerprints = ConcurrentHashMap<String, Int>()
        @Volatile
        private var persistedShortcutIds: MutableSet<String>? = null
        private val shortcutExecutor = Executors.newSingleThreadExecutor { r ->
            Thread(r, "bb-shortcut-push").apply { isDaemon = true }
        }

        internal fun computeShortcutFingerprint(
            name: String,
            resolvedUri: String?,
            iconHash: Int,
            participantCount: Int
        ): Int {
            var h = name.hashCode()
            h = 31 * h + (resolvedUri?.hashCode() ?: 0)
            h = 31 * h + iconHash
            h = 31 * h + participantCount
            return h
        }

        internal fun shouldSkipShortcutPush(
            guid: String,
            fingerprint: Int,
            fingerprints: Map<String, Int> = pushedShortcutFingerprints
        ): Boolean = fingerprints[guid] == fingerprint

        // Non-blocking cache read for secondary group participants on the notification hot path.
        fun resolveContactLookupUriIfCached(
            nativeContactId: String?,
            fallbackUri: String?
        ): String? {
            val cacheKey = "${nativeContactId.orEmpty()}|${fallbackUri.orEmpty()}"
            val cached = contactLookupCache[cacheKey] ?: return null
            return if (System.currentTimeMillis() < cached.expiresAtMs) cached.uri else null
        }

        // Cached in-memory for 10m to avoid repeated ContentResolver Binder IPC on incoming messages.
        fun resolveContactLookupUri(
            context: Context,
            nativeContactId: String?,
            fallbackUri: String?
        ): String? {
            val cacheKey = "${nativeContactId.orEmpty()}|${fallbackUri.orEmpty()}"
            val now = System.currentTimeMillis()
            contactLookupCache[cacheKey]?.let { cached ->
                if (now < cached.expiresAtMs) return cached.uri
                contactLookupCache.remove(cacheKey)
            }
            val resolved = resolveContactLookupUriUncached(context, nativeContactId, fallbackUri)
            if (contactLookupCache.size >= LOOKUP_CACHE_MAX_SIZE) {
                contactLookupCache.clear()
            }
            contactLookupCache[cacheKey] = CachedLookup(resolved, now + LOOKUP_CACHE_TTL_MS)
            return resolved
        }

        private fun resolveContactLookupUriUncached(
            context: Context,
            nativeContactId: String?,
            fallbackUri: String?
        ): String? {
            if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) {
                return fallbackUri
            }
            if (!nativeContactId.isNullOrEmpty()) {
                try {
                    val cursor = context.contentResolver.query(
                        ContactsContract.Contacts.CONTENT_URI,
                        arrayOf(ContactsContract.Contacts._ID, ContactsContract.Contacts.LOOKUP_KEY),
                        "${ContactsContract.Contacts._ID} = ?",
                        arrayOf(nativeContactId),
                        null
                    )
                    cursor?.use {
                        if (it.moveToFirst()) {
                            val idCol = it.getColumnIndex(ContactsContract.Contacts._ID)
                            val lookupCol = it.getColumnIndex(ContactsContract.Contacts.LOOKUP_KEY)
                            if (idCol >= 0 && lookupCol >= 0) {
                                val lookupKey = it.getString(lookupCol)
                                if (!lookupKey.isNullOrEmpty()) {
                                    ContactsContract.Contacts.getLookupUri(it.getLong(idCol), lookupKey)
                                        ?.let { uri -> return uri.toString() }
                                }
                            }
                        }
                    }
                } catch (e: Exception) {
                    PersistentLog.w(context, Constants.logTag, "Failed to resolve contact lookup URI for id=$nativeContactId: ${e.message}")
                }
            }
            // Fallback: resolve tel:/mailto: directly via Android Contacts so DND Starred Contacts matches even for server-only ContactV2 entries
            if (!fallbackUri.isNullOrEmpty()) {
                try {
                    val (queryUri, idColumn) = when {
                        fallbackUri.startsWith("tel:") -> Pair(
                            Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(fallbackUri.removePrefix("tel:"))),
                            ContactsContract.PhoneLookup._ID
                        )
                        fallbackUri.startsWith("mailto:") -> Pair(
                            Uri.withAppendedPath(ContactsContract.CommonDataKinds.Email.CONTENT_FILTER_URI, Uri.encode(fallbackUri.removePrefix("mailto:"))),
                            ContactsContract.CommonDataKinds.Email.CONTACT_ID
                        )
                        else -> null
                    } ?: return fallbackUri
                    context.contentResolver.query(
                        queryUri,
                        arrayOf(idColumn, ContactsContract.Contacts.LOOKUP_KEY),
                        null, null, null
                    )?.use {
                        if (it.moveToFirst()) {
                            val idCol = it.getColumnIndex(idColumn)
                            val lookupCol = it.getColumnIndex(ContactsContract.Contacts.LOOKUP_KEY)
                            if (idCol >= 0 && lookupCol >= 0) {
                                val lookupKey = it.getString(lookupCol)
                                if (!lookupKey.isNullOrEmpty()) {
                                    ContactsContract.Contacts.getLookupUri(it.getLong(idCol), lookupKey)
                                        ?.let { uri -> return uri.toString() }
                                }
                            }
                        }
                    }
                } catch (e: Exception) {
                    PersistentLog.w(context, Constants.logTag, "Failed to resolve contact lookup URI for uri=$fallbackUri: ${e.message}")
                }
            }
            return fallbackUri
        }

        private fun getPersistedShortcutIds(context: Context): MutableSet<String> {
            persistedShortcutIds?.let { return it }
            val set = ConcurrentHashMap.newKeySet<String>()
            try {
                ShortcutManagerCompat.getDynamicShortcuts(context).forEach { set.add(it.id) }
            } catch (_: Exception) {
                // Fall back to empty set; next push will populate it
            }
            persistedShortcutIds = set
            return set
        }
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val name: String = call.argument("title")!!
        val guid: String = call.argument("guid")!!
        val icon: ByteArray? = call.argument("icon")
        val contactUri: String? = call.argument("contact_uri")
        val contactKey: String? = call.argument("contact_key")
        val nativeContactId: String? = call.argument("native_contact_id")
        val rawParticipants: List<Map<String, Any?>>? = call.argument("participants")
        val participants = rawParticipants?.mapNotNull { p ->
            val pName = p["name"] as? String ?: return@mapNotNull null
            val pKey = p["key"] as? String
            val pUri = resolveContactLookupUri(context, p["native_contact_id"] as? String, p["uri"] as? String)
            Person.Builder()
                .setName(pName)
                .setImportant(true)
                .apply {
                    if (!pUri.isNullOrEmpty()) setUri(pUri)
                    if (!pKey.isNullOrEmpty()) setKey(pKey)
                }
                .build()
        }
        pushShareTarget(context, name, guid, icon, contactUri, contactKey, nativeContactId, participants)
        result.success(null)
    }

    fun pushShareTarget(
        context: Context,
        name: String,
        guid: String,
        icon: ByteArray?,
        contactUri: String? = null,
        contactKey: String? = null,
        nativeContactId: String? = null,
        participants: List<Person>? = null,
        predecodedIcon: IconCompat? = null,
        alreadyResolvedUri: Boolean = false
    ) {
        val adaptiveIcon = predecodedIcon ?: if ((icon?.size ?: 0) == 0) null else Utils.getAdaptiveIconFromByteArray(icon!!)

        PersistentLog.d(context, Constants.logTag, "Creating intent for shortcut with name $name")
        val contactCategories = setOf(Constants.categoryTextShareTarget)
        val launcherIntent = Intent(context, MainActivity::class.java)
            .putExtra("chatGuid", guid)
            .putExtra("bubble", false)
            .setAction(Intent.ACTION_DEFAULT)
        val resolvedUri = if (alreadyResolvedUri) contactUri else resolveContactLookupUri(context, nativeContactId, contactUri)
        val person = Person.Builder()
            .setName(name)
            .setImportant(true)
        if (adaptiveIcon != null) {
            person.setIcon(adaptiveIcon)
        }
        if (!resolvedUri.isNullOrEmpty()) {
            person.setUri(resolvedUri)
        }
        if (!contactKey.isNullOrEmpty()) {
            person.setKey(contactKey)
        }

        PersistentLog.d(context, Constants.logTag, "Creating and pushing shortcut for $name")
        val shortcut = ShortcutInfoCompat.Builder(context, guid)
            .setShortLabel(name)
            .setIntent(launcherIntent)
            .setCategories(contactCategories)
            .setLongLived(true)
            .setIsConversation()
            .setLocusId(LocusIdCompat(guid))
        if (!participants.isNullOrEmpty()) {
            shortcut.setPersons(participants.toTypedArray())
        } else {
            shortcut.setPerson(person.build())
        }
        if (adaptiveIcon != null) {
            shortcut.setIcon(adaptiveIcon)
        }

        ShortcutManagerCompat.pushDynamicShortcut(context, shortcut.build())
        getPersistedShortcutIds(context).add(guid)
    }

    /**
     * Avoids blocking notification posting on repeated shortcut pushes:
     * skips unchanged shortcuts, refreshes existing persisted shortcuts off the main thread,
     * and only pushes synchronously for brand-new conversations.
     */
    fun ensureShareTargetForNotification(
        context: Context,
        name: String,
        guid: String,
        icon: ByteArray?,
        predecodedIcon: IconCompat?,
        resolvedSenderUri: String?,
        contactKey: String?,
        contactBitmap: IconCompat?,
        rawParticipants: List<Map<String, Any?>>?
    ) {
        val fingerprint = computeShortcutFingerprint(
            name = name,
            resolvedUri = resolvedSenderUri,
            iconHash = icon?.contentHashCode() ?: 0,
            participantCount = rawParticipants?.size ?: 0
        )
        if (shouldSkipShortcutPush(guid, fingerprint)) return
        pushedShortcutFingerprints[guid] = fingerprint

        val appCtx = context.applicationContext
        val work = Runnable {
            val participants = rawParticipants?.mapNotNull { p ->
                val pName = p["name"] as? String ?: return@mapNotNull null
                val pKey = p["key"] as? String
                val pUri = if (pKey != null && pKey == contactKey) {
                    resolvedSenderUri
                } else {
                    resolveContactLookupUri(appCtx, p["native_contact_id"] as? String, p["uri"] as? String)
                }
                val pIcon = if (pKey != null && pKey == contactKey) contactBitmap else null
                Person.Builder()
                    .setName(pName)
                    .setImportant(true)
                    .apply {
                        if (pIcon != null) setIcon(pIcon)
                        if (!pUri.isNullOrEmpty()) setUri(pUri)
                        if (!pKey.isNullOrEmpty()) setKey(pKey)
                    }
                    .build()
            }?.ifEmpty { null }
            pushShareTarget(
                context = appCtx,
                name = name,
                guid = guid,
                icon = icon,
                contactUri = resolvedSenderUri,
                contactKey = contactKey,
                participants = participants,
                predecodedIcon = predecodedIcon,
                alreadyResolvedUri = true
            )
        }

        if (getPersistedShortcutIds(appCtx).contains(guid)) {
            shortcutExecutor.execute(work)
        } else {
            work.run()
        }
    }
}