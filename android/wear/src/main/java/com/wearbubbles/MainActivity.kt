package com.wearbubbles

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.mutableStateOf
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.wearbubbles.notifications.NotificationHelper
import com.wearbubbles.ui.WearApp
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {

    private val initialChatGuid = mutableStateOf<String?>(null)
    private val initialChatNonce = mutableStateOf(0L)
    private var pausedActiveChatGuid: String? = null
    private var activeHeartbeatJob: Job? = null
    private var bridgingObserverJob: Job? = null

    private val notificationPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { _ -> }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        NotificationHelper.setAppResumed(false)

        val launchGuid = intent.getStringExtra(NotificationHelper.EXTRA_CHAT_GUID)
        if (!launchGuid.isNullOrBlank()) {
            NotificationHelper.setPendingLaunchChatGuid(launchGuid)
            initialChatGuid.value = launchGuid
            initialChatNonce.value += 1L
        }
        requestNotificationPermissionIfNeeded()

        setContent {
            WearApp(
                initialChatGuid = initialChatGuid.value,
                initialChatNonce = initialChatNonce.value,
                onInitialChatHandled = {
                    NotificationHelper.setPendingLaunchChatGuid(null)
                    initialChatGuid.value = null
                }
            )
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val status = ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
        if (status != PackageManager.PERMISSION_GRANTED &&
            !shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)
        ) {
            notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    override fun onResume() {
        super.onResume()
        NotificationHelper.setAppResumed(true)
        val pendingRestore = pausedActiveChatGuid
        pausedActiveChatGuid = null
        if (pendingRestore != null && NotificationHelper.activeChatGuid.value == null) {
            NotificationHelper.setActiveChat(pendingRestore, this)
        } else {
            NotificationHelper.updateBridgingExclusion(this, NotificationHelper.activeChatGuid.value)
        }

        bridgingObserverJob?.cancel()
        bridgingObserverJob = lifecycleScope.launch {
            NotificationHelper.activeChatGuid.collect { guid ->
                NotificationHelper.updateBridgingExclusion(this@MainActivity, guid)
                if (guid != null) {
                    NotificationHelper.cancelNotification(this@MainActivity, guid)
                }
            }
        }

        val relay = (applicationContext as WearBubblesApp).phoneRelayClient
        activeHeartbeatJob?.cancel()
        activeHeartbeatJob = lifecycleScope.launch {
            launch { relay.refreshPhoneConnected() }
            relay.isPhoneConnected.collectLatest { connected ->
                if (connected) {
                    while (isActive) {
                        relay.notifyWatchActive(true)
                        delay(60_000L)
                    }
                }
            }
        }
    }

    override fun onPause() {
        NotificationHelper.setAppResumed(false)
        bridgingObserverJob?.cancel()
        bridgingObserverJob = null
        val currentActive = NotificationHelper.activeChatGuid.value
        if (currentActive != null) {
            pausedActiveChatGuid = currentActive
            NotificationHelper.setActiveChat(null, this)
        } else {
            NotificationHelper.updateBridgingExclusion(this, null)
        }
        activeHeartbeatJob?.cancel()
        activeHeartbeatJob = null
        val relay = (applicationContext as WearBubblesApp).phoneRelayClient
        if (relay.isPhoneConnected.value) {
            relay.notifyWatchActive(false)
        }
        super.onPause()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val guid = intent.getStringExtra(NotificationHelper.EXTRA_CHAT_GUID)
        if (!guid.isNullOrBlank()) {
            // Only keep pausedActiveChatGuid if already paused on that same chat; otherwise let navigation activate it.
            if (pausedActiveChatGuid != guid) {
                pausedActiveChatGuid = null
            }
            NotificationHelper.setPendingLaunchChatGuid(guid)
            initialChatGuid.value = guid
            initialChatNonce.value += 1L
        }
    }
}
