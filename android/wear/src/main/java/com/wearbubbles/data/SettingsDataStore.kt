package com.wearbubbles.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "settings")

class SettingsDataStore(private val context: Context) {

    companion object {
        private val SERVER_URL = stringPreferencesKey("server_url")
        private val PASSWORD = stringPreferencesKey("password")
        private val CUSTOM_HEADERS_JSON = stringPreferencesKey("custom_headers_json")
        private val PRIVATE_API_SEND = booleanPreferencesKey("private_api_send")
        private val HAPTIC_ENABLED = booleanPreferencesKey("haptic_enabled")
        private val LAST_UPDATE_CHECK = longPreferencesKey("last_update_check")
        private val DISMISSED_UPDATE_VERSION = stringPreferencesKey("dismissed_update_version")
        private val gson = Gson()
        private val mapType = object : TypeToken<Map<String, String>>() {}.type
    }

    val serverUrl: Flow<String> = context.dataStore.data.map { prefs ->
        prefs[SERVER_URL] ?: ""
    }

    val password: Flow<String> = context.dataStore.data.map { prefs ->
        prefs[PASSWORD] ?: ""
    }

    val customHeadersJson: Flow<String> = context.dataStore.data.map { prefs ->
        prefs[CUSTOM_HEADERS_JSON] ?: "{}"
    }

    val privateApiSend: Flow<Boolean> = context.dataStore.data.map { prefs ->
        prefs[PRIVATE_API_SEND] ?: false
    }

    val hapticEnabled: Flow<Boolean> = context.dataStore.data.map { prefs ->
        prefs[HAPTIC_ENABLED] ?: true
    }

    val isConfigured: Flow<Boolean> = context.dataStore.data.map { prefs ->
        !prefs[SERVER_URL].isNullOrBlank() && !prefs[PASSWORD].isNullOrBlank()
    }

    suspend fun getServerUrl(): String = serverUrl.first()

    suspend fun getPassword(): String = password.first()

    suspend fun getCustomHeaders(): Map<String, String> {
        val raw = customHeadersJson.first()
        return parseHeaders(raw)
    }

    suspend fun isPrivateApiSend(): Boolean = privateApiSend.first()

    suspend fun saveServerUrl(url: String) {
        val normalized = url.trim().trimEnd('/')
        context.dataStore.edit { prefs ->
            prefs[SERVER_URL] = normalized
        }
    }

    suspend fun savePassword(pass: String) {
        context.dataStore.edit { prefs ->
            prefs[PASSWORD] = pass
        }
    }

    suspend fun saveCredentials(
        url: String,
        pass: String,
        headersJson: String = "{}",
        usePrivateApiSend: Boolean = false
    ) {
        val normalized = url.trim().trimEnd('/')
        context.dataStore.edit { prefs ->
            prefs[SERVER_URL] = normalized
            prefs[PASSWORD] = pass
            prefs[CUSTOM_HEADERS_JSON] = headersJson.ifBlank { "{}" }
            prefs[PRIVATE_API_SEND] = usePrivateApiSend
        }
    }

    suspend fun setHapticEnabled(enabled: Boolean) {
        context.dataStore.edit { prefs ->
            prefs[HAPTIC_ENABLED] = enabled
        }
    }

    suspend fun getLastUpdateCheck(): Long = context.dataStore.data.map { it[LAST_UPDATE_CHECK] ?: 0L }.first()

    suspend fun setLastUpdateCheck(time: Long) {
        context.dataStore.edit { it[LAST_UPDATE_CHECK] = time }
    }

    suspend fun getDismissedUpdateVersion(): String? =
        context.dataStore.data.map { it[DISMISSED_UPDATE_VERSION] }.first()

    suspend fun setDismissedUpdateVersion(version: String) {
        context.dataStore.edit { it[DISMISSED_UPDATE_VERSION] = version }
    }

    suspend fun clearAll() {
        context.dataStore.edit { it.clear() }
    }

    fun parseHeaders(raw: String): Map<String, String> {
        return try {
            gson.fromJson<Map<String, String>>(raw, mapType) ?: emptyMap()
        } catch (_: Exception) {
            emptyMap()
        }
    }
}
