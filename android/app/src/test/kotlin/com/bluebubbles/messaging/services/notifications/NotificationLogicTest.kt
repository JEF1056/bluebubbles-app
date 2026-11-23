package com.bluebubbles.messaging.services.notifications

import android.app.Notification
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.services.intents.InternalIntentReceiver
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationLogicTest {
    @Test
    fun `shouldRecreateNewMessagesChannel triggers once for DND or vibration migration`() {
        assertFalse(
            NotificationChannelHandler.shouldRecreateNewMessagesChannel(
                exists = false,
                shouldVibrate = false,
                vibrationMigrated = false,
                canBypassDnd = true,
                dndMigrated = false
            )
        )
        assertTrue(
            NotificationChannelHandler.shouldRecreateNewMessagesChannel(
                exists = true,
                shouldVibrate = true,
                vibrationMigrated = true,
                canBypassDnd = true,
                dndMigrated = false
            )
        )
        assertFalse(
            NotificationChannelHandler.shouldRecreateNewMessagesChannel(
                exists = true,
                shouldVibrate = true,
                vibrationMigrated = true,
                canBypassDnd = true,
                dndMigrated = true
            )
        )
        assertTrue(
            NotificationChannelHandler.shouldRecreateNewMessagesChannel(
                exists = true,
                shouldVibrate = false,
                vibrationMigrated = false,
                canBypassDnd = false,
                dndMigrated = true
            )
        )
    }

    @Test
    fun `resolveTargetChannelId routes to conversation channel only when conversationId matches chatGuid`() {
        val base = "com.bluebubbles.new_messages"
        val chatGuid = "iMessage;-;+15551234567"

        assertEquals(
            chatGuid,
            CreateIncomingMessageNotification.resolveTargetChannelId(base, chatGuid, chatGuid, chatGuid)
        )
        assertEquals(
            base,
            CreateIncomingMessageNotification.resolveTargetChannelId(base, base, null, chatGuid)
        )
        assertEquals(
            base,
            CreateIncomingMessageNotification.resolveTargetChannelId(base, null, null, chatGuid)
        )
    }

    @Test
    fun `buildSummaryLines caps at maxLines and drops blank lines`() {
        val lines = CreateIncomingMessageNotification.buildSummaryLines(
            existingLines = listOf("A: 1", " ", "B: 2", "C: 3", "D: 4", "E: 5"),
            newLine = "F: 6",
            maxLines = 5
        )
        assertEquals(listOf("B: 2", "C: 3", "D: 4", "E: 5", "F: 6"), lines)
    }

    @Test
    fun `pending intent offsets for like and mute do not collide with adjacent chat IDs or existing offsets`() {
        val likeOffset = CreateIncomingMessageNotification.PENDING_INTENT_LIKE_OFFSET
        val muteOffset = CreateIncomingMessageNotification.PENDING_INTENT_MUTE_OFFSET
        assertEquals(400000, likeOffset)
        assertEquals(500000, muteOffset)
        assertNotEquals(1, likeOffset)
        assertNotEquals(likeOffset, muteOffset)
        val existingOffsets = setOf(
            Constants.pendingIntentOpenChatOffset,
            Constants.pendingIntentMarkReadOffset,
            Constants.pendingIntentOpenBubbleOffset,
            Constants.pendingIntentDeleteNotificationOffset
        )
        assertFalse(likeOffset in existingOffsets)
        assertFalse(muteOffset in existingOffsets)
    }

    @Test
    fun `reactionButtonTitle toggles like and love labels`() {
        assertEquals("Like", InternalIntentReceiver.reactionButtonTitle("like", false))
        assertEquals("Un-Like", InternalIntentReceiver.reactionButtonTitle("like", true))
        assertEquals("Love", InternalIntentReceiver.reactionButtonTitle("love", false))
        assertEquals("Un-Love", InternalIntentReceiver.reactionButtonTitle("love", true))
    }

    @Test
    fun `replaceReactionAction preserves Mark As Read, Reply, and Mute actions`() {
        val actions = listOf("Mark As Read", "Reply", "Like", "Mute")
        val updated = InternalIntentReceiver.replaceReactionAction(actions, "Un-Like") { title ->
            InternalIntentReceiver.isReactionAction(title, null)
        }
        assertEquals(listOf("Mark As Read", "Reply", "Un-Like", "Mute"), updated)
        assertTrue(InternalIntentReceiver.isReactionAction("Custom", Notification.Action.SEMANTIC_ACTION_THUMBS_UP))
        assertFalse(InternalIntentReceiver.isReactionAction("Mute", Notification.Action.SEMANTIC_ACTION_MUTE))
    }

    @Test
    fun `shouldOnlyAlertOnce suppresses sound on reaction, edit, fromMe, or explicit flag`() {
        assertFalse(
            CreateIncomingMessageNotification.shouldOnlyAlertOnce(
                messageIsFromMe = false,
                isReaction = false,
                isEdit = false,
                explicitOnlyAlertOnce = false
            )
        )
        assertTrue(
            CreateIncomingMessageNotification.shouldOnlyAlertOnce(
                messageIsFromMe = false,
                isReaction = true,
                isEdit = false,
                explicitOnlyAlertOnce = false
            )
        )
        assertTrue(
            CreateIncomingMessageNotification.shouldOnlyAlertOnce(
                messageIsFromMe = false,
                isReaction = false,
                isEdit = true,
                explicitOnlyAlertOnce = false
            )
        )
        assertTrue(
            CreateIncomingMessageNotification.shouldOnlyAlertOnce(
                messageIsFromMe = true,
                isReaction = false,
                isEdit = false,
                explicitOnlyAlertOnce = false
            )
        )
        assertTrue(
            CreateIncomingMessageNotification.shouldOnlyAlertOnce(
                messageIsFromMe = false,
                isReaction = false,
                isEdit = false,
                explicitOnlyAlertOnce = true
            )
        )
    }

    @Test
    fun `shouldCancelSummary returns true only when summary remains with no child notifications`() {
        val tag = Constants.newMessageNotificationTag
        assertTrue(
            com.bluebubbles.messaging.services.wear.WearSyncManager.shouldCancelSummary(
                listOf(tag to 0),
                tag
            )
        )
        assertFalse(
            com.bluebubbles.messaging.services.wear.WearSyncManager.shouldCancelSummary(
                listOf(tag to 0, tag to 42),
                tag
            )
        )
        assertFalse(
            com.bluebubbles.messaging.services.wear.WearSyncManager.shouldCancelSummary(
                emptyList(),
                tag
            )
        )
    }

    @Test
    fun `resolveDismissedChatGuid falls back to intent extra when notification is already removed`() {
        assertEquals(
            "iMessage;-;+15551234567",
            DeleteNotificationHandler.resolveDismissedChatGuid("iMessage;-;+15551234567", "other")
        )
        assertEquals(
            "iMessage;-;+15551234567",
            DeleteNotificationHandler.resolveDismissedChatGuid(null, "iMessage;-;+15551234567")
        )
        assertEquals(
            "iMessage;-;+15551234567",
            DeleteNotificationHandler.resolveDismissedChatGuid("", "iMessage;-;+15551234567")
        )
        assertEquals(null, DeleteNotificationHandler.resolveDismissedChatGuid(null, ""))
    }

    @Test
    fun `shortcut fingerprint deduplicates unchanged pushes and invalidates on metadata change`() {
        val fp1 = com.bluebubbles.messaging.services.system.PushShareTargetsHandler.computeShortcutFingerprint(
            name = "Audrey",
            resolvedUri = "content://com.android.contacts/contacts/lookup/abc/1",
            iconHash = 12345,
            participantCount = 0
        )
        val fpSame = com.bluebubbles.messaging.services.system.PushShareTargetsHandler.computeShortcutFingerprint(
            name = "Audrey",
            resolvedUri = "content://com.android.contacts/contacts/lookup/abc/1",
            iconHash = 12345,
            participantCount = 0
        )
        val fpRenamed = com.bluebubbles.messaging.services.system.PushShareTargetsHandler.computeShortcutFingerprint(
            name = "Audrey Sioeng",
            resolvedUri = "content://com.android.contacts/contacts/lookup/abc/1",
            iconHash = 12345,
            participantCount = 0
        )
        assertEquals(fp1, fpSame)
        assertNotEquals(fp1, fpRenamed)
        val map = mapOf("any;-;+16266165776" to fp1)
        assertTrue(
            com.bluebubbles.messaging.services.system.PushShareTargetsHandler.shouldSkipShortcutPush(
                "any;-;+16266165776",
                fpSame,
                map
            )
        )
        assertFalse(
            com.bluebubbles.messaging.services.system.PushShareTargetsHandler.shouldSkipShortcutPush(
                "any;-;+16266165776",
                fpRenamed,
                map
            )
        )
        assertFalse(
            com.bluebubbles.messaging.services.system.PushShareTargetsHandler.shouldSkipShortcutPush(
                "any;-;+19999999999",
                fp1,
                map
            )
        )
    }

    @Test
    fun `sortKeyForTimestamp orders newer timestamps earlier lexicographically`() {
        val older = CreateIncomingMessageNotification.sortKeyForTimestamp(1_700_000_000_000L)
        val newer = CreateIncomingMessageNotification.sortKeyForTimestamp(1_700_000_010_000L)
        assertTrue(newer < older)
    }

    @Test
    fun `shouldShowPhoneMuteAction moves Mute off phone when reactions enabled`() {
        assertFalse(CreateIncomingMessageNotification.shouldShowPhoneMuteAction(showReactionAction = true))
        assertTrue(CreateIncomingMessageNotification.shouldShowPhoneMuteAction(showReactionAction = false))
    }

    @Test
    fun `channel group routing maps messages, calls, and other channels cleanly`() {
        assertEquals(
            "com.bluebubbles.incoming_facetimes_v2",
            NotificationChannelHandler.FACETIME_CHANNEL_ID
        )
        assertEquals(
            "com.bluebubbles.incoming_facetimes",
            NotificationChannelHandler.LEGACY_FACETIME_CHANNEL_ID
        )
        assertEquals(
            NotificationChannelHandler.GROUP_MESSAGES,
            NotificationChannelHandler.groupIdForChannel(NotificationChannelHandler.NEW_MESSAGES_CHANNEL_ID)
        )
        assertEquals(
            NotificationChannelHandler.GROUP_CALLS,
            NotificationChannelHandler.groupIdForChannel(NotificationChannelHandler.FACETIME_CHANNEL_ID)
        )
        assertEquals(
            NotificationChannelHandler.GROUP_CALLS,
            NotificationChannelHandler.groupIdForChannel(NotificationChannelHandler.FACETIME_RING_CHANNEL_ID)
        )
        assertEquals(
            NotificationChannelHandler.GROUP_CALLS,
            NotificationChannelHandler.groupIdForChannel(NotificationChannelHandler.LEGACY_FACETIME_CHANNEL_ID)
        )
        assertEquals(
            NotificationChannelHandler.GROUP_OTHER,
            NotificationChannelHandler.groupIdForChannel(NotificationChannelHandler.FOREGROUND_SERVICE_CHANNEL_ID)
        )
        assertEquals(
            "set-call-tone",
            com.bluebubbles.messaging.services.telecom.SetCallToneHandler.tag
        )
    }

    @Test
    fun `computeInboxSummary keeps count and caps visible lines at 5`() {
        val (count, lines) = DeleteNotificationHandler.computeInboxSummary(
            listOf("A: 1", "B: 2", " ", "C: 3", "D: 4", "E: 5", "F: 6")
        )
        assertEquals(7, count)
        assertEquals(listOf("B: 2", "C: 3", "D: 4", "E: 5", "F: 6"), lines)
    }

    @Test
    fun `formatCallerUri adds tel or mailto scheme when missing`() {
        assertEquals("tel:+15551234567", CreateIncomingFaceTimeNotification.formatCallerUri("+15551234567"))
        assertEquals("mailto:alice@example.com", CreateIncomingFaceTimeNotification.formatCallerUri("alice@example.com"))
        assertEquals("tel:+15551234567", CreateIncomingFaceTimeNotification.formatCallerUri("tel:+15551234567"))
        assertEquals(null, CreateIncomingFaceTimeNotification.formatCallerUri("  "))
    }

    @Test
    fun `extensionForMime maps common image types and falls back to jpg`() {
        assertEquals("png", InternalIntentReceiver.extensionForMime("image/png"))
        assertEquals("gif", InternalIntentReceiver.extensionForMime("image/gif"))
        assertEquals("webp", InternalIntentReceiver.extensionForMime("image/webp"))
        assertEquals("jpg", InternalIntentReceiver.extensionForMime("image/jpeg"))
    }

    @Test
    fun `matchesNotification respects targetTag when provided`() {
        assertTrue(DeleteNotificationHandler.matchesNotification("NEW_MESSAGE", 42, 42, "NEW_MESSAGE"))
        assertFalse(DeleteNotificationHandler.matchesNotification("NEW_FACETIME", 42, 42, "NEW_MESSAGE"))
        assertTrue(DeleteNotificationHandler.matchesNotification("NEW_FACETIME", 42, 42, null))
        assertFalse(DeleteNotificationHandler.matchesNotification("NEW_MESSAGE", 41, 42, "NEW_MESSAGE"))
    }

    @Test
    fun `shouldUseCallStyle gates on canUseFsi and disables for ongoing or enable-account`() {
        assertTrue(
            CreateIncomingFaceTimeNotification.shouldUseCallStyle(
                sdkInt = android.os.Build.VERSION_CODES.UPSIDE_DOWN_CAKE,
                isOngoing = false,
                route = com.bluebubbles.messaging.services.telecom.IncomingFaceTimeRoute.NOTIFICATION,
                canUseFsi = true
            )
        )
        assertFalse(
            CreateIncomingFaceTimeNotification.shouldUseCallStyle(
                sdkInt = android.os.Build.VERSION_CODES.UPSIDE_DOWN_CAKE,
                isOngoing = false,
                route = com.bluebubbles.messaging.services.telecom.IncomingFaceTimeRoute.NOTIFICATION,
                canUseFsi = false
            )
        )
        assertFalse(
            CreateIncomingFaceTimeNotification.shouldUseCallStyle(
                sdkInt = android.os.Build.VERSION_CODES.UPSIDE_DOWN_CAKE,
                isOngoing = true,
                route = com.bluebubbles.messaging.services.telecom.IncomingFaceTimeRoute.NOTIFICATION,
                canUseFsi = true
            )
        )
        assertFalse(
            CreateIncomingFaceTimeNotification.shouldUseCallStyle(
                sdkInt = android.os.Build.VERSION_CODES.UPSIDE_DOWN_CAKE,
                isOngoing = false,
                route = com.bluebubbles.messaging.services.telecom.IncomingFaceTimeRoute.NOTIFICATION_ENABLE_ACCOUNT,
                canUseFsi = true
            )
        )
        assertFalse(
            CreateIncomingFaceTimeNotification.shouldUseCallStyle(
                sdkInt = android.os.Build.VERSION_CODES.R,
                isOngoing = false,
                route = com.bluebubbles.messaging.services.telecom.IncomingFaceTimeRoute.NOTIFICATION,
                canUseFsi = true
            )
        )
    }

    @Test
    fun `resolveIsVideo and computeFaceTimeNotificationId match Dart logic`() {
        assertFalse(CreateIncomingFaceTimeNotification.resolveIsVideo(isVideoFlag = true, isAudioFlag = null, isTelephony = true))
        assertFalse(CreateIncomingFaceTimeNotification.resolveIsVideo(isVideoFlag = null, isAudioFlag = true, isTelephony = false))
        assertTrue(CreateIncomingFaceTimeNotification.resolveIsVideo(isVideoFlag = null, isAudioFlag = null, isTelephony = false))
        assertEquals(12345678, CreateIncomingFaceTimeNotification.computeFaceTimeNotificationId("1234-5678-90ab"))
    }

    @Test
    fun `resolveIncomingDartDedupeAction updates notification silently when deduped without active Telecom or pending end`() {
        assertEquals(
            CreateIncomingFaceTimeNotification.IncomingDartDedupeAction.UPDATE_NOTIFICATION_SILENTLY,
            CreateIncomingFaceTimeNotification.resolveIncomingDartDedupeAction(
                isOngoing = false,
                callUuid = "uuid-1",
                isPendingEnded = false,
                hasActiveConnection = false,
                isNewlySeen = false
            )
        )
        assertEquals(
            CreateIncomingFaceTimeNotification.IncomingDartDedupeAction.DROP_TELECOM_ACTIVE,
            CreateIncomingFaceTimeNotification.resolveIncomingDartDedupeAction(
                isOngoing = false,
                callUuid = "uuid-1",
                isPendingEnded = false,
                hasActiveConnection = true,
                isNewlySeen = false
            )
        )
        assertEquals(
            CreateIncomingFaceTimeNotification.IncomingDartDedupeAction.DROP_ENDED,
            CreateIncomingFaceTimeNotification.resolveIncomingDartDedupeAction(
                isOngoing = false,
                callUuid = "uuid-1",
                isPendingEnded = true,
                hasActiveConnection = false,
                isNewlySeen = false
            )
        )
    }

    @Test
    fun `ongoingActionLabels reflects muted and speaker states`() {
        assertEquals(
            "Mute" to "Speaker on",
            com.bluebubbles.messaging.services.telecom.FaceTimeCallForegroundService.ongoingActionLabels(
                muted = false,
                speaker = false
            )
        )
        assertEquals(
            "Unmute" to "Speaker off",
            com.bluebubbles.messaging.services.telecom.FaceTimeCallForegroundService.ongoingActionLabels(
                muted = true,
                speaker = true
            )
        )
    }

    @Test
    fun `promotion extras key matches Android Live Updates requestPromotedOngoing`() {
        assertEquals(
            "android.requestPromotedOngoing",
            com.bluebubbles.messaging.services.telecom.FaceTimeCallForegroundService.EXTRA_REQUEST_PROMOTED_ONGOING
        )
    }

    @Test
    fun `WearSyncManager clearCallEnded allows re-notifying call ended after active call`() {
        val uuid = "test-live-call-uuid-dedupe"
        val now = 1_700_000_000_000L
        com.bluebubbles.messaging.services.wear.WearSyncManager.clearCallEnded(uuid)
        assertTrue(com.bluebubbles.messaging.services.wear.WearSyncManager.recordCallEndedIfNew(uuid, now))
        assertFalse(com.bluebubbles.messaging.services.wear.WearSyncManager.recordCallEndedIfNew(uuid, now + 100L))
        com.bluebubbles.messaging.services.wear.WearSyncManager.clearCallEnded(uuid)
        assertTrue(com.bluebubbles.messaging.services.wear.WearSyncManager.recordCallEndedIfNew(uuid, now + 200L))
        com.bluebubbles.messaging.services.wear.WearSyncManager.clearCallEnded(uuid)
    }

    @Test
    fun `resolveIncomingRingOwnership uses app ring only with Telecom binding and system ring otherwise`() {
        assertEquals(
            CreateIncomingFaceTimeNotification.IncomingRingOwnership.NONE,
            CreateIncomingFaceTimeNotification.resolveIncomingRingOwnership(
                isOngoing = true,
                hasTelecomConnection = false,
                hasOtherActiveCall = false
            )
        )
        assertEquals(
            CreateIncomingFaceTimeNotification.IncomingRingOwnership.APP_TELECOM,
            CreateIncomingFaceTimeNotification.resolveIncomingRingOwnership(
                isOngoing = false,
                hasTelecomConnection = true,
                hasOtherActiveCall = false
            )
        )
        assertEquals(
            CreateIncomingFaceTimeNotification.IncomingRingOwnership.APP_TELECOM,
            CreateIncomingFaceTimeNotification.resolveIncomingRingOwnership(
                isOngoing = false,
                hasTelecomConnection = false,
                hasOtherActiveCall = true
            )
        )
        assertEquals(
            CreateIncomingFaceTimeNotification.IncomingRingOwnership.SYSTEM_NOTIFICATION,
            CreateIncomingFaceTimeNotification.resolveIncomingRingOwnership(
                isOngoing = false,
                hasTelecomConnection = false,
                hasOtherActiveCall = false
            )
        )
    }

    @Test
    fun `shouldHideBubbleOnRead hides bubble only when keepBubble is true and not in car`() {
        assertTrue(shouldHideBubbleOnRead(keepBubble = true, inCar = false))
        assertFalse(shouldHideBubbleOnRead(keepBubble = true, inCar = true))
        assertFalse(shouldHideBubbleOnRead(keepBubble = false, inCar = false))
        assertFalse(shouldHideBubbleOnRead(keepBubble = false, inCar = true))
    }

    @Test
    fun `incoming FaceTime answerIntent includes notificationId and showsUserInterface flags are true`() {
        val ints = mutableMapOf<String, Int>()
        val bools = mutableMapOf<String, Boolean>()
        val strings = mutableMapOf<String, String>()
        var intentType: String? = null

        CreateIncomingFaceTimeNotification.applyAnswerIntentExtras(
            notificationId = 4242,
            isVideo = true,
            isTelephony = false,
            callerName = "Alice",
            isOngoing = false,
            putInt = { k, v -> ints[k] = v },
            putBoolean = { k, v -> bools[k] = v },
            putString = { k, v -> strings[k] = v },
            setType = { intentType = it }
        )

        assertEquals(4242, ints["notificationId"])
        assertEquals(true, bools["answer"])
        assertEquals(false, bools["audioOnly"])
        assertEquals(false, bools["isTelephony"])
        assertEquals("Alice", strings["caller"])
        assertEquals(true, bools["incomingFaceTime"])
        assertEquals("AnswerFaceTime", intentType)
        assertTrue(CreateIncomingFaceTimeNotification.ANSWER_ACTION_SHOWS_USER_INTERFACE)
        assertTrue(CreateIncomingFaceTimeNotification.AUDIO_ANSWER_ACTION_SHOWS_USER_INTERFACE)
    }

    @Test
    fun `AnswerFaceTimeAudio launch uses OpenCall when routed and AnswerFaceTime when not routed`() {
        val routedBools = mutableMapOf<String, Boolean>()
        val routedStrings = mutableMapOf<String, String>()
        var routedFlags = 0
        var routedType: String? = null

        InternalIntentReceiver.applyAnswerFaceTimeAudioLaunch(
            routed = true,
            callUuid = "ft-audio-uuid",
            isTelephony = false,
            callerName = "Bob",
            addFlags = { routedFlags = routedFlags or it },
            putBoolean = { k, v -> routedBools[k] = v },
            putString = { k, v -> routedStrings[k] = v },
            setType = { routedType = it }
        )

        assertEquals("OpenCall", routedType)
        assertEquals(true, routedBools["openCall"])
        assertEquals(null, routedBools["answer"])
        assertEquals(true, routedBools["audioOnly"])
        assertEquals(false, routedBools["isTelephony"])
        assertEquals(true, routedBools["incomingFaceTime"])
        assertEquals("ft-audio-uuid", routedStrings["callUuid"])
        assertEquals("Bob", routedStrings["caller"])
        assertTrue((routedFlags and android.content.Intent.FLAG_ACTIVITY_NEW_TASK) != 0)
        assertTrue((routedFlags and android.content.Intent.FLAG_ACTIVITY_SINGLE_TOP) != 0)

        val fallbackBools = mutableMapOf<String, Boolean>()
        var fallbackType: String? = null
        InternalIntentReceiver.applyAnswerFaceTimeAudioLaunch(
            routed = false,
            callUuid = "ft-audio-uuid",
            isTelephony = true,
            callerName = "Bob",
            addFlags = {},
            putBoolean = { k, v -> fallbackBools[k] = v },
            putString = { _, _ -> },
            setType = { fallbackType = it }
        )
        assertEquals("AnswerFaceTime", fallbackType)
        assertEquals(true, fallbackBools["answer"])
        assertEquals(null, fallbackBools["openCall"])
        assertEquals(true, fallbackBools["isTelephony"])
    }

    @Test
    fun `facetime ring channel v2 replaces legacy v1 in calls group`() {
        assertEquals(
            "com.bluebubbles.incoming_facetimes_ring_v2",
            NotificationChannelHandler.FACETIME_RING_CHANNEL_ID
        )
        assertEquals(
            "com.bluebubbles.incoming_facetimes_ring_v1",
            NotificationChannelHandler.LEGACY_FACETIME_RING_CHANNEL_ID
        )
        assertEquals(
            NotificationChannelHandler.GROUP_CALLS,
            NotificationChannelHandler.groupIdForChannel(NotificationChannelHandler.LEGACY_FACETIME_RING_CHANNEL_ID)
        )
    }
}
