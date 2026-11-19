package com.wearbubbles.ui.messages

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.wearbubbles.WearBubblesApp
import com.wearbubbles.data.ContactRepository
import com.wearbubbles.data.SettingsDataStore
import com.wearbubbles.db.AppDatabase
import com.wearbubbles.db.entities.ContactEntity
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class NewMessageViewModel(application: Application) : AndroidViewModel(application) {
    private val db = AppDatabase.getInstance(application)
    private val settings = SettingsDataStore(application)
    private val relay = (application as WearBubblesApp).phoneRelayClient
    private val contactRepo = ContactRepository(application, db.contactDao(), settings, relay)

    private val _query = MutableStateFlow("")
    val query: StateFlow<String> = _query.asStateFlow()

    private val _contacts = MutableStateFlow<List<ContactEntity>>(emptyList())
    val contacts: StateFlow<List<ContactEntity>> = _contacts.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    private var allContacts: List<ContactEntity> = emptyList()

    init {
        viewModelScope.launch {
            _isLoading.value = true
            allContacts = db.contactDao().getAllContacts()
            if (allContacts.isEmpty()) {
                contactRepo.refreshContacts(force = false)
                allContacts = db.contactDao().getAllContacts()
            }
            applyFilter(_query.value)
            _isLoading.value = false
        }
    }

    fun setQuery(q: String) {
        _query.value = q
        applyFilter(q)
    }

    private fun applyFilter(q: String) {
        val trimmed = q.trim().lowercase()
        _contacts.value = if (trimmed.isBlank()) {
            allContacts.take(60)
        } else {
            allContacts.filter {
                it.displayName.lowercase().contains(trimmed) ||
                    it.normalizedAddress.lowercase().contains(trimmed)
            }.take(60)
        }
    }

    fun chatGuidForAddress(rawAddress: String): String {
        val trimmed = rawAddress.trim()
        val formatted = if (trimmed.contains("@")) {
            trimmed
        } else {
            val digits = trimmed.filter { it.isDigit() }
            when {
                trimmed.startsWith("+") -> trimmed
                digits.length == 10 -> "+1$digits"
                digits.length == 11 && digits.startsWith("1") -> "+$digits"
                else -> trimmed
            }
        }
        return "iMessage;-;$formatted"
    }
}
