package com.bluebubbles.messaging.services.intents

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.utils.PersistentLog
import com.bluebubbles.messaging.utils.Utils
import io.flutter.plugin.common.MethodChannel

/// Receives intents from other apps. This is primarily used for Tasker integration.
class ExternalIntentReceiver: BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null || intent == null) return

        PersistentLog.d(context, Constants.logTag, "Received intent ${intent.action} from external app")
        when (intent.action) {
            "com.bluebubbles.external.GET_SERVER_URL" -> {
                val password = intent.extras?.getString("password")
                val identifier = intent.extras?.getString("id")
                val prefs = context.getSharedPreferences("FlutterSharedPreferences", 0)
                val storedPassword = prefs.getString("guidAuthKey", "")

                if (!storedPassword.isNullOrEmpty() && !password.isNullOrEmpty() &&
                    java.security.MessageDigest.isEqual(
                        password.toByteArray(Charsets.UTF_8),
                        storedPassword.toByteArray(Charsets.UTF_8)
                    )
                ) {
                    Utils.getServerUrl(context, object : MethodChannel.Result {
                        override fun success(result: Any?) {
                            PersistentLog.d(context, Constants.logTag, "Sending server URL to Tasker")
                            val outIntent = Intent("net.dinglisch.android.taskerm.BB_SERVER_URL")
                                .setPackage("net.dinglisch.android.taskerm")
                                .putExtra("url", result.toString())
                                .putExtra("id", identifier)
                            context.sendBroadcast(outIntent)
                        }

                        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}
                        override fun notImplemented() {}
                    })
                }
            }
        }
    }
}