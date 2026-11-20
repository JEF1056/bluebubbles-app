package com.bluebubbles.messaging

import android.content.Intent
import android.content.LocusId
import android.os.Build
import android.os.Bundle
import com.bluebubbles.messaging.services.backend_ui_interop.MethodCallHandler
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class BubbleActivity : FlutterFragmentActivity() {
    companion object {
        private val engineLock = Any()
        @Volatile private var _engine: FlutterEngine? = null
        
        fun getEngine(): FlutterEngine? {
            synchronized(engineLock) {
                return _engine
            }
        }
        
        fun setEngine(newEngine: FlutterEngine?) {
            synchronized(engineLock) {
                _engine = newEngine
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        updateLocusContext(intent?.getStringExtra("chatGuid"))
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        updateLocusContext(intent.getStringExtra("chatGuid"))
    }

    private fun updateLocusContext(chatGuid: String?) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val locusId = chatGuid?.takeIf { it.isNotBlank() && it != "-1" }?.let(::LocusId)
            setLocusContext(locusId, null)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        setEngine(flutterEngine)
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, Constants.methodChannel).setMethodCallHandler {
                call, result ->
            if (call.method == "ready") {
                result.success(null)
            } else {
                MethodCallHandler().methodCallHandler(call, result, this)
            }
        }
    }

    override fun getDartEntrypointFunctionName(): String {
        return "bubble"
    }

    override fun onDestroy() {
        setEngine(null)
        super.onDestroy()
    }
}