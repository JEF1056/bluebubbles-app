package com.wearbubbles.ui.call

import android.graphics.BitmapFactory
import android.os.Bundle
import android.os.SystemClock
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Call
import androidx.compose.material.icons.rounded.CallEnd
import androidx.compose.material.icons.rounded.Mic
import androidx.compose.material.icons.rounded.MicOff
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import com.wearbubbles.WearBubblesApp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.material.Icon
import androidx.wear.compose.material.Text
import com.wearbubbles.notifications.ActiveCallState
import com.wearbubbles.notifications.CallNotificationHelper
import com.wearbubbles.notifications.CallPhase
import com.wearbubbles.ui.components.rememberReducedMotion
import com.wearbubbles.ui.theme.BlurFadeContent
import com.wearbubbles.ui.theme.WearBubblesTheme
import com.wearbubbles.ui.theme.centeredTextStyle
import kotlinx.coroutines.delay
import java.io.File
import java.util.Locale

class IncomingCallActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setShowWhenLocked(true)
        setTurnScreenOn(true)

        lifecycleScope.launch {
            CallNotificationHelper.activeCallState.collect { callState ->
                if (callState == null) {
                    finish()
                } else if (callState.phase == CallPhase.RINGING) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
            }
        }

        setContent {
            WearBubblesTheme {
                val callState by CallNotificationHelper.activeCallState.collectAsStateWithLifecycle()
                callState?.let { state ->
                    IncomingCallScreen(state = state)
                }
            }
        }
    }
}

private val DialerCanvasBlack = Color(0xFF000000)
private val DialerElevatedSurface = Color(0xFF282A2C)
private val DialerPrimaryText = Color(0xFFF1F3F4)
private val DialerSecondaryText = Color(0xFFC4C7C5)
private val DialerDeclineRed = Color(0xFFD93025)
private val DialerAnswerGreen = Color(0xFF34A853)

