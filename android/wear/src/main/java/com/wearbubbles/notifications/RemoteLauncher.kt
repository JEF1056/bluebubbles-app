package com.wearbubbles.notifications

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import androidx.wear.remote.interactions.RemoteActivityHelper
import com.wearbubbles.WearBubblesApp
import com.wearbubbles.data.SettingsDataStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.TimeUnit

object RemoteLauncher {
    private const val TAG = "RemoteLauncher"

    fun openChatOnPhoneAsync(context: Context, chatGuid: String) {
        val appContext = context.applicationContext
        val scope = (appContext as? WearBubblesApp)?.applicationScope ?: CoroutineScope(Dispatchers.IO)
        scope.launch {
            openChatOnPhone(appContext, chatGuid)
        }
    }

    suspend fun openChatOnPhone(context: Context, chatGuid: String) {
        val appContext = context.applicationContext
        val relay = (appContext as? WearBubblesApp)?.phoneRelayClient
        val openedViaPhone = if (relay != null && chatGuid.isNotBlank() && relay.refreshPhoneConnected()) {
            relay.sendOpenChatAwait(chatGuid)
        } else {
            false
        }
        if (!openedViaPhone) {
            openServerOnPhone(appContext)
        }
    }

    fun openUrlOnPhoneAsync(context: Context, url: String) {
        val parsed = runCatching { Uri.parse(url.trim()) }.getOrNull() ?: return
        val scheme = parsed.scheme?.lowercase()
        if (scheme != "http" && scheme != "https") return
        val appContext = context.applicationContext
        val scope = (appContext as? WearBubblesApp)?.applicationScope ?: CoroutineScope(Dispatchers.IO)
        scope.launch {
            openUriOnPhone(appContext, parsed)
        }
    }

    fun openServerOnPhoneAsync(context: Context) {
        val appContext = context.applicationContext
        CoroutineScope(Dispatchers.IO).launch {
            openServerOnPhone(appContext)
        }
    }

    suspend fun openServerOnPhone(context: Context): Unit = withContext(Dispatchers.IO) {
        val appContext = context.applicationContext
        val url = SettingsDataStore(appContext).getServerUrl()
        if (url.isBlank()) return@withContext
        openUriOnPhone(appContext, Uri.parse(url))
    }

    private suspend fun openUriOnPhone(appContext: Context, uri: Uri): Unit = withContext(Dispatchers.IO) {
        try {
            val helper = RemoteActivityHelper(appContext)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                addCategory(Intent.CATEGORY_BROWSABLE)
                data = uri
            }
            helper.startRemoteActivity(intent, null).get(10, TimeUnit.SECONDS)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to open on phone: ${e.message}")
        }
    }
}
