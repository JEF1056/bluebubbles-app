package com.bluebubbles.messaging

import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.LocusId
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.KeyEvent
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsAnimation
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.core.view.WindowCompat
import com.bluebubbles.messaging.services.backend_ui_interop.MethodCallHandler
import com.bluebubbles.messaging.services.camera.GmsgCameraHost
import com.bluebubbles.messaging.services.extensions.OpenPigeonHost
import com.bluebubbles.messaging.services.findmy.FindMyBleHost
import com.bluebubbles.messaging.services.foreground.ForegroundServiceBroadcastReceiver
import com.bluebubbles.messaging.services.notifications.CreateIncomingFaceTimeNotification
import com.bluebubbles.messaging.services.telecom.CallTonePlayer
import com.bluebubbles.messaging.services.telecom.FaceTimeConnectionService
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.utils.PersistentLog
import com.google.firebase.firestore.FirebaseFirestoreException
import io.flutter.embedding.android.FlutterFragment
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

internal object LockScreenCallPolicy {
    const val EXTRA_INCOMING_FACETIME = "incomingFaceTime"

    fun shouldShowOverLockScreenForIncomingCall(
        intentType: String?,
        hasIncomingFaceTimeExtra: Boolean,
        incomingFaceTimeExtra: Boolean,
        callUuid: String?,
        answerExtra: Boolean,
        launchedFromHistory: Boolean,
        isCallPendingEnded: Boolean = !callUuid.isNullOrBlank() &&
            FaceTimeConnectionService.isCallPendingEnded(callUuid)
    ): Boolean {
        if (launchedFromHistory) return false
        val isFaceTimeLaunch = if (hasIncomingFaceTimeExtra) {
            incomingFaceTimeExtra
        } else {
            val hasUuid = !callUuid.isNullOrBlank()
            when (intentType) {
                "AnswerFaceTime" -> hasUuid || answerExtra
                "OpenSummary" -> hasUuid
                else -> false
            }
        }
        return isFaceTimeLaunch && !isCallPendingEnded
    }

    @Suppress("DEPRECATION")
    fun applyLockScreenFlags(
        sdkInt: Int,
        enabled: Boolean,
        setShowWhenLocked: (Boolean) -> Unit,
        setTurnScreenOn: (Boolean) -> Unit,
        addWindowFlags: (Int) -> Unit,
        clearWindowFlags: (Int) -> Unit
    ) {
        val legacyFlags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
            WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
        if (enabled) {
            if (sdkInt >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(true)
                setTurnScreenOn(true)
            } else {
                addWindowFlags(legacyFlags)
            }
        } else {
            if (sdkInt >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(false)
                setTurnScreenOn(false)
            }
            clearWindowFlags(legacyFlags)
        }
    }

    fun dismissIncomingFaceTimeNotification(
        intentType: String?,
        answerExtra: Boolean,
        callUuid: String?,
        notificationId: Int,
        stopRing: (String?) -> Unit,
        cancelByCallUuid: (String) -> Unit,
        cancelByNotificationId: (Int) -> Unit
    ) {
        if (intentType != "AnswerFaceTime" || !answerExtra) return
        stopRing(callUuid)
        if (!callUuid.isNullOrBlank()) {
            cancelByCallUuid(callUuid)
        }
        if (notificationId != 0) {
            cancelByNotificationId(notificationId)
        }
    }

    fun handleAnswerFaceTime(
        intentType: String?,
        answerExtra: Boolean,
        callUuid: String?,
        caller: String?,
        address: String?,
        isTelephony: Boolean,
        hasVideoExtra: Boolean,
        videoExtra: Boolean,
        audioOnlyExtra: Boolean,
        addIncomingCall: (callUuid: String, caller: String, address: String?, isTelephony: Boolean, isVideo: Boolean) -> Boolean,
        rewriteExtras: (openCall: Boolean, answer: Boolean) -> Unit
    ): Boolean {
        if (intentType != "AnswerFaceTime" || !answerExtra || callUuid.isNullOrBlank()) {
            return false
        }
        val isVideo = if (hasVideoExtra) videoExtra else !audioOnlyExtra
        val routed = addIncomingCall(callUuid, caller ?: "", address, isTelephony, isVideo)
        if (routed) {
            rewriteExtras(true, false)
        }
        return routed
    }