@Composable
private fun IncomingCallScreen(state: ActiveCallState) {
    val context = LocalContext.current
    val app = remember(context) { context.applicationContext as WearBubblesApp }
    val appScope = remember(app) { app.applicationScope }
    val reducedMotion = rememberReducedMotion()
    val isPhoneConnected by app.phoneRelayClient.isPhoneConnected.collectAsStateWithLifecycle()
    var actionInFlight by remember(state.callUuid, state.phase) { mutableStateOf(false) }
    var transferFeedback by remember(state.callUuid) { mutableStateOf<String?>(null) }

    val canTransferToPhone = state.phase == CallPhase.ONGOING && (state.fromPhoneRelay || isPhoneConnected)

    LaunchedEffect(state.callUuid, state.phase) {
        if (state.phase == CallPhase.ONGOING && !state.fromPhoneRelay && !isPhoneConnected) {
            withContext(Dispatchers.IO) {
                app.phoneRelayClient.refreshPhoneConnected()
            }
        }
    }

    LaunchedEffect(transferFeedback) {
        if (transferFeedback != null) {
            delay(2200L)
            transferFeedback = null
        }
    }

    val avatarBitmap by produceState<ImageBitmap?>(initialValue = null, key1 = state.avatarPath) {
        value = state.avatarPath?.let { path ->
            withContext(Dispatchers.IO) {
                val file = File(path)
                if (file.exists()) BitmapFactory.decodeFile(file.absolutePath)?.asImageBitmap() else null
            }
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(DialerCanvasBlack)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        contentAlignment = Alignment.Center
    ) {
        Column(
            modifier = Modifier.fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.SpaceBetween
        ) {
            Spacer(modifier = Modifier.height(2.dp))

            Column(
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Box(
                    modifier = Modifier
                        .size(46.dp)
                        .clip(CircleShape)
                        .background(DialerElevatedSurface),
                    contentAlignment = Alignment.Center
                ) {
                    BlurFadeContent(targetState = avatarBitmap) { bitmap ->
                        if (bitmap != null) {
                            Image(
                                bitmap = bitmap,
                                contentDescription = state.callerName,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier.fillMaxSize()
                            )
                        } else {
                            Text(
                                text = state.callerName.firstOrNull()?.uppercase() ?: "?",
                                color = DialerPrimaryText,
                                style = centeredTextStyle(
                                    fontSize = 19.sp,
                                    lineHeight = 23.sp,
                                    fontWeight = FontWeight.SemiBold
                                )
                            )
                        }
                    }
                }

                Spacer(modifier = Modifier.height(6.dp))

                BlurFadeContent(targetState = state.callerName) { callerName ->
                    Text(
                        text = callerName,
                        color = DialerPrimaryText,
                        style = centeredTextStyle(
                            fontSize = 18.sp,
                            lineHeight = 22.sp,
                            fontWeight = FontWeight.SemiBold
                        ),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        textAlign = TextAlign.Center
                    )
                }

                Spacer(modifier = Modifier.height(2.dp))

                val subtitleState = when {
                    transferFeedback != null -> "feedback:$transferFeedback"
                    state.phase == CallPhase.ONGOING -> "ongoing"
                    else -> ringingCallSubtitle(
                        isVideo = state.isVideo,
                        isTelephony = state.isTelephony,
                        isGroup = state.isGroup
                    )
                }
                BlurFadeContent(targetState = subtitleState) { phaseSubtitle ->
                    when {
                        phaseSubtitle.startsWith("feedback:") -> {
                            val msg = phaseSubtitle.removePrefix("feedback:")
                            Text(
                                text = msg,
                                color = if (msg == "Couldn't reach phone") DialerDeclineRed else DialerPrimaryText,
                                style = centeredTextStyle(
                                    fontSize = 12.sp,
                                    lineHeight = 16.sp,
                                    fontWeight = FontWeight.Medium
                                ),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                textAlign = TextAlign.Center
                            )
                        }
                        phaseSubtitle == "ongoing" -> {
                            CallTimerText(
                                startedAtElapsedMs = state.startedAtElapsedMs,
                                isMuted = state.muted,
                                callKind = CallNotificationHelper.callKindLabel(
                                    isVideo = state.isVideo,
                                    isTelephony = state.isTelephony,
                                    isGroup = state.isGroup
                                )
                            )
                        }
                        else -> {
                            Text(
                                text = phaseSubtitle,
                                color = DialerSecondaryText,
                                style = centeredTextStyle(
                                    fontSize = 12.sp,
                                    lineHeight = 16.sp,
                                    fontWeight = FontWeight.Medium
                                ),
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                textAlign = TextAlign.Center
                            )
                        }
                    }
                }
            }

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = if (canTransferToPhone) 10.dp else 8.dp),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically
            ) {
                if (state.phase == CallPhase.ONGOING && canTransferToPhone) {
                    val isMuted = state.muted
                    Box(
                        modifier = Modifier
                            .offset(y = (-8).dp)
                            .size(48.dp)
                            .clip(CircleShape)
                            .background(if (isMuted) DialerPrimaryText else DialerElevatedSurface)
                            .semantics { contentDescription = if (isMuted) "Unmute" else "Mute" }
                            .clickable(enabled = !actionInFlight, role = Role.Button) {
                                actionInFlight = true
                                appScope.launch {
                                    try {
                                        CallNotificationHelper.toggleMute(context.applicationContext, state.callUuid)
                                    } finally {
                                        withContext(Dispatchers.Main) {
                                            actionInFlight = false
                                        }
                                    }
                                }
                            },
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(
                            imageVector = if (isMuted) Icons.Rounded.MicOff else Icons.Rounded.Mic,
                            contentDescription = null,
                            tint = if (isMuted) DialerCanvasBlack else DialerPrimaryText,
                            modifier = Modifier.size(22.dp)
                        )
                    }

                    Spacer(modifier = Modifier.width(6.dp))
                }

                Box(
                    modifier = Modifier
                        .size(52.dp)
                        .clip(CircleShape)
                        .background(DialerDeclineRed)
                        .semantics { contentDescription = if (state.phase == CallPhase.ONGOING) "End Call" else "Decline" }
                        .clickable(enabled = !actionInFlight, role = Role.Button) {
                            actionInFlight = true
                            appScope.launch {
                                try {
                                    CallNotificationHelper.declineOrEndCall(context.applicationContext, state.callUuid)
                                } finally {
                                    withContext(Dispatchers.Main) {
                                        actionInFlight = false
                                    }
                                }
                            }
                        },
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        imageVector = Icons.Rounded.CallEnd,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.size(24.dp)
                    )
                }

                AnimatedVisibility(
                    visible = state.phase == CallPhase.RINGING,
                    enter = if (reducedMotion) {
                        EnterTransition.None
                    } else {
                        fadeIn(tween(200, easing = FastOutSlowInEasing)) +
                            expandHorizontally(tween(200, easing = FastOutSlowInEasing))
                    },
                    exit = if (reducedMotion) {
                        ExitTransition.None
                    } else {
                        fadeOut(tween(180, easing = FastOutSlowInEasing)) +
                            shrinkHorizontally(tween(200, easing = FastOutSlowInEasing))
                    }
                ) {
                    Box(modifier = Modifier.padding(start = 28.dp)) {
                        Box(
                            modifier = Modifier
                                .size(52.dp)
                                .clip(CircleShape)
                                .background(DialerAnswerGreen)
                                .semantics { contentDescription = "Answer Audio" }
                                .clickable(enabled = !actionInFlight, role = Role.Button) {
                                    actionInFlight = true
                                    appScope.launch {
                                        try {
                                            CallNotificationHelper.answerCallAudio(context.applicationContext, state.callUuid)
                                        } finally {
                                            withContext(Dispatchers.Main) {
                                                actionInFlight = false
                                            }
                                        }
                                    }
                                },
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                imageVector = Icons.Rounded.Call,
                                contentDescription = null,
                                tint = Color.White,
                                modifier = Modifier.size(24.dp)
                            )
                        }
                    }
                }

                AnimatedVisibility(
                    visible = state.phase == CallPhase.ONGOING && !canTransferToPhone,
                    enter = if (reducedMotion) {
                        EnterTransition.None
                    } else {
                        fadeIn(tween(200, easing = FastOutSlowInEasing)) +
                            expandHorizontally(tween(200, easing = FastOutSlowInEasing))
                    },
                    exit = if (reducedMotion) {
                        ExitTransition.None
                    } else {
                        fadeOut(tween(180, easing = FastOutSlowInEasing)) +
                            shrinkHorizontally(tween(200, easing = FastOutSlowInEasing))
                    }
                ) {
                    Box(modifier = Modifier.padding(start = 28.dp)) {
                        val isMuted = state.muted
                        Box(
                            modifier = Modifier
                                .size(52.dp)
                                .clip(CircleShape)
                                .background(if (isMuted) DialerPrimaryText else DialerElevatedSurface)
                                .semantics { contentDescription = if (isMuted) "Unmute" else "Mute" }
                                .clickable(enabled = !actionInFlight, role = Role.Button) {
                                    actionInFlight = true
                                    appScope.launch {
                                        try {
                                            CallNotificationHelper.toggleMute(context.applicationContext, state.callUuid)
                                        } finally {
                                            withContext(Dispatchers.Main) {
                                                actionInFlight = false
                                            }
                                        }
                                    }
                                },
                            contentAlignment = Alignment.Center
                        ) {
                            Icon(
                                imageVector = if (isMuted) Icons.Rounded.MicOff else Icons.Rounded.Mic,
                                contentDescription = null,
                                tint = if (isMuted) DialerCanvasBlack else DialerPrimaryText,
                                modifier = Modifier.size(24.dp)
                            )
                        }
                    }
                }

                if (state.phase == CallPhase.ONGOING && canTransferToPhone) {
                    Spacer(modifier = Modifier.width(6.dp))

                    Box(
                        modifier = Modifier
                            .offset(y = (-8).dp)
                            .size(48.dp)
                            .clip(CircleShape)
                            .background(DialerElevatedSurface)
                            .semantics { contentDescription = "Transfer to phone" }
                            .clickable(enabled = !actionInFlight, role = Role.Button) {
                                actionInFlight = true
                                transferFeedback = "Sending to phone…"
                                appScope.launch {
                                    val sent = try {
                                        CallNotificationHelper.transferCallToPhone(
                                            context.applicationContext,
                                            state.callUuid
                                        )
                                    } finally {
                                        withContext(Dispatchers.Main) {
                                            actionInFlight = false
                                        }
                                    }
                                    withContext(Dispatchers.Main) {
                                        transferFeedback = if (sent) "Audio moved to phone" else "Couldn't reach phone"
                                    }
                                }
                            },
                        contentAlignment = Alignment.Center
                    ) {
                        PhoneTransferIcon(
                            tint = DialerPrimaryText,
                            modifier = Modifier.size(22.dp)
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun CallTimerText(
    startedAtElapsedMs: Long,
    isMuted: Boolean,
    callKind: String
) {
    val lifecycleOwner = LocalLifecycleOwner.current
    var elapsedSeconds by remember(startedAtElapsedMs) {
        mutableLongStateOf(
            if (startedAtElapsedMs > 0L) {
                ((SystemClock.elapsedRealtime() - startedAtElapsedMs) / 1000L).coerceAtLeast(0L)
            } else {
                0L
            }
        )
    }
    LaunchedEffect(startedAtElapsedMs, lifecycleOwner) {
        if (startedAtElapsedMs > 0L) {
            lifecycleOwner.repeatOnLifecycle(Lifecycle.State.RESUMED) {
                while (true) {
                    elapsedSeconds = ((SystemClock.elapsedRealtime() - startedAtElapsedMs) / 1000L).coerceAtLeast(0L)
                    delay(1000L)
                }
            }
        }
    }
    val mins = elapsedSeconds / 60L
    val secs = elapsedSeconds % 60L
    val suffix = if (isMuted) "Muted" else callKind
    Text(
        text = String.format(Locale.US, "%02d:%02d • %s", mins, secs, suffix),
        color = DialerAnswerGreen,
        style = centeredTextStyle(
            fontSize = 12.sp,
            lineHeight = 16.sp,
            fontWeight = FontWeight.Medium
        ).copy(fontFeatureSettings = "tnum"),
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        textAlign = TextAlign.Center
    )
}

internal fun ringingCallSubtitle(
    isVideo: Boolean,
    isTelephony: Boolean,
    isGroup: Boolean = false
): String = CallNotificationHelper.callKindLabel(
    isVideo = isVideo,
    isTelephony = isTelephony,
    isGroup = isGroup
)
