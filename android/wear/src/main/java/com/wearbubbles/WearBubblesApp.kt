package com.wearbubbles

import android.app.Application
import com.wearbubbles.notifications.NotificationHelper
import com.wearbubbles.relay.PhoneRelayClient
import com.wearbubbles.socket.SocketManager
import com.wearbubbles.worker.MessageSyncWorker

class WearBubblesApp : Application() {
    val socketManager = SocketManager()
    lateinit var phoneRelayClient: PhoneRelayClient
        private set

    override fun onCreate() {
        super.onCreate()
        phoneRelayClient = PhoneRelayClient(this)
        NotificationHelper.createChannels(this)
        MessageSyncWorker.schedule(this)
    }
}
