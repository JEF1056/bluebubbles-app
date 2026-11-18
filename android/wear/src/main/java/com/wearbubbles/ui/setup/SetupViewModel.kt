package com.wearbubbles.ui.setup

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.wearbubbles.WearBubblesApp
import com.wearbubbles.api.ApiClient
import com.wearbubbles.data.SettingsDataStore
import com.wearbubbles.service.MessageListenerService
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

data class SetupUiState(
    val serverUrl: String = "",
    val password: String = "",
    val isTesting: Boolean = false,
    val isSyncingFromPhone: Boolean = false,
    val isPhoneConnected: Boolean = false,
    val error: String? = null,
    val isSuccess: Boolean = false
)

class SetupViewModel(application: Application) : AndroidViewModel(application) {

    private val settings = SettingsDataStore(application)
    private val app = application as WearBubblesApp
    private val relay = app.phoneRelayClient

    private val _uiState = MutableStateFlow(SetupUiState())
    val uiState: StateFlow<SetupUiState> = _uiState.asStateFlow()

    init {
        viewModelScope.launch {
            val savedUrl = settings.getServerUrl()
            val savedPass = settings.getPassword()
            val phoneConnected = relay.refreshPhoneConnected()
            _uiState.value = _uiState.value.copy(
                serverUrl = savedUrl,
                password = savedPass,
                isPhoneConnected = phoneConnected
            )
            if (phoneConnected) {
                syncFromPhone()
            }
        }
    }

    fun updateServerUrl(url: String) {
        val cleaned = url.trim().let {
            if (it.isNotBlank() && !it.startsWith("http://") && !it.startsWith("https://")) {
                "https://$it"
            } else {
                it
            }
        }
        _uiState.value = _uiState.value.copy(serverUrl = cleaned, error = null)
        viewModelScope.launch {
            settings.saveServerUrl(cleaned)
        }
    }

    fun updatePassword(password: String) {
        _uiState.value = _uiState.value.copy(password = password, error = null)
        viewModelScope.launch {
            settings.savePassword(password)
        }
    }

    fun syncFromPhone() {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isSyncingFromPhone = true, error = null)
            val connected = relay.refreshPhoneConnected()
            if (!connected) {
                _uiState.value = _uiState.value.copy(
                    isSyncingFromPhone = false,
                    isPhoneConnected = false,
                    error = "Phone app not reachable"
                )
                return@launch
            }
            if (relay.loadCachedCredentialsFromDataLayer() && settings.isConfigured.first()) {
                _uiState.value = _uiState.value.copy(isSyncingFromPhone = false, isSuccess = true)
                return@launch
            }
            relay.requestCredentials()
            // Wait briefly for phone Data Layer response
            repeat(12) {
                delay(400)
                if (settings.isConfigured.first()) {
                    _uiState.value = _uiState.value.copy(isSyncingFromPhone = false, isSuccess = true)
                    return@launch
                }
            }
            _uiState.value = _uiState.value.copy(
                isSyncingFromPhone = false,
                error = "Open BlueBubbles on phone or enter server manually"
            )
        }
    }

    fun testAndConnect() {
        val url = _uiState.value.serverUrl.trim().trimEnd('/')
        val pass = _uiState.value.password
        if (url.isBlank() || pass.isBlank()) {
            _uiState.value = _uiState.value.copy(error = "Enter URL & password")
            return
        }

        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isTesting = true, error = null)
            try {
                val api = ApiClient.getApi(url, settings.getCustomHeaders())
                val response = api.ping(pass)
                if (response.status == 200) {
                    settings.saveServerUrl(url)
                    settings.savePassword(pass)
                    if (!relay.refreshPhoneConnected()) {
                        MessageListenerService.start(getApplication())
                    }
                    _uiState.value = _uiState.value.copy(isTesting = false, isSuccess = true)
                } else {
                    _uiState.value = _uiState.value.copy(
                        isTesting = false,
                        error = "Auth failed (${response.status})"
                    )
                }
            } catch (e: Exception) {
                _uiState.value = _uiState.value.copy(
                    isTesting = false,
                    error = e.localizedMessage?.take(60) ?: "Connection failed"
                )
            }
        }
    }
}
