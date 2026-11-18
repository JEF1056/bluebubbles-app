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

object RemoteLauncher {
    private const val TAG = "RemoteLauncher"

    fun openServerOnPhone(context: Context) {
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val url = SettingsDataStore(context).getServerUrl()
                if (url.isBlank()) return@launch
                val helper = RemoteActivityHelper(context)
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    addCategory(Intent.CATEGORY_BROWSABLE)
                    data = Uri.parse(url)
                }
                helper.startRemoteActivity(intent, null)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to open on phone: ${e.message}")
            }
        }
    }
}
