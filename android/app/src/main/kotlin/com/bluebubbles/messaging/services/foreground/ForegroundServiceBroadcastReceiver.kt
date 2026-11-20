package com.bluebubbles.messaging.services.foreground

import android.app.ForegroundServiceStartNotAllowedException
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.utils.PersistentLog

class ForegroundServiceBroadcastReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        PersistentLog.d(context, Constants.logTag, "Received Foreground Service Broadcast")

        val keepAppAlive = context.getSharedPreferences("FlutterSharedPreferences", 0)
            .getBoolean("keepAppAlive", false)
        if (!keepAppAlive) {
            PersistentLog.d(context, Constants.logTag, "Foreground Service disabled; ignoring restart broadcast")
            return
        }

        val serviceIntent = Intent(context, SocketIOForegroundService::class.java)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        } catch (e: Exception) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && e is ForegroundServiceStartNotAllowedException) {
                PersistentLog.w(context, Constants.logTag, "FGS start not allowed from background broadcast: ${e.message}")
            } else {
                PersistentLog.e(context, Constants.logTag, "Failed to start SocketIOForegroundService from broadcast: ${e.message}", e)
            }
        }
    }
}