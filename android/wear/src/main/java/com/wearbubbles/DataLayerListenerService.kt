package com.wearbubbles

import android.net.Uri
import android.util.Log
import com.google.android.gms.wearable.Asset
import com.google.android.gms.wearable.CapabilityInfo
import com.google.android.gms.wearable.ChannelClient
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import com.google.gson.Gson
import com.google.gson.JsonParser
import com.wearbubbles.api.ApiClient
import com.wearbubbles.data.ContactRepository
import com.wearbubbles.data.SettingsDataStore
import com.wearbubbles.db.AppDatabase
import com.wearbubbles.notifications.CallNotificationHelper
import com.wearbubbles.notifications.NotificationHelper
import com.wearbubbles.relay.PhoneRelayClient
import com.wearbubbles.worker.MessageSyncWorker
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import java.io.File
import java.net.URLDecoder

class DataLayerListenerService : WearableListenerService() {

    internal data class IncomingCallPayload(
        val callUuid: String,
        val callerName: String,
        val callerAddress: String,
        val isVideo: Boolean,
        val isTelephony: Boolean,
        val isGroup: Boolean = false
    )

    internal data class CallActivePayload(
        val callUuid: String,
        val startedAtMs: Long,
        val muted: Boolean,
        val callerName: String? = null,
        val callerAddress: String? = null,
        val isVideo: Boolean = false,
        val isTelephony: Boolean = false,
        val isGroup: Boolean = false
    )

