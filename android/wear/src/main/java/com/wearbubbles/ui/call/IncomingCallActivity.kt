package com.wearbubbles.ui.call

import android.graphics.BitmapFactory
import android.os.Bundle
import android.os.SystemClock
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Call
import androidx.compose.material.icons.rounded.CallEnd
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
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
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File
import java.util.Locale

class IncomingCallActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setShowWhenLocked(true)
        setTurnScreenOn(true)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        setContent {
            val callState by CallNotificationHelper.activeCallState.collectAsState()
            LaunchedEffect(callState) {
                if (callState == null) {
                    finish()
                }
            }
            callState?.let { state ->
                IncomingCallScreen(state = state)
            }
        }
    }
}

@Composable
private fun IncomingCallScreen(state: ActiveCallState) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var actionInFlight by remember(state.callUuid, state.phase) { mutableStateOf(false) }

    var elapsedSeconds by remember(state.phase, state.startedAtElapsedMs) {
        mutableLongStateOf(0L)
    }
    LaunchedEffect(state.phase, state.startedAtElapsedMs) {
        if (state.phase == CallPhase.ONGOING && state.startedAtElapsedMs > 0L) {
            while (true) {
                elapsedSeconds = ((SystemClock.elapsedRealtime() - state.startedAtElapsedMs) / 1000L).coerceAtLeast(0L)
                delay(1000L)
            }
        }
    }

    val avatarBitmap = remember(state.avatarPath) {
        state.avatarPath?.let { path ->
            val file = File(path)
            if (file.exists()) BitmapFactory.decodeFile(file.absolutePath)?.asImageBitmap() else null
        }
    }

    val bgBrush = remember {
        Brush.verticalGradient(
            colors = listOf(Color(0xFF0E1520), Color(0xFF000000))
        )
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(bgBrush)
            .padding(horizontal = 16.dp, vertical = 14.dp),
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
                        .size(52.dp)
                        .clip(CircleShape)
                        .background(Color(0xFF1F2A3A)),
                    contentAlignment = Alignment.Center
                ) {
                    if (avatarBitmap != null) {
                        Image(
                            bitmap = avatarBitmap,
                            contentDescription = state.callerName,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.fillMaxSize()
                        )
                    } else {
                        Text(
                            text = state.callerName.firstOrNull()?.uppercase() ?: "?",
                            color = Color.White,
                            fontSize = 20.sp,
                            fontWeight = FontWeight.SemiBold
                        )
                    }
                }

                Spacer(modifier = Modifier.height(8.dp))

                Text(
                    text = state.callerName,
                    color = Color.White,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    textAlign = TextAlign.Center
                )

                Spacer(modifier = Modifier.height(2.dp))

                val subtitle = when (state.phase) {
                    CallPhase.RINGING -> if (state.isVideo) {
                        "FaceTime Video • Audio only"
                    } else {
                        "FaceTime Audio"
                    }
                    CallPhase.ONGOING -> {
                        val mins = elapsedSeconds / 60L
                        val secs = elapsedSeconds % 60L
                        String.format(Locale.US, "%02d:%02d • Audio", mins, secs)
                    }
                }
                Text(
                    text = subtitle,
                    color = if (state.phase == CallPhase.ONGOING) Color(0xFF30D158) else Color(0xFF9AA4B2),
                    fontSize = 12.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    textAlign = TextAlign.Center
                )
            }

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = 6.dp),
                horizontalArrangement = Arrangement.SpaceEvenly,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    modifier = Modifier
                        .size(52.dp)
                        .clip(CircleShape)
                        .background(Color(0xFFFF453A))
                        .semantics { contentDescription = if (state.phase == CallPhase.ONGOING) "End Call" else "Decline" }
                        .clickable(enabled = !actionInFlight, role = Role.Button) {
                            actionInFlight = true
                            scope.launch {
                                try {
                                    CallNotificationHelper.declineOrEndCall(context, state.callUuid)
                                } finally {
                                    actionInFlight = false
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

                if (state.phase == CallPhase.RINGING) {
                    Box(
                        modifier = Modifier
                            .size(52.dp)
                            .clip(CircleShape)
                            .background(Color(0xFF30D158))
                            .semantics { contentDescription = "Answer Audio" }
                            .clickable(enabled = !actionInFlight, role = Role.Button) {
                                actionInFlight = true
                                scope.launch {
                                    try {
                                        CallNotificationHelper.answerCallAudio(context, state.callUuid)
                                    } finally {
                                        actionInFlight = false
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
        }
    }
}