    fun handleAnswerFaceTimeIntent(
        intent: Intent?,
        addIncomingCall: (callUuid: String, caller: String, address: String?, isTelephony: Boolean, isVideo: Boolean) -> Boolean
    ): Boolean {
        if (intent == null) return false
        return handleAnswerFaceTime(
            intentType = intent.type,
            answerExtra = intent.getBooleanExtra("answer", false),
            callUuid = intent.getStringExtra("callUuid"),
            caller = intent.getStringExtra("caller") ?: intent.getStringExtra("callerName"),
            address = intent.getStringExtra("callerAddress") ?: intent.getStringExtra("address"),
            isTelephony = intent.getBooleanExtra("isTelephony", false),
            hasVideoExtra = intent.hasExtra("isVideo"),
            videoExtra = intent.getBooleanExtra("isVideo", false),
            audioOnlyExtra = intent.getBooleanExtra("audioOnly", false),
            addIncomingCall = addIncomingCall,
            rewriteExtras = { openCall, answer ->
                intent.putExtra("openCall", openCall)
                intent.putExtra("answer", answer)
            }
        )
    }
}

class MainActivity : FlutterFragmentActivity() {
    companion object {
        internal const val EXTRA_INCOMING_FACETIME = LockScreenCallPolicy.EXTRA_INCOMING_FACETIME
        private val engineLock = Any()
        @Volatile private var _engine: FlutterEngine? = null
        @Volatile private var activeInstance: WeakReference<MainActivity>? = null

        // Whether the Dart side of [_engine] has finished registering its method-call
        // handler (signaled via the "ready" method call — see MethodCallHandler).
        // Always reset to false alongside [_engine] itself so a stale "ready" from a
        // previous engine can never be mistaken for the current one's readiness.
        @Volatile private var _dartReady = false

        fun clearCallLockScreenFlags() {
            if (FaceTimeConnectionService.hasActiveCall()) return
            val clearRunnable = Runnable {
                if (FaceTimeConnectionService.hasActiveCall()) return@Runnable
                val activity = activeInstance?.get() ?: return@Runnable
                if (activity.isDestroyed) return@Runnable
                activity.intent?.putExtra(EXTRA_INCOMING_FACETIME, false)
                activity.applyLockScreenFlags(false)
            }
            if (Looper.myLooper() == Looper.getMainLooper()) {
                clearRunnable.run()
            } else {
                Handler(Looper.getMainLooper()).post(clearRunnable)
            }
        }

        fun getEngine(): FlutterEngine? {
            synchronized(engineLock) {
                return _engine
            }
        }

        fun setEngine(newEngine: FlutterEngine?, context: Context) {
            synchronized(engineLock) {
                PersistentLog.d(
                    context,
                    Constants.logTag,
                    "MainActivity engine ${if (newEngine != null) "set (${newEngine.hashCode()})" else "cleared"} — resetting dartReady to false"
                )
                _engine = newEngine
                _dartReady = false
            }
        }

        fun isDartReady(): Boolean {
            synchronized(engineLock) {
                return _dartReady
            }
        }

        fun setDartReady(ready: Boolean, context: Context) {
            synchronized(engineLock) {
                if (_dartReady != ready) {
                    PersistentLog.d(context, Constants.logTag, "MainActivity dartReady changing from $_dartReady to $ready")
                }
                _dartReady = ready
            }
        }
    }

    // Workaround for stale IME insets leaving half the screen blank on resume (#3377).
    // Remove once https://github.com/flutter/flutter/pull/191453 lands in our Flutter version.
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        activeInstance = WeakReference(this)
        configureEdgeToEdge()
        updateLockScreenFlagsForIntent(intent)
        dismissIncomingFaceTimeNotificationIfAnswering(intent)
        handleAnswerFaceTimeIntent(intent)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return

