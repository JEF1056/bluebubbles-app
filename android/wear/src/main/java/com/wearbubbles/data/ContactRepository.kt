package com.wearbubbles.data

import android.content.Context
import android.util.Base64
import android.util.Log
import com.wearbubbles.api.ApiClient
import com.wearbubbles.api.dto.AddressNormalizer
import com.wearbubbles.db.ContactDao
import com.wearbubbles.db.entities.ContactEntity
import com.wearbubbles.relay.PhoneRelayClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.ConcurrentHashMap

class ContactRepository(
    private val context: Context,
    private val contactDao: ContactDao,
    private val settings: SettingsDataStore,
    private val phoneRelay: PhoneRelayClient? = null
) {
    companion object {
        private const val TAG = "ContactRepository"
    }

    private val nameCache = ConcurrentHashMap<String, String>()
    private val avatarCache = ConcurrentHashMap<String, String>()
    private var loaded = false

    fun getContactsFlow(): Flow<List<ContactEntity>> = contactDao.getAllContactsFlow()

    suspend fun loadFromDb() {
        val contacts = contactDao.getAllContacts()
        contacts.forEach {
            nameCache[it.normalizedAddress] = it.displayName
            if (!it.avatarPath.isNullOrBlank()) {
                avatarCache[it.normalizedAddress] = it.avatarPath
            }
        }
        loaded = true
    }

    suspend fun refreshContacts(force: Boolean = false): Unit = withContext(Dispatchers.IO) {
        if (!loaded) loadFromDb()
        if (!force && contactDao.getCount() > 0) return@withContext

        // Primary: Phone Relay when tethered
        if (phoneRelay != null && phoneRelay.refreshPhoneConnected()) {
            if (phoneRelay.requestContactsSyncAwait()) {
                loadFromDb()
                return@withContext
            }
        }

        // Fallback: Direct Server
        val serverUrl = settings.getServerUrl()
        val password = settings.getPassword()
        if (serverUrl.isBlank() || password.isBlank()) return@withContext

        try {
            val api = ApiClient.getApi(serverUrl, settings.getCustomHeaders())
            val response = api.getContacts(password)
            val contacts = response.data ?: return@withContext
            val avatarsDir = File(context.filesDir, "avatars").apply { mkdirs() }

            val entities = mutableListOf<ContactEntity>()
            for (contact in contacts) {
                val name = contact.displayName?.takeIf { it.isNotBlank() }
                    ?: listOfNotNull(
                        contact.firstName?.takeIf { it.isNotBlank() },
                        contact.lastName?.takeIf { it.isNotBlank() }
                    ).joinToString(" ").takeIf { it.isNotBlank() }
                    ?: continue

                var savedAvatarPath: String? = null
                val addresses = (contact.phoneNumbers?.mapNotNull { it.address } ?: emptyList()) +
                    (contact.emails?.mapNotNull { it.address } ?: emptyList())

                if (!contact.avatar.isNullOrBlank() && addresses.isNotEmpty()) {
                    try {
                        val key = AddressNormalizer.normalize(addresses.first())
                        if (key.isNotBlank()) {
                            val file = File(avatarsDir, "${key.replace(Regex("[^a-zA-Z0-9._-]"), "_")}.img")
                            file.writeBytes(Base64.decode(contact.avatar, Base64.DEFAULT))
                            savedAvatarPath = file.absolutePath
                        }
                    } catch (_: Exception) {
                    }
                }

                addresses.forEach { addr ->
                    val normalized = AddressNormalizer.normalize(addr)
                    if (normalized.isNotBlank()) {
                        entities.add(
                            ContactEntity(
                                normalizedAddress = normalized,
                                displayName = name,
                                rawAddress = addr,
                                avatarPath = savedAvatarPath ?: avatarCache[normalized]
                            )
                        )
                    }
                }
            }

            if (entities.isNotEmpty()) {
                contactDao.upsertAll(entities)
                entities.forEach {
                    nameCache[it.normalizedAddress] = it.displayName
                    if (!it.avatarPath.isNullOrBlank()) {
                        avatarCache[it.normalizedAddress] = it.avatarPath
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to fetch contacts: ${e.message}")
        }
    }

    fun resolveDisplayName(address: String): String {
        val normalized = AddressNormalizer.normalize(address)
        return nameCache[normalized] ?: AddressNormalizer.format(address)
    }

    fun resolveAvatarPath(address: String): String? {
        val normalized = AddressNormalizer.normalize(address)
        val cached = avatarCache[normalized] ?: phoneRelay?.getAvatarFile(normalized)?.absolutePath
        if (cached != null) avatarCache[normalized] = cached
        return cached
    }

    fun resolveAvatarForChat(chatGuid: String, participantAddresses: String): String? {
        val participants = participantAddresses.split(",").filter { it.isNotBlank() }
        if (participants.size == 1) {
            resolveAvatarPath(participants.first())?.let { return it }
        }
        return phoneRelay?.getAvatarFile(chatGuid)?.absolutePath
    }

    fun resolveChatTitle(displayName: String?, chatIdentifier: String, participantAddresses: String): String {
        if (!displayName.isNullOrBlank()) return displayName

        val participants = participantAddresses.split(",").filter { it.isNotBlank() }
        if (participants.size == 1) {
            return resolveDisplayName(participants.first())
        }
        if (participants.size > 1) {
            return participants.take(3).joinToString(", ") { resolveDisplayName(it) }
        }
        return resolveDisplayName(chatIdentifier)
    }
}
