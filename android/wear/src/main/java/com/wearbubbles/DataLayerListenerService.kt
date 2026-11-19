package com.wearbubbles

import android.net.Uri
import android.util.Log
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
import com.wearbubbles.data.SettingsDataStore
import com.wearbubbles.db.AppDatabase
import com.wearbubbles.notifications.CallNotificationHelper
import com.wearbubbles.notifications.NotificationHelper
import com.wearbubbles.relay.PhoneRelayClient
import com.wearbubbles.service.MessageListenerService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import java.io.File
import java.net.URLDecoder

class DataLayerListenerService : WearableListenerService() {

    companion object {
        private const val TAG = "DataLayerListener"
        private const val PATH_SETUP = "/setup-credentials"
        private const val PATH_SETUP_ACK = "/setup-credentials-ack"
        private const val PATH_RESET = "/reset-watch"
        private const val PATH_RESET_ACK = "/reset-ack"
        private const val PATH_REQUEST_STATUS = "/request-status"
        private const val PATH_WATCH_STATUS = "/watch-status"
    }

    data class SetupPayload(val url: String = "", val password: String = "")

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val gson = Gson()

    override fun onCapabilityChanged(capabilityInfo: CapabilityInfo) {
        if (capabilityInfo.name == PhoneRelayClient.PHONE_CAPABILITY) {
            val connected = capabilityInfo.nodes.isNotEmpty()
            val app = applicationContext as WearBubblesApp
            app.phoneRelayClient.updatePhoneConnected(connected)
            if (connected) {
                app.socketManager.disconnect()
                MessageListenerService.stop(applicationContext)
                scope.launch { app.phoneRelayClient.requestCredentials() }
            } else {
                scope.launch {
                    val settings = SettingsDataStore(applicationContext)
                    if (settings.isConfigured.first()) {
                        try {
                            MessageListenerService.start(applicationContext)
                        } catch (e: Exception) {
                            Log.w(TAG, "Unable to start MessageListenerService from background: ${e.message}")
                        }
                    }
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
                    if (url.isNotBlank() && pass.isNotBlank()) {
                        scope.launch {
                            val settings = SettingsDataStore(applicationContext)
                            settings.saveCredentials(url, pass, headers, privateApi)
                            ApiClient.configureHeaders(url, settings.parseHeaders(headers))
                        }
                    }
                }

                path == PhoneRelayClient.PATH_SYNC_CONTACTS -> {
                    val asset = DataMapItem.fromDataItem(item).dataMap.getAsset("contactsAsset") ?: continue
                    scope.launch {
                        try {
                            val fd = Wearable.getDataClient(applicationContext).getFdForAsset(asset).await()
                            val json = fd.inputStream.bufferedReader().use { it.readText() }
                            fd.release()
                            relay.handleContactsSyncJson(json)
                        } catch (e: Exception) {
                            Log.w(TAG, "Failed to read contactsAsset: ${e.message}")
                        }
                    }
                }

                path.startsWith(PhoneRelayClient.PATH_AVATAR_PREFIX) -> {
                    val map = DataMapItem.fromDataItem(item).dataMap
                    val key = map.getString("key")
                        ?: Uri.decode(path.removePrefix(PhoneRelayClient.PATH_AVATAR_PREFIX))
                    val asset = map.getAsset("avatar") ?: continue
                    scope.launch { relay.handleAvatarAsset(key, asset) }
                }
            }
        }
    }