    companion object {
        private const val TAG = "DataLayerListener"
        internal const val DISCONNECT_DEBOUNCE_MS = 25_000L
        private const val PATH_SETUP = "/setup-credentials"
        private const val PATH_SETUP_ACK = "/setup-credentials-ack"
        private const val PATH_RESET = "/reset-watch"
        private const val PATH_RESET_ACK = "/reset-ack"
        private const val PATH_REQUEST_STATUS = "/request-status"
        private const val PATH_WATCH_STATUS = "/watch-status"
        internal const val PATH_PHONE_ACTIVE_CHAT = "/wearbubbles/phone_active_chat"

        internal fun parsePhoneActiveChatGuid(json: String): String? =
            try {
                JsonParser.parseString(json).asJsonObject
                    .get("chatGuid")?.takeIf { !it.isJsonNull }?.asString?.takeIf { it.isNotBlank() }
            } catch (_: Exception) {
                null
            }

        internal fun parseIncomingCallPayload(json: String): IncomingCallPayload? {
            val obj = try {
                JsonParser.parseString(json).asJsonObject
            } catch (_: Exception) {
                null
            } ?: return null
            val callUuid = obj.get("callUuid")?.takeIf { !it.isJsonNull }?.asString ?: return null
            if (callUuid.isBlank()) return null
            val isTelephony = try {
                obj.get("isTelephony")?.takeIf { !it.isJsonNull }?.asBoolean ?: false
            } catch (_: Exception) {
                false
            }
            val isVideo = try {
                obj.get("isVideo")?.takeIf { !it.isJsonNull }?.asBoolean ?: false
            } catch (_: Exception) {
                false
            } && !isTelephony
            val isGroup = try {
                obj.get("isGroup")?.takeIf { !it.isJsonNull && it.isJsonPrimitive }?.asBoolean ?: false
            } catch (_: Exception) {
                false
            } && !isTelephony
            val callerAddress = obj.get("callerAddress")?.takeIf { !it.isJsonNull }?.asString ?: ""
            val callerName = obj.get("callerName")?.takeIf { !it.isJsonNull }?.asString?.takeIf { it.isNotBlank() }
                ?: callerAddress.takeIf { it.isNotBlank() }
                ?: CallNotificationHelper.callKindLabel(isVideo = isVideo, isTelephony = isTelephony, isGroup = isGroup)
            return IncomingCallPayload(
                callUuid = callUuid,
                callerName = callerName,
                callerAddress = callerAddress,
                isVideo = isVideo,
                isTelephony = isTelephony,
                isGroup = isGroup
            )
        }

        internal fun parseCallActivePayload(json: String): CallActivePayload? {
            val obj = try {
                JsonParser.parseString(json).asJsonObject
            } catch (_: Exception) {
                null
            } ?: return null
            val callUuid = obj.get("callUuid")?.takeIf { !it.isJsonNull }?.asString ?: return null
            if (callUuid.isBlank()) return null
            val startedAtMs = try {
                obj.get("startedAtMs")?.takeIf { !it.isJsonNull && it.isJsonPrimitive }?.asLong ?: 0L
            } catch (_: Exception) {
                0L
            }
            val muted = try {
                obj.get("muted")?.takeIf { !it.isJsonNull && it.isJsonPrimitive }?.asBoolean ?: false
            } catch (_: Exception) {
                false
            }
            val callerName = obj.get("callerName")?.takeIf { !it.isJsonNull && it.isJsonPrimitive }?.asString?.takeIf { it.isNotBlank() }
            val callerAddress = obj.get("callerAddress")?.takeIf { !it.isJsonNull && it.isJsonPrimitive }?.asString?.takeIf { it.isNotBlank() }
            val isTelephony = try {
                obj.get("isTelephony")?.takeIf { !it.isJsonNull && it.isJsonPrimitive }?.asBoolean ?: false
            } catch (_: Exception) {
                false
            }
            val isVideo = try {
                obj.get("isVideo")?.takeIf { !it.isJsonNull && it.isJsonPrimitive }?.asBoolean ?: false
            } catch (_: Exception) {
                false
            } && !isTelephony
            val isGroup = try {
                obj.get("isGroup")?.takeIf { !it.isJsonNull && it.isJsonPrimitive }?.asBoolean ?: false
            } catch (_: Exception) {
                false
            } && !isTelephony
            return CallActivePayload(
                callUuid = callUuid,
                startedAtMs = startedAtMs,
                muted = muted,
                callerName = callerName,
                callerAddress = callerAddress,
                isVideo = isVideo,
                isTelephony = isTelephony,
                isGroup = isGroup
            )
        }

        private val disconnectJobLock = Any()
        @Volatile
        private var pendingDisconnectJob: Job? = null

        internal fun cancelPendingDisconnect() {
            synchronized(disconnectJobLock) {
                pendingDisconnectJob?.cancel()
                pendingDisconnectJob = null
            }
        }

        internal fun scheduleDebouncedDisconnect(
            scope: CoroutineScope,
            delayMs: Long = DISCONNECT_DEBOUNCE_MS,
            confirmStillDisconnected: suspend () -> Boolean,
            onConfirmedDisconnect: suspend () -> Unit
        ): Job {
            val job = scope.launch {
                delay(delayMs)
                if (confirmStillDisconnected()) {
                    onConfirmedDisconnect()
                }
            }
            synchronized(disconnectJobLock) {
                pendingDisconnectJob?.cancel()
                pendingDisconnectJob = job
            }
            return job
        }
    }

    data class SetupPayload(val url: String = "", val password: String = "")

    private val scope get() = (applicationContext as WearBubblesApp).applicationScope
    private val gson = Gson()

    override fun onCapabilityChanged(capabilityInfo: CapabilityInfo) {
        if (capabilityInfo.name == PhoneRelayClient.PHONE_CAPABILITY) {
            val app = applicationContext as WearBubblesApp
            app.phoneRelayClient.invalidateNodeCache()
            scope.launch {
                val settings = SettingsDataStore(applicationContext)
                val userDisconnected = settings.isUserDisconnected()
                val hasCreds = settings.isConfigured.first()
                val connected = PhoneRelayClient.selectRelayNode(capabilityInfo.nodes, hasCreds) != null
                if (connected) {
                    cancelPendingDisconnect()
                    app.phoneRelayClient.updatePhoneConnected(true)
                    app.socketManager.disconnect()
                    MessageSyncWorker.cancel(applicationContext)
                    if (!userDisconnected) {
                        app.phoneRelayClient.requestCredentials()
                    }
                } else if (hasCreds && !userDisconnected) {
                    // Debounce brief BTC blips before flipping standalone mode.
                    scheduleDebouncedDisconnect(
                        scope = scope,
                        confirmStillDisconnected = { !app.phoneRelayClient.refreshPhoneConnected() },
                        onConfirmedDisconnect = {
                            // refreshPhoneConnected() already updated isPhoneConnected for any active ForegroundSocketSession.
                        }
                    )
                } else {
                    cancelPendingDisconnect()
                    app.phoneRelayClient.updatePhoneConnected(false)
                }
            }
        }
    }

