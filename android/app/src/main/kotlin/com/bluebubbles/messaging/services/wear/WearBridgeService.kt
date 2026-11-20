package com.bluebubbles.messaging.services.wear

import com.bluebubbles.messaging.utils.PersistentLog
import com.google.android.gms.wearable.CapabilityInfo
import com.google.android.gms.wearable.ChannelClient
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import com.google.gson.JsonParser
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext
import java.io.File
import java.net.URLDecoder

class WearBridgeService : WearableListenerService() {
    companion object {
        private const val TAG = "WearBridgeService"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onCapabilityChanged(capabilityInfo: CapabilityInfo) {
        if (capabilityInfo.name == WearSyncManager.WATCH_CAPABILITY) {
            val connected = capabilityInfo.nodes.isNotEmpty()
            WearSyncManager.updateWatchConnectedCache(applicationContext, connected)
            if (connected) {
                WearSyncManager.syncCredentials(applicationContext)
            } else {
                WearSyncManager.setWatchActive(applicationContext, false)
            }
        }
    }

    override fun onMessageReceived(messageEvent: MessageEvent) {
        val path = messageEvent.path
        val nodeId = messageEvent.sourceNodeId
        val dataStr = String(messageEvent.data, Charsets.UTF_8)
        WearSyncManager.updateWatchConnectedCache(applicationContext, true)

        when (path) {
            WearSyncManager.PATH_REQUEST_CREDENTIALS -> {
                WearSyncManager.syncCredentials(applicationContext, nodeId)
            }
            WearSyncManager.PATH_REQUEST_SYNC -> {
                val obj = parseJson(dataStr) ?: return
                when (obj.str("type")) {
                    "chats" -> WearSyncManager.syncChats(applicationContext, nodeId)
                    "messages" -> {
                        val chatGuid = obj.str("chatGuid") ?: return
                        val before = if (obj.has("before") && !obj.get("before").isJsonNull) {
                            obj.get("before").asLong
                        } else {
                            null
                        }
                        WearSyncManager.syncMessages(applicationContext, chatGuid, before, nodeId)
                    }
                    "contacts" -> WearSyncManager.syncContacts(applicationContext, nodeId)
                    "credentials" -> WearSyncManager.syncCredentials(applicationContext, nodeId)
                }
            }
            WearSyncManager.PATH_SEND_MESSAGE -> {
                val obj = parseJson(dataStr) ?: return
                val chatGuid = obj.str("chatGuid") ?: return
                val text = obj.str("text") ?: return
                val tempGuid = obj.str("tempGuid") ?: return
                val requestId = obj.str("requestId") ?: tempGuid
                WearSyncManager.sendTextMessage(applicationContext, nodeId, chatGuid, text, tempGuid, requestId)
            }
            WearSyncManager.PATH_SEND_REACTION -> {
                val obj = parseJson(dataStr) ?: return
                val chatGuid = obj.str("chatGuid") ?: return
                val msgGuid = obj.str("selectedMessageGuid") ?: return
                val reaction = obj.str("reaction") ?: return
                val partIndex = if (obj.has("partIndex") && !obj.get("partIndex").isJsonNull) {
                    obj.get("partIndex").asInt
                } else {
                    0
                }
                val requestId = obj.str("requestId") ?: msgGuid
                val tempGuid = obj.str("tempGuid")
                WearSyncManager.sendReaction(applicationContext, nodeId, chatGuid, msgGuid, reaction, partIndex, requestId, tempGuid)
            }
            WearSyncManager.PATH_REQUEST_ATTACHMENT -> {
                val obj = parseJson(dataStr) ?: return
                val attachmentGuid = obj.str("attachmentGuid") ?: return
                WearSyncManager.streamAttachmentToWatch(applicationContext, nodeId, attachmentGuid)
            }
            WearSyncManager.PATH_MARK_READ -> {
                val chatGuid = parseJson(dataStr)?.str("chatGuid") ?: return
                WearSyncManager.handleMarkReadFromWatch(applicationContext, chatGuid)
            }
            WearSyncManager.PATH_DISMISS_NOTIFICATION -> {
                val chatGuid = parseJson(dataStr)?.str("chatGuid") ?: return
                WearSyncManager.handleDismissFromWatch(applicationContext, chatGuid)
            }
            WearSyncManager.PATH_WATCH_ACTIVE -> {
                val obj = parseJson(dataStr)
                val active = obj != null && obj.has("active") && obj.get("active").asBoolean
                WearSyncManager.setWatchActive(applicationContext, active)
            }
            WearSyncManager.PATH_ANSWER_CALL_AUDIO -> {
                val obj = parseJson(dataStr) ?: return
                val callUuid = obj.str("callUuid") ?: return
                WearSyncManager.handleAnswerCallAudioFromWatch(
                    context = applicationContext,
                    callUuid = callUuid,
                    callerNameArg = obj.str("callerName"),
                    callerAddressArg = obj.str("callerAddress")
                )
            }
            WearSyncManager.PATH_DECLINE_CALL -> {
                val callUuid = parseJson(dataStr)?.str("callUuid") ?: return
                WearSyncManager.handleDeclineCallFromWatch(applicationContext, callUuid)
            }
            WearSyncManager.PATH_OPEN_CHAT -> {
                val chatGuid = parseJson(dataStr)?.str("chatGuid") ?: return
                WearSyncManager.handleOpenChatFromWatch(applicationContext, chatGuid)
            }
        }
    }

    override fun onChannelOpened(channel: ChannelClient.Channel) {
        val path = channel.path
        if (!path.startsWith(WearSyncManager.PATH_SEND_AUDIO_PREFIX)) return
        // Path format: /bb/send-audio/<urlEncodedChatGuid>/<urlEncodedTempGuid>
        val rest = path.removePrefix(WearSyncManager.PATH_SEND_AUDIO_PREFIX)
        val parts = rest.split("/", limit = 2)
        if (parts.size < 2) return
        val chatGuid = URLDecoder.decode(parts[0], "UTF-8")
        val tempGuid = URLDecoder.decode(parts[1], "UTF-8")
        val nodeId = channel.nodeId

        WearSyncManager.scope.launch {
            val channelClient = Wearable.getChannelClient(applicationContext)
            val tempFile = File(applicationContext.cacheDir, "wear_audio_${System.currentTimeMillis()}.m4a")
            try {
                val input = channelClient.getInputStream(channel).await()
                input.use { inStream ->
                    tempFile.outputStream().use { outStream ->
                        inStream.copyTo(outStream)
                    }
                }
                WearSyncManager.sendAudioAttachment(applicationContext, nodeId, chatGuid, tempGuid, tempFile)
            } catch (e: Exception) {
                PersistentLog.e(applicationContext, TAG, "onChannelOpened audio read failed: ${e.message}")
                tempFile.delete()
                WearSyncManager.notifyAudioReceiveFailed(
                    applicationContext,
                    nodeId,
                    tempGuid,
                    e.message ?: "Audio stream failed"
                )
            } finally {
                withContext(NonCancellable) {
                    try {
                        channelClient.close(channel).await()
                    } catch (_: Exception) {
                    }
                }
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        scope.cancel()
    }

    private fun parseJson(raw: String) = try {
        JsonParser.parseString(raw).asJsonObject
    } catch (_: Exception) {
        null
    }

    private fun com.google.gson.JsonObject.str(key: String): String? =
        if (has(key) && !get(key).isJsonNull) get(key).asString else null
}
