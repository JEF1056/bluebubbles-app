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
import com.wearbubbles.notifications.NotificationHelper
import com.wearbubbles.ui.WearApp

class MainActivity : ComponentActivity() {

    private val initialChatGuid = mutableStateOf<String?>(null)

    private val notificationPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { _ -> }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        initialChatGuid.value = intent.getStringExtra(NotificationHelper.EXTRA_CHAT_GUID)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.POST_NOTIFICATIONS
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
        }

        setContent {
            WearApp(initialChatGuid = initialChatGuid.value)
        }
    }

    override fun onResume() {
        super.onResume()
        (applicationContext as WearBubblesApp).phoneRelayClient.notifyWatchActive(true)
    }

    override fun onPause() {
        (applicationContext as WearBubblesApp).phoneRelayClient.notifyWatchActive(false)
        super.onPause()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val guid = intent.getStringExtra(NotificationHelper.EXTRA_CHAT_GUID)
        if (!guid.isNullOrBlank()) {
            initialChatGuid.value = guid
        }
    }
}