    override fun onDataChanged(dataEvents: DataEventBuffer) {
        val app = applicationContext as WearBubblesApp
        val relay = app.phoneRelayClient

        for (event in dataEvents) {
            if (event.type != DataEvent.TYPE_CHANGED) continue
            val item = event.dataItem
            val path = item.uri.path ?: continue

            when {
                path == PhoneRelayClient.PATH_CREDENTIALS -> {
                    val map = DataMapItem.fromDataItem(item).dataMap
                    val url = map.getString("serverUrl") ?: ""
                    val pass = map.getString("password") ?: ""
                    val headers = map.getString("customHeadersJson") ?: "{}"
                    val privateApi = map.getBoolean("privateApiSend", false)
                    val privateMarkChatAsRead = map.getBoolean("privateMarkChatAsRead", false)
                    if (url.isNotBlank() && pass.isNotBlank()) {
                        scope.launch {
                            val settings = SettingsDataStore(applicationContext)
                            if (settings.isUserDisconnected()) return@launch
                            settings.saveCredentials(url, pass, headers, privateApi, privateMarkChatAsRead)
                            ApiClient.configureHeaders(url, settings.parseHeaders(headers))
                        }
                    }
                }

                path == PhoneRelayClient.PATH_SYNC_CHATS -> {
                    val map = DataMapItem.fromDataItem(item).dataMap
                    val asset = map.getAsset("payload") ?: map.getAsset("chatsAsset") ?: continue
                    scope.launch {
                        if (SettingsDataStore(applicationContext).isUserDisconnected()) return@launch
                        readAssetText(asset)?.let { relay.handleChatsSyncJson(it) }
                    }
                }

                path == PhoneRelayClient.PATH_SYNC_MESSAGES ||
                    path.startsWith("${PhoneRelayClient.PATH_SYNC_MESSAGES}/") -> {
                    val map = DataMapItem.fromDataItem(item).dataMap
                    val asset = map.getAsset("payload") ?: map.getAsset("messagesAsset") ?: continue
                    scope.launch {
                        if (SettingsDataStore(applicationContext).isUserDisconnected()) return@launch
                        readAssetText(asset)?.let { relay.handleMessagesSyncJson(it) }
                    }
                }

                path == PhoneRelayClient.PATH_SYNC_CONTACTS -> {
                    val map = DataMapItem.fromDataItem(item).dataMap
                    val asset = map.getAsset("payload") ?: map.getAsset("contactsAsset") ?: continue
                    scope.launch {
                        if (SettingsDataStore(applicationContext).isUserDisconnected()) return@launch
                        readAssetText(asset)?.let { relay.handleContactsSyncJson(it) }
                    }
                }

                path.startsWith(PhoneRelayClient.PATH_AVATAR_PREFIX) -> {
                    val map = DataMapItem.fromDataItem(item).dataMap
                    val key = map.getString("key")
                        ?: Uri.decode(path.removePrefix(PhoneRelayClient.PATH_AVATAR_PREFIX))
                    val asset = map.getAsset("avatar") ?: continue
                    scope.launch {
                        if (SettingsDataStore(applicationContext).isUserDisconnected()) return@launch
                        relay.handleAvatarAsset(key, asset)
                    }
                }

                path == PhoneRelayClient.PATH_PROFILE -> {
                    val map = DataMapItem.fromDataItem(item).dataMap
                    val userName = map.getString("userName") ?: ""
                    val userHandle = map.getString("userHandle") ?: ""
                    val asset = map.getAsset("avatar")
                    scope.launch {
                        if (SettingsDataStore(applicationContext).isUserDisconnected()) return@launch
                        val bytes = asset?.let { readAssetBytes(it) }
                        relay.handleProfileSync(userName, userHandle, bytes)
                    }
                }
            }
        }
    }

