package com.wearbubbles.ui.messages

import android.app.Activity
import android.app.RemoteInput
import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Bundle
import android.speech.RecognizerIntent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.Backspace
import androidx.compose.material.icons.automirrored.rounded.Send
import androidx.compose.material.icons.outlined.Keyboard
import androidx.compose.material.icons.outlined.Mic
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Dialpad
import androidx.compose.material.icons.rounded.Person
import androidx.compose.material.icons.rounded.Star
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.wear.compose.material.Icon
import androidx.wear.compose.material.Text
import androidx.wear.input.RemoteInputIntentHelper
import coil.compose.AsyncImage
import com.google.android.horologist.annotations.ExperimentalHorologistApi
import com.google.android.horologist.compose.layout.ScalingLazyColumn
import com.google.android.horologist.compose.layout.ScalingLazyColumnDefaults
import com.google.android.horologist.compose.layout.ScalingLazyColumnDefaults.ItemType
import com.google.android.horologist.compose.layout.ScreenScaffold
import com.google.android.horologist.compose.layout.rememberResponsiveColumnState
import com.wearbubbles.api.dto.AddressNormalizer
import com.wearbubbles.db.AppDatabase
import com.wearbubbles.db.entities.ChatEntity
import com.wearbubbles.db.entities.ContactEntity
import com.wearbubbles.ui.theme.ContactAvatar
import com.wearbubbles.ui.theme.LocalWearPalette
import com.wearbubbles.ui.theme.WearPillButton
import com.wearbubbles.ui.theme.avatarMonogram
import com.wearbubbles.ui.theme.avatarSwatchFor
import com.wearbubbles.ui.theme.centeredTextStyle
import java.io.File
import java.util.Locale

private const val MAX_FAVORITE_CONTACTS = 4

private val DIALPAD_ROWS = listOf(
    listOf("1", "2", "3"),
    listOf("4", "5", "6"),
    listOf("7", "8", "9"),
    listOf("+", "0", "BACK")
)

internal data class ContactSection(
    val letter: String,
    val contacts: List<ContactEntity>
)

internal fun looksLikeDirectAddress(input: String): Boolean {
    val trimmed = input.trim()
    if (trimmed.isEmpty()) return false
    if (trimmed.contains('@') && !trimmed.contains(' ') && trimmed.length >= 3) return true
    if (trimmed.any { it.isLetter() }) return false
    val digits = trimmed.count { it.isDigit() }
    return digits >= 7 && trimmed.all { it.isDigit() || it in "+-(). " }
}

internal fun canStartDirectQuery(query: String): Boolean {
    val trimmed = query.trim()
    if (trimmed.isEmpty()) return false
    return trimmed.contains('@') || (trimmed.any { it.isDigit() } && !trimmed.any { it.isLetter() })
}

internal fun appendDialpadToken(
    current: String,
    token: String,
    maxLength: Int = 24
): String {
    if (current.length >= maxLength) return current
    if (token == "+" && current.isNotEmpty()) return current
    return current + token
}

internal fun resolveStartChatGuid(
    rawAddress: String,
    recentChats: List<ChatEntity>,
    fallbackChatGuid: (String) -> String
): String {
    val target = AddressNormalizer.normalize(rawAddress)
    if (target.isNotBlank()) {
        for (chat in recentChats.sortedByDescending { it.lastMessageDate }) {
            if (chat.isGroup) continue
            val participants = chat.participantAddresses
                .split(",")
                .map { it.trim() }
                .filter { it.isNotBlank() }
                .ifEmpty { listOf(chat.chatIdentifier) }
            if (participants.any { AddressNormalizer.normalize(it) == target }) {
                return chat.guid
            }
        }
    }
    return fallbackChatGuid(rawAddress)
}

internal fun filterContacts(
    contacts: List<ContactEntity>,
    query: String
): List<ContactEntity> {
    val trimmed = query.trim().lowercase(Locale.ROOT)
    if (trimmed.isEmpty()) return contacts
    return contacts.filter {
        it.displayName.lowercase(Locale.ROOT).contains(trimmed) ||
            it.normalizedAddress.lowercase(Locale.ROOT).contains(trimmed) ||
            it.rawAddress.lowercase(Locale.ROOT).contains(trimmed)
    }
}