        updateLocusContext(intent?.getStringExtra("chatGuid"))
        window.decorView.setWindowInsetsAnimationCallback(
            object : WindowInsetsAnimation.Callback(DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
                override fun onProgress(
                    insets: WindowInsets,
                    runningAnimations: List<WindowInsetsAnimation>,
                ) = insets

                override fun onEnd(animation: WindowInsetsAnimation) {
                    if ((animation.typeMask and WindowInsets.Type.ime()) != 0) reapplyInsets()
                }
            },
        )
    }

    @Suppress("DEPRECATION")
    private fun configureEdgeToEdge() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
            window.isStatusBarContrastEnforced = false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val attrs = window.attributes
            attrs.layoutInDisplayCutoutMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            } else {
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
            window.attributes = attrs
        }
    }

    override fun onNewIntent(intent: Intent) {
        // Rewrite answer extras before super.onNewIntent so receive_intent doesn't forward answer=true to Dart
        dismissIncomingFaceTimeNotificationIfAnswering(intent)
        handleAnswerFaceTimeIntent(intent)
        setIntent(intent)
        super.onNewIntent(intent)
        updateLockScreenFlagsForIntent(intent)
        updateLocusContext(intent.getStringExtra("chatGuid"))
    }

    private fun handleAnswerFaceTimeIntent(intent: Intent?) {
        val callUuid = intent?.getStringExtra("callUuid")
        val routed = LockScreenCallPolicy.handleAnswerFaceTimeIntent(intent) { uuid, caller, address, isTelephony, isVideo ->
            FaceTimeConnectionService.addIncomingCall(
                context = this,
                callUuid = uuid,
                callerName = caller,
                address = address,
                autoAnswer = true,
                isTelephony = isTelephony,
                isVideo = isVideo
            )
        }
        if (!routed && !callUuid.isNullOrBlank()) {
            CreateIncomingFaceTimeNotification.cancelIncomingCallNotification(this, callUuid)
            intent?.removeExtra("openCall")
            intent?.removeExtra("answer")
        }
    }

    private fun updateLockScreenFlagsForIntent(intent: Intent?) {
        val shouldShow = LockScreenCallPolicy.shouldShowOverLockScreenForIncomingCall(
            intentType = intent?.type,
            hasIncomingFaceTimeExtra = intent?.hasExtra(EXTRA_INCOMING_FACETIME) == true,
            incomingFaceTimeExtra = intent?.getBooleanExtra(EXTRA_INCOMING_FACETIME, false) == true,
            callUuid = intent?.getStringExtra("callUuid"),
            answerExtra = intent?.getBooleanExtra("answer", false) == true,
            launchedFromHistory = ((intent?.flags ?: 0) and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0
        )
        applyLockScreenFlags(shouldShow)
    }

    internal fun applyLockScreenFlags(enabled: Boolean) {
        LockScreenCallPolicy.applyLockScreenFlags(
            sdkInt = Build.VERSION.SDK_INT,
            enabled = enabled,
            setShowWhenLocked = { show ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) setShowWhenLocked(show)
            },
            setTurnScreenOn = { turnOn ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) setTurnScreenOn(turnOn)
            },
            addWindowFlags = { flags -> window.addFlags(flags) },
            clearWindowFlags = { flags -> window.clearFlags(flags) }
        )
    }

    private fun dismissIncomingFaceTimeNotificationIfAnswering(intent: Intent?) {
        LockScreenCallPolicy.dismissIncomingFaceTimeNotification(
            intentType = intent?.type,
            answerExtra = intent?.getBooleanExtra("answer", false) == true,
            callUuid = intent?.getStringExtra("callUuid"),
            notificationId = intent?.getIntExtra("notificationId", 0) ?: 0,
            stopRing = { CallTonePlayer.stopIncomingRing(it) },
            cancelByCallUuid = { CreateIncomingFaceTimeNotification.cancelIncomingCallNotification(this, it) },
            cancelByNotificationId = {
                getSystemService(NotificationManager::class.java)
                    ?.cancel(Constants.newFaceTimeNotificationTag, it)
            }
        )
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if ((keyCode == KeyEvent.KEYCODE_VOLUME_DOWN || keyCode == KeyEvent.KEYCODE_VOLUME_UP) &&
            CallTonePlayer.isIncomingRinging()
        ) {
            CallTonePlayer.stopIncomingRing()
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    fun updateLocusContext(chatGuid: String?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val locusId = chatGuid?.takeIf { it.isNotBlank() && it != "-1" }?.let(::LocusId)
            setLocusContext(locusId, null)
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) reapplyInsets()
    }

    // Posted so it runs after Flutter has applied any insets it deferred.
    private fun reapplyInsets() {
        val view = findViewById<View>(FlutterFragment.FLUTTER_VIEW_ID) ?: return
        view.post { view.rootWindowInsets?.let(view::onApplyWindowInsets) }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        setEngine(flutterEngine, this)
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, Constants.methodChannel).setMethodCallHandler {
            call, result -> MethodCallHandler().methodCallHandler(call, result, this)
        }
        OpenPigeonHost.register(flutterEngine, this)
        GmsgCameraHost.register(flutterEngine, this)
        FindMyBleHost.register(flutterEngine, this)

        val defaultHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            val cause = throwable.cause ?: throwable
            if (cause is FirebaseFirestoreException) {
                when (cause.code) {
                    FirebaseFirestoreException.Code.PERMISSION_DENIED ->
                        PersistentLog.e(this, Constants.logTag, "Firestore: PERMISSION_DENIED — missing or insufficient security rules (${cause.message})", cause)
                    FirebaseFirestoreException.Code.UNAVAILABLE ->
                        PersistentLog.e(this, Constants.logTag, "Firestore: UNAVAILABLE — service unreachable, check network connectivity (${cause.message})", cause)
                    FirebaseFirestoreException.Code.UNAUTHENTICATED ->
                        PersistentLog.e(this, Constants.logTag, "Firestore: UNAUTHENTICATED — request not authenticated (${cause.message})", cause)
                    FirebaseFirestoreException.Code.NOT_FOUND ->
                        PersistentLog.e(this, Constants.logTag, "Firestore: NOT_FOUND — document or collection does not exist (${cause.message})", cause)
                    FirebaseFirestoreException.Code.CANCELLED ->
                        PersistentLog.d(this, Constants.logTag, "Firestore: CANCELLED — listener was cancelled (${cause.message})")
                    FirebaseFirestoreException.Code.ALREADY_EXISTS ->
                        PersistentLog.w(this, Constants.logTag, "Firestore: ALREADY_EXISTS — document already exists (${cause.message})")
                    FirebaseFirestoreException.Code.RESOURCE_EXHAUSTED ->
                        PersistentLog.e(this, Constants.logTag, "Firestore: RESOURCE_EXHAUSTED — quota exceeded (${cause.message})", cause)
                    FirebaseFirestoreException.Code.FAILED_PRECONDITION ->
                        PersistentLog.e(this, Constants.logTag, "Firestore: FAILED_PRECONDITION — operation rejected, check indexes or state (${cause.message})", cause)
                    FirebaseFirestoreException.Code.ABORTED ->
                        PersistentLog.e(this, Constants.logTag, "Firestore: ABORTED — transaction conflict or contention (${cause.message})", cause)
                    FirebaseFirestoreException.Code.INTERNAL ->
                        PersistentLog.e(this, Constants.logTag, "Firestore: INTERNAL — internal server error (${cause.message})", cause)
                    FirebaseFirestoreException.Code.DEADLINE_EXCEEDED ->
                        PersistentLog.e(this, Constants.logTag, "Firestore: DEADLINE_EXCEEDED — operation timed out (${cause.message})", cause)
                    else ->
                        PersistentLog.e(this, Constants.logTag, "Firestore: unhandled error ${cause.code} (${cause.message})", cause)
                }
            } else {
                defaultHandler?.uncaughtException(thread, throwable)
            }
        }
    }

    override fun onDestroy() {
        PersistentLog.d(this, Constants.logTag, "BlueBubbles MainActivity is being destroyed")
        if (activeInstance?.get() === this) {
            activeInstance = null
        }
        MethodCallHandler.clearNotificationListenerResult()
        setEngine(null, this)

        // If we are finishing "gracefully", the dart code would have started the foreground service.
        // If we are finishing because the system is destroying the activity, we need to start the foreground service
        // via a broadcast intent.
        if (isFinishing) {
            PersistentLog.d(this, Constants.logTag, "BlueBubbles activity is finishing")
        } else {
            PersistentLog.d(this, Constants.logTag, "BlueBubbles activity is being destroyed by the system")

            val prefs = applicationContext.getSharedPreferences("FlutterSharedPreferences", 0)
            val keepAppAlive: Boolean = prefs.getBoolean("keepAppAlive", false)

            // Create an intent to start the foreground service
            if (keepAppAlive) {
                PersistentLog.d(this, Constants.logTag, "Creating broadcast intent to restart the foreground service...")
                val broadcastIntent = Intent(this, ForegroundServiceBroadcastReceiver::class.java)
                broadcastIntent.setAction("restartservice");
                sendBroadcast(broadcastIntent);
            }
        }

        try {
            super.onDestroy()
        } catch (e: ConcurrentModificationException) {
            PersistentLog.e(this, Constants.logTag, "Caught ConcurrentModificationException when destroying MainActivity", e)
        } catch (e: Exception) {
            PersistentLog.e(this, Constants.logTag, "Caught unhandled Exception when destroying MainActivity", e)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == Constants.notificationListenerRequestCode) {
            MethodCallHandler.consumeNotificationListenerResult()?.success(resultCode == Activity.RESULT_OK)
        }
    }
}