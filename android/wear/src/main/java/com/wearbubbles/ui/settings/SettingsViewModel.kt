package com.wearbubbles.ui.settings

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.wearbubbles.WearBubblesApp
import com.wearbubbles.data.SettingsDataStore
import com.wearbubbles.db.AppDatabase
import com.wearbubbles.service.MessageListenerService
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class SettingsUiState(
    val serverUrl: String = "",
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
    }

    fun toggleHaptic(enabled: Boolean) {
        viewModelScope.launch {
            settings.setHapticEnabled(enabled)
        }
    }

    fun syncFromPhone() {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isSyncing = true)
            if (relay.refreshPhoneConnected()) {
                relay.requestCredentials()
                relay.requestChatsSync()
                relay.requestContactsSync()
            }
            _uiState.value = _uiState.value.copy(isSyncing = false)
        }
    }

    fun resetSetup() {
        viewModelScope.launch {
            app.socketManager.disconnect()
            MessageListenerService.stop(getApplication())
            settings.clearAll()
            db.clearAllTables()
            _uiState.value = _uiState.value.copy(isResetDone = true)
        }
    }
}
