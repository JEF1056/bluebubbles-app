package com.wearbubbles.notifications

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import androidx.wear.remote.interactions.RemoteActivityHelper
import com.wearbubbles.data.SettingsDataStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.TimeUnit

object RemoteLauncher {
    private const val TAG = "RemoteLauncher"

    fun openServerOnPhoneAsync(context: Context) {
        val appContext = context.applicationContext
        CoroutineScope(Dispatchers.IO).launch {
            openServerOnPhone(appContext)
        }
    }

    suspend fun openServerOnPhone(context: Context): Unit = withContext(Dispatchers.IO) {
        try {
            val appContext = context.applicationContext
            val url = SettingsDataStore(appContext).getServerUrl()
            if (url.isBlank()) return@withContext
            val helper = RemoteActivityHelper(appContext)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                addCategory(Intent.CATEGORY_BROWSABLE)
                data = Uri.parse(url)
            }
            helper.startRemoteActivity(intent, null).get(10, TimeUnit.SECONDS)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to open on phone: ${e.message}")
        }
    }
}
