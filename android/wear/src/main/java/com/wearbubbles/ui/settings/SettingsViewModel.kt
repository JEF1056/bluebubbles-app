package com.wearbubbles.ui.settings

import android.app.Application
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.wearbubbles.WearBubblesApp
import com.wearbubbles.api.ApiClient
import com.wearbubbles.data.SettingsDataStore
import com.wearbubbles.db.AppDatabase
import com.wearbubbles.relay.PhoneRelayClient
import com.wearbubbles.service.MessageListenerService
import com.wearbubbles.worker.MessageSyncWorker
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class SettingsUiState(
    val serverUrl: String = "",
    val userName: String = "",
    val userHandle: String = "",
    val userAvatarPath: String? = null,
    val isPhoneRelay: Boolean = false,
    val isSocketConnected: Boolean = false,
    val hapticEnabled: Boolean = true,
    val isSyncing: Boolean = false,
    val isResetDone: Boolean = false
)

class SettingsViewModel(application: Application) : AndroidViewModel(application) {

    private val settings = SettingsDataStore(application)
    private val app = application as WearBubblesApp
    private val relay = app.phoneRelayClient
    private val db = AppDatabase.getInstance(application)

    private val _uiState = MutableStateFlow(SettingsUiState())
    val uiState: StateFlow<SettingsUiState> = _uiState.asStateFlow()

    init {
        viewModelScope.launch {
            relay.refreshPhoneConnected()
            settings.serverUrl.collect { url ->
                _uiState.value = _uiState.value.copy(serverUrl = url)
            }
        }
        viewModelScope.launch {
            settings.hapticEnabled.collect { haptic ->
                _uiState.value = _uiState.value.copy(hapticEnabled = haptic)
            }
        }
        viewModelScope.launch {
            relay.isPhoneConnected.collect { phone ->
                _uiState.value = _uiState.value.copy(isPhoneRelay = phone)
            }
        }
        viewModelScope.launch {
            app.socketManager.isConnected.collect { connected ->
                _uiState.value = _uiState.value.copy(isSocketConnected = connected)
            }
        }
        viewModelScope.launch {
            settings.userName.collect { name ->
                _uiState.value = _uiState.value.copy(userName = name)
            }
        }
        viewModelScope.launch {
            settings.userHandle.collect { handle ->
                _uiState.value = _uiState.value.copy(userHandle = handle)
            }
        }
        viewModelScope.launch {
            settings.userAvatarPath.collect { path ->
                _uiState.value = _uiState.value.copy(userAvatarPath = path)
            }
        }
        viewModelScope.launch {
            refreshProfileFromServer()
        }
    }

    private suspend fun refreshProfileFromServer() {
        withContext(Dispatchers.IO) {
            try {
                val url = settings.getServerUrl()
                val password = settings.getPassword()
                if (url.isBlank() || password.isBlank()) return@withContext
                ApiClient.configureHeaders(url, settings.getCustomHeaders())
                val resp = ApiClient.getApi(url).getICloudContact(password)
                val dto = resp.data ?: return@withContext
                val name = dto.resolvedName()
                val handle = dto.resolvedHandle()
                val rawAvatar = PhoneRelayClient.decodeAvatarBase64(dto.avatar)
                val compressed = rawAvatar?.let { PhoneRelayClient.compressSelfAvatar(it) }
                val outFile = relay.getSelfAvatarFile()
                val avatarPath = if (compressed != null) {
                    outFile.writeBytes(compressed)
                    "${outFile.absolutePath}?v=${outFile.lastModified()}"
                } else {
                    outFile.takeIf { it.exists() }?.let { "${it.absolutePath}?v=${it.lastModified()}" }
                }
                if (name.isNotBlank() || handle.isNotBlank() || avatarPath != null) {
                    settings.saveUserProfile(name, handle, avatarPath)
                }
            } catch (e: Exception) {
                Log.w("SettingsViewModel", "refreshProfileFromServer failed: ${e.message}")
            }
        }
    }

    fun toggleHaptic(enabled: Boolean) {
        viewModelScope.launch {
            settings.setHapticEnabled(enabled)
        }
    }

    fun syncFromPhone() {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isSyncing = true)
            if (relay.refreshPhoneConnected(force = true)) {
                relay.requestCredentials()
                relay.requestProfileSync()
                relay.requestChatsSync()
                relay.requestContactsSync()
            } else {
                refreshProfileFromServer()
            }
            _uiState.value = _uiState.value.copy(isSyncing = false)
        }
    }

    fun resetSetup() {
        viewModelScope.launch {
            app.socketManager.disconnect()
            MessageSyncWorker.cancel(getApplication())
            MessageListenerService.stop(getApplication())
            settings.clearAll()
            withContext(Dispatchers.IO) {
                relay.getSelfAvatarFile().delete()
                db.clearAllTables()
            }
            _uiState.value = _uiState.value.copy(isResetDone = true)
        }
    }
}