    private suspend fun readAssetBytes(asset: Asset): ByteArray? = try {
        val fd = Wearable.getDataClient(applicationContext).getFdForAsset(asset).await()
        try {
            fd.inputStream.use { it.readBytes() }
        } finally {
            fd.release()
        }
    } catch (_: Exception) {
        null
    }

    override fun onMessageReceived(messageEvent: MessageEvent) {
        val app = applicationContext as WearBubblesApp
        val relay = app.phoneRelayClient
        val dataStr = String(messageEvent.data, Charsets.UTF_8)

        when (messageEvent.path) {
            PhoneRelayClient.PATH_CREDENTIALS -> {
                scope.launch {
                    if (SettingsDataStore(applicationContext).isUserDisconnected()) return@launch
                    relay.handleCredentialsJson(dataStr)
                }
            }
            PhoneRelayClient.PATH_PROFILE -> {
                scope.launch {
                    if (SettingsDataStore(applicationContext).isUserDisconnected()) return@launch
                    relay.handleProfileJson(dataStr)
                }
            }
            PhoneRelayClient.PATH_SYNC_CHATS -> {
                scope.launch {
                    if (SettingsDataStore(applicationContext).isUserDisconnected()) return@launch
                    relay.handleChatsSyncJson(dataStr)
                }
            }
            PhoneRelayClient.PATH_SYNC_MESSAGES -> {
                scope.launch {
                    if (SettingsDataStore(applicationContext).isUserDisconnected()) return@launch
                    relay.handleMessagesSyncJson(dataStr)
                }
            }
            PhoneRelayClient.PATH_SYNC_CONTACTS -> {
                scope.launch {
                    if (SettingsDataStore(applicationContext).isUserDisconnected()) return@launch
                    relay.handleContactsSyncJson(dataStr)
                }
            }
            PhoneRelayClient.PATH_NEW_MESSAGE -> {
                scope.launch {
                    if (SettingsDataStore(applicationContext).isUserDisconnected()) return@launch
                    relay.handleIncomingMessageJson(dataStr, isUpdate = false)
                }
            }
            PhoneRelayClient.PATH_UPDATED_MESSAGE -> {
                scope.launch {
                    if (SettingsDataStore(applicationContext).isUserDisconnected()) return@launch
                    relay.handleIncomingMessageJson(dataStr, isUpdate = true)
                }
            }
            PhoneRelayClient.PATH_TYPING_INDICATOR -> {
                relay.handleTypingJson(dataStr)
            }
            PhoneRelayClient.PATH_SEND_RESULT -> {
                relay.handleSendResultJson(dataStr)
            }
            PhoneRelayClient.PATH_ATTACHMENT_FAILED -> {
                val obj = parseJsonObject(dataStr)
                val guid = obj?.stringOrNull("guid") ?: obj?.stringOrNull("attachmentGuid")
                if (!guid.isNullOrBlank()) relay.failAttachmentRequest(guid)
            }
            PhoneRelayClient.PATH_AUDIO_FAILED -> {
                val obj = parseJsonObject(dataStr)
                val tempGuid = obj?.stringOrNull("tempGuid")
                if (!tempGuid.isNullOrBlank()) relay.failAudioRequest(tempGuid, obj.stringOrNull("reason"))
            }
            PhoneRelayClient.PATH_DISMISS_NOTIFICATION -> {
                parseJsonObject(dataStr)?.stringOrNull("chatGuid")?.takeIf { it.isNotBlank() }?.let {
                    NotificationHelper.cancelNotification(applicationContext, it)
                }
            }
            PhoneRelayClient.PATH_MARK_READ -> {
                parseJsonObject(dataStr)?.stringOrNull("chatGuid")?.takeIf { it.isNotBlank() }?.let { chatGuid ->
                    NotificationHelper.cancelNotification(applicationContext, chatGuid)
                    relay.notifyChatMarkedRead(chatGuid)
                    scope.launch { AppDatabase.getInstance(applicationContext).chatDao().markRead(chatGuid) }
                }
            }
            PhoneRelayClient.PATH_MESSAGE_NOTIFICATION -> {
                val obj = parseJsonObject(dataStr) ?: return
                val chatGuid = obj.stringOrNull("chatGuid")?.takeIf { it.isNotBlank() } ?: return
                val senderName = obj.stringOrNull("senderName")?.takeIf { it.isNotBlank() } ?: "BlueBubbles"
                val messageText = obj.stringOrNull("messageText")?.takeIf { it.isNotBlank() } ?: "New message"
                val isGroup = runCatching { obj.get("isGroup")?.asBoolean }.getOrNull() ?: false
                val groupTitle = obj.stringOrNull("groupTitle")
                val timestamp = runCatching { obj.get("timestamp")?.asLong }.getOrNull() ?: System.currentTimeMillis()
                val isTapback = runCatching { obj.get("isTapback")?.asBoolean }.getOrNull() ?: false
                val onlyAlertOnce = runCatching { obj.get("onlyAlertOnce")?.asBoolean }.getOrNull() ?: isTapback
                val senderAddress = obj.stringOrNull("senderAddress")
                val messageGuid = obj.stringOrNull("messageGuid")
                val photoThumbB64 = obj.stringOrNull("photoThumbB64")
                scope.launch {
                    val settings = SettingsDataStore(applicationContext)
                    if (settings.isUserDisconnected()) return@launch
                    val hapticEnabled = settings.hapticEnabled.first()
                    val senderAvatarPath = senderAddress?.let { addr ->
                        val db = AppDatabase.getInstance(applicationContext)
                        ContactRepository(applicationContext, db.contactDao(), settings, relay)
                            .resolveAvatarPath(addr)
                    }
                    NotificationHelper.showMessageNotification(
                        context = applicationContext,
                        chatGuid = chatGuid,
                        senderName = senderName,
                        messageText = messageText,
                        isGroup = isGroup,
                        groupTitle = groupTitle,
                        hapticEnabled = hapticEnabled,
                        timestamp = timestamp,
                        senderAddress = senderAddress,
                        senderAvatarPath = senderAvatarPath,
                        isTapback = isTapback,
                        onlyAlertOnce = onlyAlertOnce,
                        messageGuid = messageGuid,
                        photoThumbB64 = photoThumbB64
                    )
                }
            }
            PATH_PHONE_ACTIVE_CHAT -> {
                parseJsonObject(dataStr)?.let {
                    NotificationHelper.setPhoneActiveChat(applicationContext, parsePhoneActiveChatGuid(dataStr))
                }
            }
            PhoneRelayClient.PATH_INCOMING_CALL -> {
                val call = parseIncomingCallPayload(dataStr) ?: return
                CallNotificationHelper.showIncomingCall(
                    context = applicationContext,
                    callUuid = call.callUuid,
                    callerName = call.callerName,
                    callerAddress = call.callerAddress,
                    isVideo = call.isVideo,
                    fromPhoneRelay = true,
                    isTelephony = call.isTelephony,
                    isGroup = call.isGroup
                )
            }
            PhoneRelayClient.PATH_CALL_ENDED -> {
                parseJsonObject(dataStr)?.stringOrNull("callUuid")?.takeIf { it.isNotBlank() }?.let {
                    CallNotificationHelper.endCall(applicationContext, it)
                }
            }
            PhoneRelayClient.PATH_CALL_ACTIVE -> {
                val active = parseCallActivePayload(dataStr) ?: return
                CallNotificationHelper.markOngoingFromPhone(
                    context = applicationContext,
                    callUuid = active.callUuid,
                    startedAtMs = active.startedAtMs,
                    muted = active.muted,
                    callerName = active.callerName,
                    callerAddress = active.callerAddress,
                    isVideo = active.isVideo,
                    isTelephony = active.isTelephony,
                    isGroup = active.isGroup
                )
            }

            // Legacy WearBubbles setup/status compatibility
            PATH_SETUP -> handleSetup(messageEvent)
            PATH_RESET -> handleReset(messageEvent)
            PATH_REQUEST_STATUS -> handleStatusRequest(messageEvent)
        }
    }

