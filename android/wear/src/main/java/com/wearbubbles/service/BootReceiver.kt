package com.wearbubbles.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.wearbubbles.WearBubblesApp
import com.wearbubbles.data.SettingsDataStore
import com.wearbubbles.worker.MessageSyncWorker
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) {
            return
        }

        val appContext = context.applicationContext
        val app = appContext as? WearBubblesApp ?: return
        val pendingResult = goAsync()

        CoroutineScope(Dispatchers.IO).launch {
            try {
                val settings = SettingsDataStore(appContext)
                if (settings.isConfigured.first() && !app.phoneRelayClient.refreshPhoneConnected()) {
                    MessageSyncWorker.schedule(appContext)
                    try {
                        MessageListenerService.start(appContext)
                    } catch (_: Exception) {
                    }
                } else {
                    MessageSyncWorker.cancel(appContext)
                }
            } finally {
                pendingResult.finish()
            }
        }
    }
}
