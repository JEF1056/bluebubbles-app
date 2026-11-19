package com.bluebubbles.messaging.services.notifications

import android.content.Context
import android.provider.Settings
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import com.bluebubbles.messaging.utils.PersistentLog
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class StartNotificationListenerHandler: MethodCallHandlerImpl() {
    companion object {
        const val tag: String = "start-notification-listener"
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val enabledListeners = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners")
        val hasPermission = enabledListeners?.contains(context.packageName) == true
        if (hasPermission) {
            PersistentLog.d(context, Constants.logTag, "Notification listener permission found, starting listener")
            NotificationListener.init(context)
            return result.success(true)
        }
        result.success(false)
    }
}