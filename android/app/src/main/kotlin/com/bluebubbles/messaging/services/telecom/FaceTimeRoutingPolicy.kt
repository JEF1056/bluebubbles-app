package com.bluebubbles.messaging.services.telecom

enum class IncomingFaceTimeRoute {
    TELECOM_DIRECT,
    NOTIFICATION
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
        phoneAccountEnabled: Boolean
    ): IncomingFaceTimeRoute {
        return if (!isVideo && !callUuid.isNullOrBlank() && phoneAccountEnabled) {
            IncomingFaceTimeRoute.TELECOM_DIRECT
        } else {
            IncomingFaceTimeRoute.NOTIFICATION
        }
    }

    fun resolveHandleScheme(address: String): String {
        return if (address.contains("@")) "mailto" else "tel"
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
