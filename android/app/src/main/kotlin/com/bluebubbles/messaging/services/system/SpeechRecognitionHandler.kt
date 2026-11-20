package com.bluebubbles.messaging.services.system

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import com.bluebubbles.messaging.MainActivity
import com.bluebubbles.messaging.models.MethodCallHandlerImpl
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// Bridges Android's system SpeechRecognizer (e.g. Gboard / Google Speech Services) to Flutter.
class SpeechRecognitionHandler : MethodCallHandlerImpl() {
    companion object {
        const val tag: String = "speech-recognition"
        private const val eventChannelName: String = "com.bluebubbles.messaging/speech"
        private val mainHandler = Handler(Looper.getMainLooper())
        private var recognizer: SpeechRecognizer? = null

        private fun runOnMain(block: () -> Unit) {
            if (Looper.myLooper() == Looper.getMainLooper()) {
                block()
            } else {
                mainHandler.post(block)
            }
        }

        private fun destroyRecognizer() {
            recognizer?.let {
                try {
                    it.cancel()
                } catch (_: Exception) {}
                try {
                    it.destroy()
                } catch (_: Exception) {}
            }
            recognizer = null
        }

        private fun emitEvent(type: String, text: String = "") {
            runOnMain {
                val engine = MainActivity.getEngine() ?: return@runOnMain
                if (!MainActivity.isDartReady()) return@runOnMain
                MethodChannel(engine.dartExecutor.binaryMessenger, eventChannelName)
                    .invokeMethod("onSpeechEvent", mapOf("type" to type, "text" to text))
            }
        }
    }

    override fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        context: Context
    ) {
        val appContext = context.applicationContext
        when (call.argument<String>("action")) {
            "isAvailable" -> {
                runOnMain {
                    result.success(SpeechRecognizer.isRecognitionAvailable(appContext))
                }
            }
            "start" -> {
                val locale = call.argument<String>("locale")
                runOnMain {
                    if (!SpeechRecognizer.isRecognitionAvailable(appContext)) {
                        result.success(false)
                        return@runOnMain
                    }
                    try {
                        destroyRecognizer()
                        val sr = SpeechRecognizer.createSpeechRecognizer(appContext)
                        sr.setRecognitionListener(object : RecognitionListener {
                            override fun onReadyForSpeech(params: Bundle?) {}
                            override fun onBeginningOfSpeech() {}
                            override fun onRmsChanged(rmsdB: Float) {}
                            override fun onBufferReceived(buffer: ByteArray?) {}
                            override fun onEndOfSpeech() {}
                            override fun onEvent(eventType: Int, params: Bundle?) {}

                            override fun onPartialResults(partialResults: Bundle?) {
                                val text = partialResults
                                    ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                                    ?.firstOrNull()
                                    ?.trim()
                                    .orEmpty()
                                if (text.isNotEmpty()) emitEvent("partial", text)
                            }

                            override fun onResults(results: Bundle?) {
                                val text = results
                                    ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                                    ?.firstOrNull()
                                    ?.trim()
                                    .orEmpty()
                                if (text.isNotEmpty()) emitEvent("final", text)
                                emitEvent("done")
                                destroyRecognizer()
                            }

                            override fun onError(error: Int) {
                                emitEvent("error", error.toString())
                                destroyRecognizer()
                            }
                        })
                        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                            putExtra(
                                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
                            )
                            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
                            if (!locale.isNullOrBlank()) {
                                putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
                            }
                        }
                        recognizer = sr
                        sr.startListening(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        destroyRecognizer()
                        result.error("speech-error", e.message, null)
                    }
                }
            }
            "stop" -> {
                runOnMain {
                    try {
                        recognizer?.stopListening()
                    } catch (_: Exception) {}
                    result.success(null)
                }
            }
            "cancel" -> {
                runOnMain {
                    destroyRecognizer()
                    result.success(null)
                }
            }
            else -> result.error("invalid-action", "Unknown speech-recognition action", null)
        }
    }
}