internal fun duplicateDisplayNames(contacts: List<ContactEntity>): Set<String> {
    val counts = HashMap<String, Int>(contacts.size)
    for (contact in contacts) {
        val key = contact.displayName.trim().lowercase(Locale.ROOT)
        if (key.isNotEmpty()) {
            counts[key] = (counts[key] ?: 0) + 1
        }
    }
    return counts.filterValues { it > 1 }.keys
}

internal fun selectFavoriteContacts(
    contacts: List<ContactEntity>,
    recentChats: List<ChatEntity>,
    limit: Int = MAX_FAVORITE_CONTACTS,
    resolveAvatarPath: (String) -> String? = { null }
): List<ContactEntity> {
    if (limit <= 0) return emptyList()

    val byNormalized = HashMap<String, ContactEntity>(contacts.size * 2)
    for (contact in contacts) {
        val normalized = AddressNormalizer.normalize(contact.normalizedAddress)
        byNormalized.putIfAbsent(normalized, contact)
        byNormalized.putIfAbsent(contact.normalizedAddress, contact)
    }

    val seenKeys = HashSet<String>()
    fun dedupKey(contact: ContactEntity): String =
        contact.displayName.trim().lowercase(Locale.ROOT).ifBlank { contact.normalizedAddress }

    // Favorites mirror pinned individual conversations synced from the phone.
    val pinnedChats = recentChats
        .filter { it.isPinned && !it.isGroup }
        .sortedWith(
            compareBy<ChatEntity> { it.pinIndex ?: Int.MAX_VALUE }
                .thenByDescending { it.lastMessageDate }
        )
    if (pinnedChats.isNotEmpty()) {
        val pinnedContacts = ArrayList<ContactEntity>(pinnedChats.size)
        for (chat in pinnedChats) {
            val candidates = chat.participantAddresses
                .split(",")
                .map { it.trim() }
                .filter { it.isNotBlank() }
                .ifEmpty { listOf(chat.chatIdentifier) }
            var matched: ContactEntity? = null
            for (rawAddr in candidates) {
                matched = byNormalized[AddressNormalizer.normalize(rawAddr)] ?: byNormalized[rawAddr]
                if (matched != null) break
            }
            val contact = matched?.let { c ->
                if (!c.avatarPath.isNullOrBlank()) c
                else resolveAvatarPath(c.normalizedAddress)?.let { c.copy(avatarPath = it) } ?: c
            } ?: run {
                val addr = candidates.firstOrNull().orEmpty()
                val normalized = AddressNormalizer.normalize(addr)
                if (normalized.isBlank()) null
                else ContactEntity(
                    normalizedAddress = normalized,
                    displayName = chat.displayName?.takeIf { it.isNotBlank() } ?: addr,
                    avatarPath = resolveAvatarPath(normalized)
                )
            }
            if (contact != null && seenKeys.add(dedupKey(contact))) {
                pinnedContacts.add(contact)
            }
        }
        if (pinnedContacts.isNotEmpty()) return pinnedContacts
    }

    if (contacts.isEmpty()) return emptyList()

    val selected = ArrayList<ContactEntity>(limit)
    for (chat in recentChats.sortedByDescending { it.lastMessageDate }) {
        if (selected.size >= limit) break
        if (chat.isGroup) continue
        val candidates = chat.participantAddresses
            .split(",")
            .map { it.trim() }
            .filter { it.isNotBlank() }
            .ifEmpty { listOf(chat.chatIdentifier) }
        for (rawAddr in candidates) {
            val match = byNormalized[AddressNormalizer.normalize(rawAddr)] ?: byNormalized[rawAddr]
            if (match != null && seenKeys.add(dedupKey(match))) {
                selected.add(match)
                break
            }
        }
    }

    if (selected.size < limit) {
        val remaining = contacts.sortedWith(
            compareByDescending<ContactEntity> { !it.avatarPath.isNullOrBlank() }
                .thenBy { !(it.displayName.trim().firstOrNull()?.isLetter() == true) }
                .thenBy { it.displayName.trim().lowercase(Locale.ROOT) }
                .thenBy { it.normalizedAddress }
        )
        for (contact in remaining) {
            if (selected.size >= limit) break
            if (seenKeys.add(dedupKey(contact))) {
                selected.add(contact)
            }
        }
    }

    return selected
}

