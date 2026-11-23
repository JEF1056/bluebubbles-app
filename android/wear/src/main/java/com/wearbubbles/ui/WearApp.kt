package com.wearbubbles.ui

import android.util.Base64
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.navigation.NavType
import androidx.navigation.navArgument
import androidx.wear.compose.navigation.SwipeDismissableNavHost
import androidx.wear.compose.navigation.composable
import androidx.wear.compose.navigation.rememberSwipeDismissableNavController
import com.google.android.horologist.annotations.ExperimentalHorologistApi
import com.google.android.horologist.compose.layout.AppScaffold
import com.wearbubbles.WearBubblesApp
import com.wearbubbles.data.SettingsDataStore
import com.wearbubbles.ui.conversations.ConversationListScreen
import com.wearbubbles.ui.messages.MessageDetailScreen
import com.wearbubbles.ui.messages.NewMessageScreen
import com.wearbubbles.ui.settings.SettingsScreen
import com.wearbubbles.ui.setup.SetupScreen
import com.wearbubbles.ui.theme.Surface
import com.wearbubbles.ui.theme.WearBubblesTheme

private fun encodeGuid(guid: String): String =
    Base64.encodeToString(guid.toByteArray(Charsets.UTF_8), Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

private fun decodeGuid(encoded: String): String =
    String(Base64.decode(encoded, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING), Charsets.UTF_8)

@OptIn(ExperimentalHorologistApi::class)
@Composable
fun WearApp(
    initialChatGuid: String? = null,
    initialChatNonce: Long = 0L,
    onInitialChatHandled: () -> Unit = {}
) {
    val context = LocalContext.current
    val settings = remember { SettingsDataStore(context) }
    val app = remember { context.applicationContext as WearBubblesApp }
    var initialStartDestination by remember { mutableStateOf<String?>(null) }
    var configured by remember { mutableStateOf(false) }

    val isConfiguredFlow by settings.isConfigured.collectAsStateWithLifecycle(initialValue = null)
    val isUserDisconnectedFlow by settings.userDisconnected.collectAsStateWithLifecycle(initialValue = null)
    val isPhoneConnected by app.phoneRelayClient.isPhoneConnected.collectAsStateWithLifecycle()

    LaunchedEffect(Unit) {
        val phoneConnected = app.phoneRelayClient.refreshPhoneConnected()
        if (!settings.isUserDisconnected()) {
            app.phoneRelayClient.loadCachedCredentialsFromDataLayer()
            if (phoneConnected) {
                app.phoneRelayClient.requestCredentials()
            }
        }
    }

    LaunchedEffect(isConfiguredFlow, isPhoneConnected, isUserDisconnectedFlow) {
        if (isConfiguredFlow != null && isUserDisconnectedFlow != null) {
            val isReady = (isConfiguredFlow == true) || (isPhoneConnected && isUserDisconnectedFlow == false)
            configured = isReady
            if (initialStartDestination == null) {
                initialStartDestination = if (isReady) "conversations" else "setup"
            }
        }
    }

    val startDestination = initialStartDestination
    if (startDestination == null) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Surface)
        )
        return
    }

    WearBubblesTheme {
        val navController = rememberSwipeDismissableNavController()

        LaunchedEffect(initialChatGuid, initialChatNonce, configured) {
            if (configured && !initialChatGuid.isNullOrBlank()) {
                val encoded = encodeGuid(initialChatGuid)
                onInitialChatHandled()
                val hasConversations = runCatching {
                    navController.getBackStackEntry("conversations")
                }.isSuccess
                if (!hasConversations) {
                    navController.navigate("conversations") {
                        popUpTo("setup") { inclusive = true }
                        launchSingleTop = true
                    }
                }
                navController.navigate("messages/$encoded") {
                    popUpTo("conversations") { inclusive = false }
                    launchSingleTop = true
                }
            }
        }

        AppScaffold(
            modifier = Modifier
                .fillMaxSize()
                .background(Surface)
        ) {
            SwipeDismissableNavHost(
                navController = navController,
                startDestination = startDestination,
                modifier = Modifier
                    .fillMaxSize()
                    .background(Surface)
            ) {
                composable("setup") {
                    SetupScreen(
                        onConnected = {
                            navController.navigate("conversations") {
                                popUpTo("setup") { inclusive = true }
                            }
                        }
                    )
                }

                composable("conversations") {
                    ConversationListScreen(
                        onChatClick = { chatGuid ->
                            val encoded = encodeGuid(chatGuid)
                            navController.navigate("messages/$encoded")
                        },
                        onSettingsClick = {
                            navController.navigate("settings")
                        },
                        onNewMessageClick = {
                            navController.navigate("new_message")
                        }
                    )
                }

                composable("new_message") {
                    NewMessageScreen(
                        onStartChat = { chatGuid ->
                            val encoded = encodeGuid(chatGuid)
                            navController.navigate("messages/$encoded") {
                                popUpTo("new_message") { inclusive = true }
                            }
                        }
                    )
                }

                composable("settings") {
                    SettingsScreen(
                        onResetComplete = {
                            navController.navigate("setup") {
                                popUpTo(0) { inclusive = true }
                            }
                        }
                    )
                }

                composable(
                    route = "messages/{chatGuid}",
                    arguments = listOf(navArgument("chatGuid") { type = NavType.StringType })
                ) { backStackEntry ->
                    val encoded = backStackEntry.arguments?.getString("chatGuid") ?: return@composable
                    val chatGuid = decodeGuid(encoded)
                    MessageDetailScreen(
                        chatGuid = chatGuid,
                        onChatDeleted = { navController.popBackStack() }
                    )
                }
            }
        }
    }
}
