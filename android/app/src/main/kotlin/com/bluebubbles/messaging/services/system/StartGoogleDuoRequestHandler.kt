package com.bluebubbles.messaging.services.system

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

data class MeetCallIntentSpec(
    val action: String,
    val packageName: String,
    val dataScheme: String,
    val dataSsp: String,
    val isAudioOnlyExtraKey: String,
    val isAudioOnly: Boolean,
    val addNewTaskFlag: Boolean,
)

/// Start a Google Meet / Duo 1:1 video call
class StartGoogleDuoRequestHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag = "google-duo"
        const val marketFallbackUri = "market://details?id=${Constants.googleDuoPackageName}"
        const val webPlayFallbackUri =
            "https://play.google.com/store/apps/details?id=${Constants.googleDuoPackageName}"

        private val dialableCharRegex = Regex("[^0-9*#+]")

        fun normalizeDialNumber(raw: String?): String? {
            if (raw.isNullOrBlank() || raw.contains("@")) return null
            val trimmed = raw.trim()
            val hasLeadingPlus = trimmed.startsWith("+")
            val stripped = trimmed.replace(dialableCharRegex, "").replace("+", "")
            if (stripped.none { it.isDigit() }) return null
            return if (hasLeadingPlus) "+$stripped" else stripped
        }

        fun buildIntentSpec(rawNumber: String?, addNewTaskFlag: Boolean): MeetCallIntentSpec? {
            val normalized = normalizeDialNumber(rawNumber) ?: return null
            return MeetCallIntentSpec(
                action = "${Constants.googleDuoPackageName}.action.CALL",
                packageName = Constants.googleDuoPackageName,
                dataScheme = "tel",
                dataSsp = normalized,
                isAudioOnlyExtraKey = "${Constants.googleDuoPackageName}.extra.IS_AUDIO_ONLY",
                isAudioOnly = false,
                addNewTaskFlag = addNewTaskFlag,
            )
        }

        fun buildCallIntent(spec: MeetCallIntentSpec): Intent {
            return Intent(spec.action).apply {
                setPackage(spec.packageName)
                data = Uri.fromParts(spec.dataScheme, spec.dataSsp, null)
                putExtra(spec.isAudioOnlyExtraKey, spec.isAudioOnly)
                if (spec.addNewTaskFlag) {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            }
        }

        fun dispatchMeetCall(
            rawNumber: String?,
            isActivityContext: Boolean,
            launchMeet: (MeetCallIntentSpec) -> Unit,
            launchPlayStoreFallback: (String, Boolean) -> Unit,
        ): Boolean {
            val addNewTask = !isActivityContext
            val spec = buildIntentSpec(rawNumber, addNewTaskFlag = addNewTask) ?: return false
            return try {
                launchMeet(spec)
                true
            } catch (_: ActivityNotFoundException) {
                try {
                    launchPlayStoreFallback(marketFallbackUri, addNewTask)
                } catch (_: ActivityNotFoundException) {
                    try {
                        launchPlayStoreFallback(webPlayFallbackUri, addNewTask)
                    } catch (_: ActivityNotFoundException) {
                        // Neither Play Store nor a browser is available; still report false cleanly.
                    }
                }
                false
            }
        }
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val launched = dispatchMeetCall(
            rawNumber = call.argument("number"),
            isActivityContext = context is Activity,
            launchMeet = { spec ->
                context.startActivity(buildCallIntent(spec))
            },
            launchPlayStoreFallback = { uri, addNewTask ->
                val fallback = Intent(Intent.ACTION_VIEW, Uri.parse(uri)).apply {
                    if (addNewTask) {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                }
                context.startActivity(fallback)
            },
        )
        result.success(launched)
    }
}