    override fun onMessageReceived(messageEvent: MessageEvent) {
        val app = applicationContext as WearBubblesApp
        val relay = app.phoneRelayClient
        val dataStr = String(messageEvent.data, Charsets.UTF_8)

        when (messageEvent.path) {
            PhoneRelayClient.PATH_CREDENTIALS -> {
                scope.launch { relay.handleCredentialsJson(dataStr) }
            }
            PhoneRelayClient.PATH_SYNC_CHATS -> {
                scope.launch { relay.handleChatsSyncJson(dataStr) }
            }
            PhoneRelayClient.PATH_SYNC_MESSAGES -> {
                scope.launch { relay.handleMessagesSyncJson(dataStr) }
            }
            PhoneRelayClient.PATH_SYNC_CONTACTS -> {
                scope.launch { relay.handleContactsSyncJson(dataStr) }
            }
            PhoneRelayClient.PATH_NEW_MESSAGE -> {
                scope.launch { relay.handleIncomingMessageJson(dataStr, isUpdate = false) }
            }
            PhoneRelayClient.PATH_UPDATED_MESSAGE -> {
                scope.launch { relay.handleIncomingMessageJson(dataStr, isUpdate = true) }
            }
            PhoneRelayClient.PATH_TYPING_INDICATOR -> {
                relay.handleTypingJson(dataStr)
            }
            PhoneRelayClient.PATH_SEND_RESULT -> {
                relay.handleSendResultJson(dataStr)
            }
            PhoneRelayClient.PATH_DISMISS_NOTIFICATION -> {
                val chatGuid = try {
                    JsonParser.parseString(dataStr).asJsonObject.get("chatGuid")?.asString
                } catch (_: Exception) {
                    null
                }
                if (!chatGuid.isNullOrBlank()) {
                    NotificationHelper.cancelNotification(applicationContext, chatGuid)
                }
            }
            PhoneRelayClient.PATH_MARK_READ -> {
                val chatGuid = try {
                    JsonParser.parseString(dataStr).asJsonObject.get("chatGuid")?.asString
                } catch (_: Exception) {
                    null
                }
                if (!chatGuid.isNullOrBlank()) {
                    NotificationHelper.cancelNotification(applicationContext, chatGuid)
                    scope.launch { AppDatabase.getInstance(applicationContext).chatDao().markRead(chatGuid) }
                }
            }
            PhoneRelayClient.PATH_INCOMING_CALL -> {
                try {
                    val obj = JsonParser.parseString(dataStr).asJsonObject
                    val callUuid = obj.get("callUuid")?.asString ?: return
                    val callerName = obj.get("callerName")?.takeIf { !it.isJsonNull }?.asString ?: "FaceTime"
                    val callerAddress = obj.get("callerAddress")?.takeIf { !it.isJsonNull }?.asString ?: ""
                    val isVideo = obj.get("isVideo")?.takeIf { !it.isJsonNull }?.asBoolean ?: false
                    CallNotificationHelper.showIncomingCall(
                        context = applicationContext,
                        callUuid = callUuid,
                        callerName = callerName,
                        callerAddress = callerAddress,
                        isVideo = isVideo,
                        fromPhoneRelay = true
                    )
                } catch (e: Exception) {
                    Log.w(TAG, "Failed to parse incoming call: ${e.message}")
                }
            }
            PhoneRelayClient.PATH_CALL_ENDED -> {
                val callUuid = try {
                    JsonParser.parseString(dataStr).asJsonObject.get("callUuid")?.asString
                } catch (_: Exception) {
                    null
                }
                if (!callUuid.isNullOrBlank()) {
                    CallNotificationHelper.endCall(applicationContext, callUuid)
                }
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

        scope.launch {
            val channelClient = Wearable.getChannelClient(applicationContext)
            val tempFile = File(applicationContext.cacheDir, "tmp_att_${System.currentTimeMillis()}")
            try {
                val input = channelClient.getInputStream(channel).await()
                input.use { inStream ->
                    tempFile.outputStream().use { outStream ->
                        inStream.copyTo(outStream)
                    }
                }
                app.phoneRelayClient.saveStreamedAttachment(attachmentGuid, tempFile)
            } catch (e: Exception) {
                Log.e(TAG, "onChannelOpened attachment failed: ${e.message}")
                tempFile.delete()
            } finally {
                try {
                    channelClient.close(channel).await()
                } catch (_: Exception) {
                }
            }
        }
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
                if (!app.phoneRelayClient.refreshPhoneConnected()) {
                    MessageListenerService.start(applicationContext)
                }

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
                (applicationContext as WearBubblesApp).socketManager.disconnect()
                MessageListenerService.stop(applicationContext)
                SettingsDataStore(applicationContext).clearAll()
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

    override fun onDestroy() {
        super.onDestroy()
        scope.cancel()
    }
}
