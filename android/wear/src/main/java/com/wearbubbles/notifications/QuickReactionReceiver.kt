package com.wearbubbles.notifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.wearbubbles.WearBubblesApp
import com.wearbubbles.api.ApiClient
import com.wearbubbles.api.dto.ReactRequest
import com.wearbubbles.data.SettingsDataStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

class QuickReactionReceiver : BroadcastReceiver() {

    internal data class ReactionPayload(
        val chatGuid: String,
        val messageGuid: String,
        val reaction: String
    )

    companion object {
        private const val TAG = "QuickReactionReceiver"

        internal fun parseReactionExtras(intent: Intent): ReactionPayload? {
            val chatGuid = intent.getStringExtra(NotificationHelper.EXTRA_CHAT_GUID)
                ?.takeIf { it.isNotBlank() } ?: return null
            val messageGuid = intent.getStringExtra(NotificationHelper.EXTRA_MESSAGE_GUID)
                ?.takeIf { it.isNotBlank() } ?: return null
            val reaction = intent.getStringExtra(NotificationHelper.EXTRA_REACTION)
                ?.takeIf { it.isNotBlank() } ?: return null
            return ReactionPayload(chatGuid = chatGuid, messageGuid = messageGuid, reaction = reaction)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        val payload = parseReactionExtras(intent) ?: return
        NotificationHelper.cancelNotification(context, payload.chatGuid)

        val pendingResult = goAsync()
        val appContext = context.applicationContext
        val app = appContext as WearBubblesApp
        val relay = app.phoneRelayClient

        CoroutineScope(Dispatchers.IO).launch {
            try {
                withTimeout(10_000L) {
                    val sentViaRelay = if (relay.refreshPhoneConnected()) {
                        val res = relay.sendReaction(
                            chatGuid = payload.chatGuid,
                            selectedMessageGuid = payload.messageGuid,
                            reaction = payload.reaction
                        )
                        res != null && res.success
                    } else {
                        false
                    }

                    if (!sentViaRelay) {
                        val settings = SettingsDataStore(appContext)
                        val url = settings.getServerUrl()
                        val password = settings.getPassword()
                        if (url.isNotBlank() && password.isNotBlank()) {
                            ApiClient.getApi(url).reactToMessage(
                                password,
                                ReactRequest(
                                    chatGuid = payload.chatGuid,
                                    selectedMessageGuid = payload.messageGuid,
                                    reaction = payload.reaction
                                )
                            )
                        }
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Failed quick reaction=${payload.reaction} for ${payload.chatGuid}", e)
            } finally {
                pendingResult.finish()
            }
        }
    }
}
