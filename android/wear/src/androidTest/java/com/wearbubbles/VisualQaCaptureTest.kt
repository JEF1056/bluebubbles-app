package com.wearbubbles

import android.content.Context
import android.graphics.Bitmap
import android.os.SystemClock
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.VisibilityOff
import androidx.compose.material.icons.rounded.LinkOff
import androidx.compose.runtime.Composable
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeUp
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.wearbubbles.api.dto.TapbackType
import com.wearbubbles.notifications.CallNotificationHelper
import com.wearbubbles.notifications.CallPhase
import com.wearbubbles.notifications.NotificationHelper
import com.wearbubbles.ui.call.IncomingCallActivity
import com.wearbubbles.ui.components.WearConfirmModal
import com.wearbubbles.ui.messages.EmojiPickerOverlay
import com.wearbubbles.ui.messages.PeopleModal
import com.wearbubbles.ui.messages.TapbackPickerOverlay
import com.wearbubbles.ui.theme.ContactAvatar
import com.wearbubbles.ui.theme.WearBubblesTheme
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.io.FileOutputStream

@RunWith(AndroidJUnit4::class)
class VisualQaCaptureTest {

    @get:Rule
    val composeRule = createEmptyComposeRule()

    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val appContext: Context
        get() = instrumentation.targetContext

    private val screenshotDir: File by lazy {
        File(appContext.getExternalFilesDir(null), "qa_screenshots").apply { mkdirs() }
    }

    @After
    fun cleanup() {
        CallNotificationHelper.endCall(appContext)
        NotificationHelper.cancelNotification(appContext, "qa-chat-alex")
        NotificationHelper.cancelNotification(appContext, "qa-chat-group")
    }

    private fun saveScreen(name: String) {
        SystemClock.sleep(450)
        val bitmap = instrumentation.uiAutomation.takeScreenshot()
            ?: error("takeScreenshot() returned null for $name")
        val out = File(screenshotDir, "$name.png")
        FileOutputStream(out).use { stream ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
        }
        bitmap.recycle()
    }

    private fun dumpNotifs(name: String) {
        val nm = appContext.getSystemService(android.app.NotificationManager::class.java)
        val sb = StringBuilder()
        sb.appendLine("=== activeNotifications (${nm?.activeNotifications?.size}) ===")
        nm?.activeNotifications?.forEach { sbn ->
            val n = sbn.notification
            sb.appendLine("id=${sbn.id} tag=${sbn.tag} group=${n.group} flags=0x${Integer.toHexString(n.flags)} cat=${n.category} title=${n.extras.getCharSequence(android.app.Notification.EXTRA_TITLE)} text=${n.extras.getCharSequence(android.app.Notification.EXTRA_TEXT)}")
        }
        File(screenshotDir, "$name.txt").writeText(sb.toString())
    }

    private fun runShell(cmd: String) {
        val pfd = instrumentation.uiAutomation.executeShellCommand(cmd)
        pfd.close()
    }

