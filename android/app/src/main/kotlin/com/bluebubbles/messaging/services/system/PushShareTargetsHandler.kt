package com.bluebubbles.messaging.services.system

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.ContactsContract
import androidx.core.app.Person
import androidx.core.content.ContextCompat
import androidx.core.content.LocusIdCompat
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.MainActivity
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import com.bluebubbles.messaging.utils.PersistentLog
import com.bluebubbles.messaging.utils.Utils
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// Create android share sheet targets
class PushShareTargetsHandler: MethodCallHandlerImpl() {
    companion object {
        const val tag = "push-share-targets"

        fun resolveContactLookupUri(
            context: Context,
            nativeContactId: String?,
            fallbackUri: String?
        ): String? {
            if (!nativeContactId.isNullOrEmpty() &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED
            ) {
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
                                val contactIdLong = it.getLong(idCol)
                                val lookupKey = it.getString(lookupCol)
                                if (!lookupKey.isNullOrEmpty()) {
                                    val lookupUri = ContactsContract.Contacts.getLookupUri(contactIdLong, lookupKey)
                                    if (lookupUri != null) {
                                        return lookupUri.toString()
                                    }
                                }
                            }
                        }
                    }
                } catch (e: Exception) {
                    PersistentLog.w(context, Constants.logTag, "Failed to resolve contact lookup URI for id=$nativeContactId: ${e.message}")
                }
            }
            return fallbackUri
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
        participants: List<Person>? = null
    ) {
        val adaptiveIcon = if ((icon?.size ?: 0) == 0) null else Utils.getAdaptiveIconFromByteArray(icon!!)

        PersistentLog.d(context, Constants.logTag, "Creating intent for shortcut with name $name")
        val contactCategories = setOf(Constants.categoryTextShareTarget)
        val launcherIntent = Intent(context, MainActivity::class.java)
            .putExtra("chatGuid", guid)
            .putExtra("bubble", false)
            .setAction(Intent.ACTION_DEFAULT)
        val resolvedUri = resolveContactLookupUri(context, nativeContactId, contactUri)
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
    }
}