    override fun onChannelOpened(channel: ChannelClient.Channel) {
        val path = channel.path
        if (!path.startsWith(PhoneRelayClient.PATH_ATTACHMENT_PREFIX)) return
        val encodedGuid = path.removePrefix(PhoneRelayClient.PATH_ATTACHMENT_PREFIX)
        val attachmentGuid = URLDecoder.decode(encodedGuid, "UTF-8")
        val app = applicationContext as WearBubblesApp
        app.phoneRelayClient.streamAttachmentFromChannel(channel, attachmentGuid)
    }

    private fun handleSetup(messageEvent: MessageEvent) {
        try {
            val json = String(messageEvent.data, Charsets.UTF_8)
            val payload = gson.fromJson(json, SetupPayload::class.java)
            if (payload.url.isBlank() || payload.password.isBlank()) return

            scope.launch {
                val settings = SettingsDataStore(applicationContext)
                settings.saveServerUrl(payload.url)
                settings.savePassword(payload.password)

                val app = applicationContext as WearBubblesApp
                app.phoneRelayClient.refreshPhoneConnected()

                try {
                    Wearable.getMessageClient(applicationContext)
                        .sendMessage(messageEvent.sourceNodeId, PATH_SETUP_ACK, byteArrayOf(1))
                        .await()
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to send setup ack: ${e.message}")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to parse setup credentials", e)
        }
    }

    private fun handleReset(messageEvent: MessageEvent) {
        scope.launch {
            try {
                val app = applicationContext as WearBubblesApp
                app.foregroundSocketSession.stop()
                app.socketManager.disconnect(clearCredentials = true)
                CallNotificationHelper.endCall(applicationContext)
                MessageSyncWorker.cancel(applicationContext)
                NotificationHelper.cancelAll(applicationContext)
                ApiClient.reset()
                app.phoneRelayClient.deleteCredentialsDataItem()
                app.phoneRelayClient.clearLocalCaches()
                SettingsDataStore(applicationContext).clearAll(markDisconnected = true)
                AppDatabase.getInstance(applicationContext).clearAllTables()

                try {
                    Wearable.getMessageClient(applicationContext)
                        .sendMessage(messageEvent.sourceNodeId, PATH_RESET_ACK, byteArrayOf(1))
                        .await()
                } catch (_: Exception) {
                }
            } catch (e: Exception) {
                Log.e(TAG, "Reset failed", e)
            }
        }
    }

    private fun handleStatusRequest(messageEvent: MessageEvent) {
        scope.launch {
            try {
                val settings = SettingsDataStore(applicationContext)
                val url = settings.getServerUrl()
                val password = settings.getPassword()
                val configured = url.isNotBlank() && password.isNotBlank()
                val app = applicationContext as WearBubblesApp

                val status = mapOf(
                    "configured" to configured,
                    "connected" to (app.socketManager.isConnected.value || app.phoneRelayClient.isPhoneConnected.value),
                    "serverUrl" to url
                )
                val json = gson.toJson(status).toByteArray(Charsets.UTF_8)

                Wearable.getMessageClient(applicationContext)
                    .sendMessage(messageEvent.sourceNodeId, PATH_WATCH_STATUS, json)
                    .await()
            } catch (e: Exception) {
                Log.w(TAG, "Failed to send watch status", e)
            }
        }
    }

    private suspend fun readAssetText(asset: com.google.android.gms.wearable.Asset): String? {
        return try {
            val fd = Wearable.getDataClient(applicationContext).getFdForAsset(asset).await()
            try {
                fd.inputStream.bufferedReader().use { it.readText() }
            } finally {
                fd.release()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to read DataItem asset: ${e.message}")
            null
        }
    }

    private fun parseJsonObject(json: String) = try {
        JsonParser.parseString(json).asJsonObject
    } catch (_: Exception) {
        null
    }

    private fun com.google.gson.JsonObject.stringOrNull(key: String): String? =
        get(key)?.takeIf { !it.isJsonNull }?.asString
}
