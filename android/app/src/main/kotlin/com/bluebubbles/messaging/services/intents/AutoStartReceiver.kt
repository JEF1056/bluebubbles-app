package com.bluebubbles.messaging.services.intents

import android.app.ForegroundServiceStartNotAllowedException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.services.foreground.SocketIOForegroundService
import com.bluebubbles.messaging.utils.PersistentLog

/// Receives intents from the system. This is primarily used for auto starting after a reboot
class AutoStartReceiver: BroadcastReceiver() {
    companion object {
        internal fun startForegroundServiceSafely(
            sdkInt: Int,
            startForeground: () -> Unit,
            startLegacy: () -> Unit,
            logWarning: (String) -> Unit,
            logError: (String, Exception) -> Unit,
        ) {
            try {
                if (sdkInt >= Build.VERSION_CODES.O) {
                    startForeground()
                } else {
                    startLegacy()
                }
            } catch (e: Exception) {
                if (sdkInt >= Build.VERSION_CODES.S && e is ForegroundServiceStartNotAllowedException) {
                    logWarning("FGS start not allowed on boot: ${e.message}")
                } else {
                    logError("Failed to start SocketIOForegroundService on boot: ${e.message}", e)
                }
            }
        }
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null || intent == null) return

        PersistentLog.d(context, Constants.logTag, "Received intent ${intent.action} from auto start")
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED -> {
                // Check to see if the foreground service is enabled
                val prefs = context.getSharedPreferences("FlutterSharedPreferences", 0)
                val keepAppAlive: Boolean = prefs.getBoolean("keepAppAlive", false)

                // If the service is enabled, start it
                if (keepAppAlive) {
                    val serviceIntent = Intent(context, SocketIOForegroundService::class.java)
                    startForegroundServiceSafely(
                        sdkInt = Build.VERSION.SDK_INT,
                        startForeground = { context.startForegroundService(serviceIntent) },
                        startLegacy = { context.startService(serviceIntent) },
                        logWarning = { msg -> PersistentLog.w(context, Constants.logTag, msg) },
                        logError = { msg, e -> PersistentLog.e(context, Constants.logTag, msg, e) },
                    )
                }
            }
        }
    }
}