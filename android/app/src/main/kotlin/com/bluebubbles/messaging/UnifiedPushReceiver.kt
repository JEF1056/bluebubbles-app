package com.bluebubbles.messaging

import com.bluebubbles.messaging.services.backend_ui_interop.DartWorkManager
import com.bluebubbles.messaging.utils.PersistentLog
import com.bluebubbles.messaging.utils.Utils
import com.google.gson.Gson
import com.google.gson.GsonBuilder
import com.google.gson.ToNumberPolicy
import com.google.gson.reflect.TypeToken

import org.unifiedpush.android.connector.MessagingReceiver
import io.flutter.plugin.common.MethodChannel

import android.content.Context
import android.content.Intent
import androidx.core.os.bundleOf

class UnifiedPushReceiver : MessagingReceiver() {
    companion object {
        const val tag: String = "UnifiedPushReceiver"
        internal const val TASKER_EVENT_ACTION = "net.dinglisch.android.taskerm.BB_EVENT"

        private val gson: Gson = GsonBuilder()
            .setObjectToNumberStrategy(ToNumberPolicy.LONG_OR_DOUBLE)
            .create()
        private val mapType = object : TypeToken<Map<String, Any?>>() {}.type

        internal fun parsePayload(msg: String): Pair<String, HashMap<String, Any?>>? {
            if (msg.isBlank()) return null
            val parsed: Map<String, Any?> = try {
                gson.fromJson(msg, mapType) ?: return null
            } catch (_: Exception) {
                return null
            }
            val type = (parsed["type"] as? String)?.takeIf { it.isNotBlank() } ?: return null
            return type to HashMap(parsed)
        }

        internal fun toTaskerExtras(map: Map<String, Any?>): Array<Pair<String, Any?>> =
            map.entries.map { (k, v) ->
                val bundleSafe: Any? = when (v) {
                    null, is String, is Boolean, is Int, is Long, is Double, is Float -> v
                    else -> gson.toJson(v)
                }
                k to bundleSafe
            }.toTypedArray()
    }

    override fun onNewEndpoint(context: Context, endpoint: String, instance: String) {
        PersistentLog.d(context, tag, "New endpoint: $endpoint")

        val data = HashMap<String, Any?>();
        data["endpoint"] = endpoint;
        DartWorkManager.createWorker(context, "unifiedpush-settings", data) {}
    }

    override fun onRegistrationFailed(context: Context, instance: String) {
        PersistentLog.d(context, tag, "Registration Failed")
        val data = HashMap<String, Any?>();
        data["endpoint"] = "";
        DartWorkManager.createWorker(context, "unifiedpush-settings", data) {}
    }

    override fun onUnregistered(context: Context, instance: String) {
        PersistentLog.d(context, tag, "Unregistered endpoint")
        val data = HashMap<String, Any?>();
        data["endpoint"] = "";
        DartWorkManager.createWorker(context, "unifiedpush-settings", data) {}
    }

    override fun onMessage(context: Context, payload: ByteArray, instance: String) {
        val applicationContext = context.getApplicationContext()
        val msg = payload.toString(Charsets.UTF_8)
        val (type, payloadMap) = parsePayload(msg) ?: run {
            PersistentLog.d(applicationContext, tag, "Invalid or malformed UnifiedPush message payload")
            return
        }

        PersistentLog.i(applicationContext, tag, "Received new message of type $type from UnifiedPush...")
        DartWorkManager.createWorker(applicationContext, type, payloadMap) {}

        // check if the user configured "Send Events to Tasker"
        val prefs = applicationContext.getSharedPreferences("FlutterSharedPreferences", 0)
        if (prefs.getBoolean("sendEventsToTasker", false)) {
            Utils.getServerUrl(applicationContext, object : MethodChannel.Result {
                override fun success(result: Any?) {
                    PersistentLog.w(applicationContext, tag, "Got URL: $result - sending to Tasker...")
                    val intent = Intent()
                    intent.setPackage("net.dinglisch.android.taskerm")
                    intent.setAction(TASKER_EVENT_ACTION)
                    intent.putExtra("url", result.toString())
                    intent.putExtra("event", type)
                    intent.putExtras(bundleOf(*toTaskerExtras(payloadMap)))
                    applicationContext.sendBroadcast(intent)
                }

                override fun error(errorCode: String, errorMesage: String?, errorDetails: Any?) {}
                override fun notImplemented() {}
            })
        }
    }
}