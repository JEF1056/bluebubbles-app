package com.bluebubbles.messaging.services.telecom

enum class IncomingFaceTimeRoute {
    TELECOM_DIRECT,
    NOTIFICATION,
    NOTIFICATION_ENABLE_ACCOUNT
}

enum class IncomingNotificationAction {
    ANSWER_VIDEO,
    ANSWER_AUDIO,
    ANSWER_LINK,
    ENABLE_CALLING,
    DECLINE
}

data class VideoNotificationActions(
    val hasAnswerVideo: Boolean,
    val hasAudioHandoff: Boolean,
    val hasDecline: Boolean,
    val audioHandoffAutoAnswer: Boolean
)

object FaceTimeRoutingPolicy {
    fun resolveIncomingRoute(
        isVideo: Boolean,
        callUuid: String?,
        phoneAccountEnabled: Boolean,
        isTelephony: Boolean = false
    ): IncomingFaceTimeRoute {
        if (!isVideo && !callUuid.isNullOrBlank()) {
            return when {
                phoneAccountEnabled -> IncomingFaceTimeRoute.TELECOM_DIRECT
                isTelephony -> IncomingFaceTimeRoute.NOTIFICATION_ENABLE_ACCOUNT
                else -> IncomingFaceTimeRoute.NOTIFICATION
            }
        }
        return IncomingFaceTimeRoute.NOTIFICATION
    }

    fun buildIncomingNotificationActions(
        isVideo: Boolean,
        callUuid: String?,
        phoneAccountEnabled: Boolean,
        isTelephony: Boolean = false
    ): List<IncomingNotificationAction> {
        val route = resolveIncomingRoute(isVideo, callUuid, phoneAccountEnabled, isTelephony)
        if (route == IncomingFaceTimeRoute.NOTIFICATION_ENABLE_ACCOUNT) {
            return listOf(IncomingNotificationAction.ENABLE_CALLING, IncomingNotificationAction.DECLINE)
        }
        if (!isVideo) {
            return buildList {
                if (!phoneAccountEnabled) add(IncomingNotificationAction.ENABLE_CALLING)
                add(IncomingNotificationAction.ANSWER_LINK)
                add(IncomingNotificationAction.DECLINE)
            }
        }
        return buildList {
            add(IncomingNotificationAction.ANSWER_VIDEO)
            if (!callUuid.isNullOrBlank()) add(IncomingNotificationAction.ANSWER_AUDIO)
            add(IncomingNotificationAction.DECLINE)
        }
    }

    fun resolveHandleScheme(address: String, isTelephony: Boolean = false): String {
        return if (isTelephony || !address.contains("@")) "tel" else "mailto"
    }

    fun buildVideoNotificationActions(callUuid: String?): VideoNotificationActions {
        val hasUuid = !callUuid.isNullOrBlank()
        return VideoNotificationActions(
            hasAnswerVideo = true,
            hasAudioHandoff = hasUuid,
            hasDecline = true,
            audioHandoffAutoAnswer = hasUuid
        )
    }

    fun shouldTriggerServerDecline(callUuid: String?): Boolean {
        return !callUuid.isNullOrBlank()
    }
}