    private fun captureComposeModal(name: String, content: @Composable () -> Unit) {
        ActivityScenario.launch(ComponentActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.setContent {
                    WearBubblesTheme {
                        content()
                    }
                }
            }
            composeRule.waitForIdle()
            SystemClock.sleep(350)
            saveScreen(name)
        }
    }

    @Test
    fun captureIncomingCallBothStates() {
        NotificationHelper.createChannels(appContext)
        CallNotificationHelper.showIncomingCall(
            context = appContext,
            callUuid = "qa-call-1",
            callerName = "Alex Rivera",
            callerAddress = "+15552345678",
            isVideo = true,
            fromPhoneRelay = false
        )

        ActivityScenario.launch(IncomingCallActivity::class.java).use {
            composeRule.waitForIdle()
            composeRule.onNodeWithText("Alex Rivera").assertExists()
            saveScreen("01_incoming_call_ringing")

            composeRule.onNodeWithContentDescription("Answer Audio").performClick()
            val deadline = SystemClock.elapsedRealtime() + 5000L
            while (CallNotificationHelper.activeCallState.value?.phase != CallPhase.ONGOING &&
                SystemClock.elapsedRealtime() < deadline
            ) {
                SystemClock.sleep(100)
            }
            SystemClock.sleep(1400)
            composeRule.waitForIdle()
            saveScreen("02_incoming_call_ongoing")
        }
    }

    @Test
    fun captureHideChatModal() {
        captureComposeModal("03_modal_hide_chat") {
            WearConfirmModal(
                show = true,
                onDismiss = {},
                title = "Hide chat?",
                message = "Removes \"Alex Rivera\" from your watch.",
                confirmLabel = "Hide chat",
                onConfirm = {},
                dismissLabel = "Keep chat",
                icon = Icons.Outlined.VisibilityOff,
                destructive = true,
                headerBadge = {
                    ContactAvatar(
                        title = "Alex Rivera",
                        seed = "iMessage;-;+15552345678",
                        avatarPath = null,
                        isGroup = false,
                        size = 40.dp
                    )
                }
            )
        }
    }

    @Test
    fun captureTapbackPickerOverlay() {
        captureComposeModal("04_modal_tapback_picker") {
            TapbackPickerOverlay(
                showDialog = true,
                targetSnippet = "Are we still on for dinner tonight?",
                activeByMeTypes = setOf(TapbackType.LOVE),
                onSelect = {},
                onDismiss = {}
            )
        }
    }

    @Test
    fun captureEmojiPickerOverlay() {
        ActivityScenario.launch(ComponentActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.setContent {
                    WearBubblesTheme {
                        EmojiPickerOverlay(
                            showDialog = true,
                            onSelectEmoji = {},
                            onOpenKeyboard = {},
                            onDismiss = {}
                        )
                    }
                }
            }
            composeRule.waitForIdle()
            SystemClock.sleep(350)
            saveScreen("05_modal_emoji_picker_top")

            // Scroll to bottom to verify Open keyboard / Close picker pills
            composeRule.onNodeWithContentDescription("Send 👍").performTouchInput {
                swipeUp(startY = centerY, endY = centerY - 260f)
            }
            composeRule.waitForIdle()
            SystemClock.sleep(350)
            composeRule.onNodeWithContentDescription("Send 💯").performTouchInput {
                swipeUp(startY = centerY, endY = centerY - 260f)
            }
            composeRule.waitForIdle()
            SystemClock.sleep(350)
            saveScreen("05b_modal_emoji_picker_bottom")
        }
    }

    @Test
    fun capturePeopleModal() {
        ActivityScenario.launch(ComponentActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.setContent {
                    WearBubblesTheme {
                        PeopleModal(
                            showDialog = true,
                            participants = listOf(
                                "Alex Rivera" to "(555) 234-5678",
                                "Maya Lin" to "maya.lin@icloud.com",
                                "Samira Patel" to "(555) 890-1234",
                                "(555) 999-0000" to "(555) 999-0000"
                            ),
                            onDismiss = {}
                        )
                    }
                }
            }
            composeRule.waitForIdle()
            SystemClock.sleep(350)
            saveScreen("06_modal_people_top")

            composeRule.onNodeWithText("Maya Lin").performTouchInput {
                swipeUp(startY = centerY, endY = centerY - 260f)
            }
            composeRule.waitForIdle()
            SystemClock.sleep(350)
            saveScreen("06b_modal_people_bottom")
        }
    }

    @Test
    fun captureTrashChatModal() {
        captureComposeModal("07_modal_trash_chat") {
            WearConfirmModal(
                show = true,
                onDismiss = {},
                title = "Move to trash?",
                message = "Removes \"Alex Rivera\" from this watch.",
                confirmLabel = "Trash chat",
                onConfirm = {},
                dismissLabel = "Keep chat",
                icon = Icons.Outlined.Delete,
                destructive = true
            )
        }
    }

    @Test
    fun captureResetWatchModal() {
        captureComposeModal("08_modal_reset_watch") {
            WearConfirmModal(
                show = true,
                onDismiss = {},
                title = "Reset watch?",
                message = "Clears saved server credentials and local messages.",
                confirmLabel = "Reset watch",
                onConfirm = {},
                dismissLabel = "Keep setup",
                icon = Icons.Rounded.LinkOff,
                destructive = true
            )
        }
    }

    @Test
    fun captureNotificationsAndOngoingChip() {
        NotificationHelper.createChannels(appContext)
        NotificationHelper.setActiveChat(null, appContext)

        // Post MessagingStyle 1:1 rich message notification
        val now = System.currentTimeMillis()
        NotificationHelper.showMessageNotification(
            context = appContext,
            chatGuid = "qa-chat-alex",
            senderName = "Alex Rivera",
            messageText = "Hey! Still on for coffee at 3pm? Also bringing the prototypes.",
            isGroup = false,
            hapticEnabled = false,
            timestamp = now - 60_000L,
            senderAddress = "+15552345678"
        )
        NotificationHelper.showMessageNotification(
            context = appContext,
            chatGuid = "qa-chat-group",
            senderName = "Maya Lin",
            messageText = "Booked the cabin for Friday night!",
            isGroup = true,
            groupTitle = "Weekend Trip",
            hapticEnabled = false,
            timestamp = now,
            senderAddress = "maya.lin@icloud.com"
        )

        // Post incoming CallStyle notification
        CallNotificationHelper.showIncomingCall(
            context = appContext,
            callUuid = "qa-call-notif-1",
            callerName = "Alex Rivera",
            callerAddress = "+15552345678",
            isVideo = true,
            fromPhoneRelay = false
        )

        runShell("am start -a android.intent.action.MAIN -c android.intent.category.HOME")
        SystemClock.sleep(800)
        dumpNotifs("notif_dump_09")
        // Wear OS notification tray lives below the watchface (swipe up from bottom edge)
        runShell("input swipe 227 420 227 80 350")
        SystemClock.sleep(1400)
        saveScreen("09_notif_shade_incoming_call_and_messages")

        // Close notification tray back to watchface, then transition to Ongoing CallStyle + OngoingActivity
        runShell("input keyevent KEYCODE_BACK")
        SystemClock.sleep(600)
        runBlocking {
            CallNotificationHelper.answerCallAudio(appContext, "qa-call-notif-1")
        }
        SystemClock.sleep(1600)
        dumpNotifs("notif_dump_11")

        // Capture Watch Home with OngoingActivity chip
        runShell("input keyevent KEYCODE_BACK")
        SystemClock.sleep(1200)
        saveScreen("10_ongoing_activity_chip_home")

        // Swipe up into Wear OS notification tray to see Ongoing CallStyle
        runShell("input swipe 227 420 227 80 350")
        SystemClock.sleep(1400)
        saveScreen("11_notif_shade_ongoing_call_and_messages")

        // Scroll tray to inspect MessagingStyle cards
        runShell("input swipe 227 320 227 130 350")
        SystemClock.sleep(1000)
        saveScreen("12_notif_shade_messaging_style")

        CallNotificationHelper.endCall(appContext, "qa-call-notif-1")
        runShell("input keyevent KEYCODE_BACK")
    }
}