internal fun groupContactsAlphabetically(contacts: List<ContactEntity>): List<ContactSection> {
    if (contacts.isEmpty()) return emptyList()
    val sorted = contacts.sortedWith(
        compareBy<ContactEntity> { it.displayName.trim().lowercase(Locale.ROOT) }
            .thenBy { it.normalizedAddress }
    )
    val grouped = LinkedHashMap<String, MutableList<ContactEntity>>()
    for (contact in sorted) {
        val first = contact.displayName.trim().firstOrNull()
        val key = if (first != null && first.isLetter()) {
            first.uppercaseChar().toString()
        } else {
            "#"
        }
        grouped.getOrPut(key) { mutableListOf() }.add(contact)
    }
    val orderedKeys = grouped.keys.sortedWith(
        compareBy<String> { it == "#" }.thenBy { it }
    )
    return orderedKeys.map { key -> ContactSection(key, grouped.getValue(key)) }
}

@OptIn(ExperimentalHorologistApi::class)
@Composable
fun NewMessageScreen(
    onStartChat: (String) -> Unit,
    viewModel: NewMessageViewModel = viewModel()
) {
    val palette = LocalWearPalette.current
    val context = LocalContext.current
    val query by viewModel.query.collectAsState()
    val isLoading by viewModel.isLoading.collectAsState()
    val db = remember(context) { AppDatabase.getInstance(context) }
    val allContacts by remember(db) {
        db.contactDao().getAllContactsFlow()
    }.collectAsState(initial = emptyList())
    val recentChats by remember(db) {
        db.chatDao().getAllChats()
    }.collectAsState(initial = emptyList())

    var showDialpad by rememberSaveable { mutableStateOf(false) }
    var dialpadNumber by rememberSaveable { mutableStateOf("") }

    fun openChatForAddress(rawAddress: String) {
        onStartChat(resolveStartChatGuid(rawAddress, recentChats, viewModel::chatGuidForAddress))
    }

    fun handleTextInput(raw: String) {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return
        showDialpad = false
        if (looksLikeDirectAddress(trimmed)) {
            openChatForAddress(trimmed)
        } else {
            viewModel.setQuery(trimmed)
        }
    }

    val recipientInputLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK && result.data != null) {
            val results: Bundle = RemoteInput.getResultsFromIntent(result.data) ?: return@rememberLauncherForActivityResult
            val entered = results.getCharSequence("recipient_input")?.toString().orEmpty()
            handleTextInput(entered)
        }
    }

    val speechLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK && result.data != null) {
            val spoken = result.data
                ?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
                ?.firstOrNull()
                .orEmpty()
            handleTextInput(spoken)
        }
    }

    fun launchKeyboardInput() {
        val intent = RemoteInputIntentHelper.createActionRemoteInputIntent()
        val remoteInput = RemoteInput.Builder("recipient_input")
            .setLabel("Name, phone, or email")
            .build()
        RemoteInputIntentHelper.putRemoteInputsExtra(intent, listOf(remoteInput))
        recipientInputLauncher.launch(intent)
    }

    fun launchMicInput() {
        val speechIntent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PROMPT, "Name or phone number")
        }
        try {
            speechLauncher.launch(speechIntent)
        } catch (_: ActivityNotFoundException) {
            launchKeyboardInput()
        }
    }

    val filteredContacts = remember(allContacts, query) {
        filterContacts(allContacts, query)
    }
    val relayClient = remember(context) { com.wearbubbles.relay.PhoneRelayClient(context.applicationContext) }
    val favoriteContacts = remember(allContacts, recentChats) {
        selectFavoriteContacts(
            contacts = allContacts,
            recentChats = recentChats,
            resolveAvatarPath = { norm -> relayClient.getAvatarFile(norm)?.absolutePath }
        )
    }
    val favoriteRows = remember(favoriteContacts) {
        favoriteContacts.chunked(2)
    }
    val duplicateNames = remember(filteredContacts) {
        duplicateDisplayNames(filteredContacts)
    }
    val alphabeticalSections = remember(filteredContacts) {
        groupContactsAlphabetically(filteredContacts)
    }

    val columnState = rememberResponsiveColumnState(
        contentPadding = ScalingLazyColumnDefaults.padding(
            first = ItemType.Chip,
            last = ItemType.Chip
        ),
        verticalArrangement = Arrangement.spacedBy(6.dp)
    )

    ScreenScaffold(
        scrollState = columnState,
        modifier = Modifier
            .fillMaxSize()
            .background(palette.canvas)
    ) {
        ScalingLazyColumn(
            columnState = columnState,
            modifier = Modifier
                .fillMaxSize()
                .background(palette.canvas)
        ) {
            item(key = "top_actions") {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 4.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    TopActionPill(
                        icon = Icons.Outlined.Mic,
                        contentDescription = "Voice search",
                        containerColor = palette.primary,
                        iconTint = palette.onPrimary,
                        onClick = { launchMicInput() },
                        modifier = Modifier.weight(1f)
                    )
                    TopActionPill(
                        icon = Icons.Outlined.Keyboard,
                        contentDescription = "Type name or address",
                        containerColor = palette.primary,
                        iconTint = palette.onPrimary,
                        onClick = { launchKeyboardInput() },
                        modifier = Modifier.weight(1f)
                    )
                    TopActionPill(
                        icon = Icons.Rounded.Dialpad,
                        contentDescription = "Dialpad",
                        containerColor = if (showDialpad) palette.primary else palette.surfaceContainerHigh,
                        iconTint = if (showDialpad) palette.onPrimary else palette.onSurface,
                        onClick = { showDialpad = !showDialpad },
                        modifier = Modifier.weight(1f)
                    )
                }
            }

            if (showDialpad) {
                item(key = "dialpad_display") {
                    DialpadDisplayPill(
                        number = dialpadNumber,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)
                    )
                }

                items(DIALPAD_ROWS.size, key = { "dialpad_row_$it" }) { rowIndex ->
                    DialpadKeypadRow(
                        keys = DIALPAD_ROWS[rowIndex],
                        onAppend = { token -> dialpadNumber = appendDialpadToken(dialpadNumber, token) },
                        onBackspace = {
                            if (dialpadNumber.isNotEmpty()) {
                                dialpadNumber = dialpadNumber.dropLast(1)
                            }
                        },
                        onClear = { dialpadNumber = "" },
                        modifier = Modifier.padding(horizontal = 6.dp)
                    )
                }

                item(key = "dialpad_start") {
                    val hasDigits = dialpadNumber.any { it.isDigit() }
                    WearPillButton(
                        label = "Start chat",
                        onClick = {
                            if (hasDigits) {
                                openChatForAddress(dialpadNumber)
                            }
                        },
                        enabled = hasDigits,
                        leadingIcon = {
                            Icon(
                                imageVector = Icons.AutoMirrored.Rounded.Send,
                                contentDescription = null,
                                tint = if (hasDigits) palette.onPrimary else palette.onSurfaceVariant,
                                modifier = Modifier.size(16.dp)
                            )
                        },
                        backgroundColor = if (hasDigits) palette.primary else palette.surfaceContainerHigh,
                        contentColor = if (hasDigits) palette.onPrimary else palette.onSurfaceVariant,
                        centered = true,
                        minHeight = 42.dp,
                        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp),
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)
                    )
                }
            } else {
                item(key = "contacts_subtitle") {
                    Text(
                        text = "Contacts",
                        style = centeredTextStyle(14.sp, 18.sp, FontWeight.Medium),
                        color = palette.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 4.dp, bottom = 2.dp)
                    )
                }

                if (query.isNotBlank()) {
                    item(key = "active_query") {
                        WearPillButton(
                            label = "Filter: $query",
                            secondaryLabel = "Tap to clear",
                            onClick = { viewModel.setQuery("") },
                            leadingIcon = {
                                Icon(
                                    imageVector = Icons.Rounded.Close,
                                    contentDescription = "Clear filter",
                                    tint = palette.onSurface,
                                    modifier = Modifier.size(16.dp)
                                )
                            },
                            backgroundColor = palette.surfaceContainerHigh,
                            contentColor = palette.onSurface,
                            minHeight = 46.dp
                        )
                    }

                    if (canStartDirectQuery(query)) {
                        item(key = "direct_query_start") {
                            WearPillButton(
                                label = "Message \"$query\"",
                                onClick = { openChatForAddress(query.trim()) },
                                leadingIcon = {
                                    Icon(
                                        imageVector = Icons.AutoMirrored.Rounded.Send,
                                        contentDescription = null,
                                        tint = palette.onPrimary,
                                        modifier = Modifier.size(16.dp)
                                    )
                                },
                                backgroundColor = palette.primary,
                                contentColor = palette.onPrimary,
                                centered = true,
                                minHeight = 46.dp
                            )
                        }
                    }
                } else if (favoriteContacts.isNotEmpty()) {
                    item(key = "favorites_header") {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(top = 4.dp, bottom = 4.dp),
                            horizontalArrangement = Arrangement.Center,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Star,
                                contentDescription = null,
                                tint = palette.onSurfaceVariant,
                                modifier = Modifier.size(16.dp)
                            )
                            Spacer(modifier = Modifier.width(5.dp))
                            Text(
                                text = "Favorites",
                                style = centeredTextStyle(17.sp, 21.sp, FontWeight.Bold),
                                color = palette.onSurface
                            )
                        }
                    }

                    items(favoriteRows.size, key = { "fav_row_$it" }) { rowIndex ->
                        val rowContacts = favoriteRows[rowIndex]
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 2.dp, vertical = 2.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            val first = rowContacts[0]
                            FavoriteContactCapsule(
                                contact = first,
                                onClick = {
                                    openChatForAddress(first.rawAddress.ifBlank { first.normalizedAddress })
                                },
                                modifier = Modifier.weight(1f)
                            )
                            if (rowContacts.size > 1) {
                                val second = rowContacts[1]
                                FavoriteContactCapsule(
                                    contact = second,
                                    onClick = {
                                        openChatForAddress(second.rawAddress.ifBlank { second.normalizedAddress })
                                    },
                                    modifier = Modifier.weight(1f)
                                )
                            } else {
                                Spacer(modifier = Modifier.weight(1f))
                            }
                        }
                    }
                }

                if (isLoading && allContacts.isEmpty()) {
                    item(key = "loading_contacts") {
                        Text(
                            text = "Loading contacts...",
                            style = centeredTextStyle(13.sp, 17.sp),
                            color = palette.onSurfaceVariant,
                            textAlign = TextAlign.Center,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = 12.dp)
                        )
                    }
                } else if (filteredContacts.isEmpty()) {
                    item(key = "empty_contacts") {
                        Text(
                            text = if (query.isBlank()) "No contacts synced" else "No matches for \"$query\"",
                            style = centeredTextStyle(13.sp, 17.sp),
                            color = palette.onSurfaceVariant,
                            textAlign = TextAlign.Center,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = 12.dp)
                        )
                    }
                } else {
                    for (section in alphabeticalSections) {
                        item(key = "section_${section.letter}") {
                            Text(
                                text = section.letter,
                                style = centeredTextStyle(17.sp, 21.sp, FontWeight.Bold),
                                color = palette.onSurface,
                                textAlign = TextAlign.Center,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(top = 8.dp, bottom = 2.dp)
                            )
                        }

                        items(
                            count = section.contacts.size,
                            key = { idx -> "contact_${section.letter}_${section.contacts[idx].normalizedAddress}" }
                        ) { idx ->
                            val contact = section.contacts[idx]
                            val label = contact.displayName.ifBlank { contact.normalizedAddress }
                            val nameKey = contact.displayName.trim().lowercase(Locale.ROOT)
                            val disambiguator = if (nameKey in duplicateNames) {
                                contact.rawAddress.ifBlank { contact.normalizedAddress }
                            } else {
                                null
                            }
                            WearPillButton(
                                label = label,
                                secondaryLabel = disambiguator,
                                onClick = {
                                    openChatForAddress(contact.rawAddress.ifBlank { contact.normalizedAddress })
                                },
                                leadingIcon = {
                                    ContactAvatar(
                                        title = label,
                                        seed = contact.normalizedAddress,
                                        avatarPath = contact.avatarPath,
                                        size = 36.dp
                                    )
                                },
                                backgroundColor = palette.surfaceContainer,
                                contentColor = palette.onSurface,
                                minHeight = 54.dp,
                                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 8.dp)
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun TopActionPill(
    icon: ImageVector,
    contentDescription: String,
    containerColor: Color,
    iconTint: Color,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    Box(
        modifier = modifier
            .height(46.dp)
            .clip(RoundedCornerShape(50))
            .background(containerColor)
            .clickable(role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            imageVector = icon,
            contentDescription = contentDescription,
            tint = iconTint,
            modifier = Modifier.size(22.dp)
        )
    }
}

@Composable
private fun FavoriteContactCapsule(
    contact: ContactEntity,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    val palette = LocalWearPalette.current
    val display = contact.displayName.ifBlank { contact.normalizedAddress }
    val avatarFile = remember(contact.avatarPath) {
        contact.avatarPath?.takeIf { it.isNotBlank() }?.let { File(it) }?.takeIf { it.exists() }
    }
    val swatch = remember(contact.normalizedAddress) {
        avatarSwatchFor(contact.normalizedAddress)
    }
    val monogram = remember(display) { avatarMonogram(display) }

    Column(
        modifier = modifier
            .clip(RoundedCornerShape(18.dp))
            .clickable(role = Role.Button, onClick = onClick)
            .padding(bottom = 2.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(46.dp)
                .clip(RoundedCornerShape(50))
                .background(swatch.container),
            contentAlignment = Alignment.Center
        ) {
            if (avatarFile != null) {
                AsyncImage(
                    model = avatarFile,
                    contentDescription = display,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize()
                )
            } else if (monogram != null) {
                Text(
                    text = monogram,
                    style = centeredTextStyle(19.sp, 22.sp, FontWeight.SemiBold),
                    color = swatch.content,
                    textAlign = TextAlign.Center
                )
            } else {
                Icon(
                    imageVector = Icons.Rounded.Person,
                    contentDescription = display,
                    tint = swatch.content,
                    modifier = Modifier.size(22.dp)
                )
            }
        }

        Spacer(modifier = Modifier.height(4.dp))

        Text(
            text = display,
            style = centeredTextStyle(13.sp, 16.sp, FontWeight.Medium),
            color = palette.onSurface,
            textAlign = TextAlign.Center,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 2.dp)
        )
    }
}

@Composable
private fun DialpadDisplayPill(
    number: String,
    modifier: Modifier = Modifier
) {
    val palette = LocalWearPalette.current
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(38.dp)
            .clip(RoundedCornerShape(50))
            .background(palette.surfaceContainer)
            .padding(horizontal = 14.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = number.ifEmpty { "Enter number" },
            style = centeredTextStyle(15.sp, 18.sp, FontWeight.Medium),
            color = if (number.isEmpty()) palette.onSurfaceVariant else palette.onSurface,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun DialpadKeypadRow(
    keys: List<String>,
    onAppend: (String) -> Unit,
    onBackspace: () -> Unit,
    onClear: () -> Unit,
    modifier: Modifier = Modifier
) {
    val palette = LocalWearPalette.current
    Row(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(5.dp)
    ) {
        for (key in keys) {
            if (key == "BACK") {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .height(34.dp)
                        .clip(RoundedCornerShape(50))
                        .background(palette.surfaceContainerHigh)
                        .combinedClickable(
                            onClick = onBackspace,
                            onLongClick = onClear
                        ),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Rounded.Backspace,
                        contentDescription = "Backspace",
                        tint = palette.onSurface,
                        modifier = Modifier.size(17.dp)
                    )
                }
            } else {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .height(34.dp)
                        .clip(RoundedCornerShape(50))
                        .background(palette.surfaceContainer)
                        .clickable(role = Role.Button) { onAppend(key) },
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = key,
                        style = centeredTextStyle(16.sp, 18.sp, FontWeight.Medium),
                        color = palette.onSurface
                    )
                }
            }
        }
    }
}
