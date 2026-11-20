package com.wearbubbles.ui.messages

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.wearbubbles.WearBubblesApp
import com.wearbubbles.data.ContactRepository
import com.wearbubbles.data.SettingsDataStore
import com.wearbubbles.db.AppDatabase
import com.wearbubbles.db.entities.ChatEntity
import com.wearbubbles.db.entities.ContactEntity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

internal data class NewMessageUiState(
    val query: String = "",
    val isLoading: Boolean = true,
    val hasContacts: Boolean = false,
    val filteredContacts: List<ContactEntity> = emptyList(),
    val favoriteRows: List<List<ContactEntity>> = emptyList(),
    val duplicateNames: Set<String> = emptySet(),
    val alphabeticalSections: List<ContactSection> = emptyList(),
    val recentChats: List<ChatEntity> = emptyList()
)

class NewMessageViewModel(application: Application) : AndroidViewModel(application) {
    private val db = AppDatabase.getInstance(application)
    private val settings = SettingsDataStore(application)
    private val relay = (application as WearBubblesApp).phoneRelayClient
    private val contactRepo = ContactRepository(application, db.contactDao(), settings, relay)

    private val _query = MutableStateFlow("")
    private val _isLoading = MutableStateFlow(true)

    internal val uiState: StateFlow<NewMessageUiState> = combine(
        _query,
        db.contactDao().getAllContactsFlow(),
        db.chatDao().getAllChats(),
        _isLoading
    ) { query, allContacts, recentChats, isLoading ->
        val filtered = filterContacts(allContacts, query)
        val favorites = selectFavoriteContacts(
            contacts = allContacts,
            recentChats = recentChats,
            resolveAvatarPath = { norm -> relay.getAvatarFile(norm)?.absolutePath }
        )
        NewMessageUiState(
            query = query,
            isLoading = isLoading,
            hasContacts = allContacts.isNotEmpty(),
            filteredContacts = filtered,
            favoriteRows = favorites.chunked(2),
            duplicateNames = duplicateDisplayNames(filtered),
            alphabeticalSections = groupContactsAlphabetically(filtered),
            recentChats = recentChats
        )
    }
        .flowOn(Dispatchers.IO)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000L), NewMessageUiState())

    init {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                if (db.contactDao().getAllContacts().isEmpty()) {
                    contactRepo.refreshContacts(force = false)
                }
            } finally {
                _isLoading.value = false
            }
        }
    }

    fun setQuery(q: String) {
        _query.value = q
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
