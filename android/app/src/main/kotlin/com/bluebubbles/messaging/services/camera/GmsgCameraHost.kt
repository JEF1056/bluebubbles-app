package com.bluebubbles.messaging.services.camera

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.OrientationEventListener
import android.view.Surface
import android.view.View
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.extensions.ExtensionMode
import androidx.camera.extensions.ExtensionsManager
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FallbackStrategy
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import com.bluebubbles.messaging.Constants
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class GmsgCameraHost private constructor(
    private val activity: FlutterFragmentActivity,
) {
    companion object {
        private const val CHANNEL = "com.bluebubbles.messaging/gmsg_camera"
        private const val VIEW_TYPE = "com.bluebubbles.messaging/gmsg_camera_preview"

        fun register(engine: FlutterEngine, activity: FlutterFragmentActivity) {
            val host = GmsgCameraHost(activity)
            MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
                host.onMethodCall(call, result)
            }
            engine.platformViewsController.registry.registerViewFactory(VIEW_TYPE, host.ViewFactory())
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val mainExecutor = ContextCompat.getMainExecutor(activity)
    private val captureExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    private val previewViews = HashMap<Int, PreviewView>()
    private var activeViewId: Int? = null
    private var cameraProvider: ProcessCameraProvider? = null
    private var extensionsManager: ExtensionsManager? = null
    private var camera: Camera? = null
    private var preview: Preview? = null
    private var imageCapture: ImageCapture? = null
    private var videoCapture: VideoCapture<Recorder>? = null
    private var activeRecording: Recording? = null
    private var pendingStopResult: MethodChannel.Result? = null
    private var currentVideoMode = false
    private var currentFlashMode = "off"
    private var initGeneration = 0

    private val orientationListener = object : OrientationEventListener(activity) {
        override fun onOrientationChanged(orientation: Int) {
            if (orientation == ORIENTATION_UNKNOWN) return
            val rotation = when {
                orientation in 45..134 -> Surface.ROTATION_270
                orientation in 135..224 -> Surface.ROTATION_180
                orientation in 225..314 -> Surface.ROTATION_90
                else -> Surface.ROTATION_0
            }
            imageCapture?.targetRotation = rotation
            videoCapture?.targetRotation = rotation
        }
    }

    private inner class ViewFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
        override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
            val previewView = PreviewView(context).apply {
                implementationMode = PreviewView.ImplementationMode.COMPATIBLE
                scaleType = PreviewView.ScaleType.FILL_CENTER
            }
            previewViews[viewId] = previewView
            return object : PlatformView {
                override fun getView(): View = previewView

                override fun dispose() {
                    previewViews.remove(viewId)
                    if (activeViewId == viewId) {
                        releaseCamera()
                    }
                }
            }
        }
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> {
                val viewId = call.argument<Number>("viewId")?.toInt()
                if (viewId == null) {
                    result.error("invalid_args", "Missing viewId", null)
                    return
                }
                val lensFacing = call.argument<String>("lensFacing") ?: "back"
                val videoMode = call.argument<Boolean>("videoMode") ?: false
                val flashMode = call.argument<String>("flashMode") ?: "off"
                initialize(viewId, lensFacing, videoMode, flashMode, result)
            }
            "setFlashMode" -> {
                val mode = call.argument<String>("mode") ?: "off"
                setFlashMode(mode, result)
            }
            "setZoom" -> {
                val zoom = call.argument<Number>("zoom")?.toFloat() ?: 1.0f
                setZoom(zoom, result)
            }
            "takePicture" -> takePicture(result)
            "startVideoRecording" -> {
                val enableAudio = call.argument<Boolean>("enableAudio") ?: false
                startVideoRecording(enableAudio, result)
            }
            "stopVideoRecording" -> stopVideoRecording(result)
            "dispose" -> {
                releaseCamera()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun initialize(
        viewId: Int,
        requestedLens: String,
        videoMode: Boolean,
        flashMode: String,
        result: MethodChannel.Result,
    ) {
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            result.error("CameraAccessDenied", "Camera permission not granted", null)
            return
        }
        val previewView = previewViews[viewId]
        if (previewView == null) {
            result.error("no_view", "PreviewView $viewId not mounted", null)
            return
        }

        val generation = ++initGeneration
        val providerFuture = ProcessCameraProvider.getInstance(activity)
        providerFuture.addListener({
            if (generation != initGeneration) {
                result.error("cancelled", "Superseded by newer initialize call", null)
                return@addListener
            }
            val provider = try {
                providerFuture.get()
            } catch (e: Exception) {
                result.error("camera_init_failed", e.message, null)
                return@addListener
            }
            cameraProvider = provider

            val extFuture = ExtensionsManager.getInstanceAsync(activity, provider)
            extFuture.addListener({
                if (generation != initGeneration) {
                    result.error("cancelled", "Superseded by newer initialize call", null)
                    return@addListener
                }
                val extMgr = try {
                    extFuture.get()
                } catch (e: Exception) {
                    Log.w(Constants.logTag, "CameraX ExtensionsManager unavailable, falling back to MAXIMIZE_QUALITY", e)
                    null
                }
                extensionsManager = extMgr
                bindCamera(provider, extMgr, viewId, previewView, requestedLens, videoMode, flashMode, result)
            }, mainExecutor)
        }, mainExecutor)
    }

    private fun bindCamera(
        provider: ProcessCameraProvider,
        extMgr: ExtensionsManager?,
        viewId: Int,
        previewView: PreviewView,
        requestedLens: String,
        videoMode: Boolean,
        flashMode: String,
        result: MethodChannel.Result,
    ) {
        try {
            val hasBack = provider.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA)
            val hasFront = provider.hasCamera(CameraSelector.DEFAULT_FRONT_CAMERA)
            val useFront = (requestedLens == "front" && hasFront) || (!hasBack && hasFront)
            val baseSelector = when {
                useFront && hasFront -> CameraSelector.DEFAULT_FRONT_CAMERA
                hasBack -> CameraSelector.DEFAULT_BACK_CAMERA
                else -> {
                    result.error("no_camera", "No cameras available on device", null)
                    return
                }
            }

            stopRecordingQuietly()
            provider.unbindAll()

            val displayRotation = previewView.display?.rotation ?: Surface.ROTATION_0
            val previewUseCase = Preview.Builder()
                .setTargetRotation(displayRotation)
                .setResolutionSelector(
                    ResolutionSelector.Builder()
                        .setAspectRatioStrategy(AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY)
                        .build()
                )
                .build()
                .also { it.surfaceProvider = previewView.surfaceProvider }

            var boundCamera: Camera? = null
            var boundExtension = "NONE"

            if (!videoMode) {
                val captureUseCase = ImageCapture.Builder()
                    .setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY)
                    .setFlashMode(mapFlashMode(flashMode))
                    .setTargetRotation(displayRotation)
                    .setResolutionSelector(
                        ResolutionSelector.Builder()
                            .setAspectRatioStrategy(AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY)
                            .setResolutionStrategy(ResolutionStrategy.HIGHEST_AVAILABLE_STRATEGY)
                            .build()
                    )
                    .build()

                val candidates = mutableListOf<Pair<String, CameraSelector>>()
                if (extMgr != null) {
                    for ((label, mode) in listOf(
                        "AUTO" to ExtensionMode.AUTO,
                        "HDR" to ExtensionMode.HDR,
                    )) {
                        if (runCatching { extMgr.isExtensionAvailable(baseSelector, mode) }.getOrDefault(false)) {
                            runCatching { extMgr.getExtensionEnabledCameraSelector(baseSelector, mode) }
                                .getOrNull()
                                ?.let { candidates.add(label to it) }
                        }
                    }
                }
                candidates.add("NONE" to baseSelector)

                var lastError: Exception? = null
                for ((label, selector) in candidates) {
                    try {
                        provider.unbindAll()
                        boundCamera = provider.bindToLifecycle(activity, selector, previewUseCase, captureUseCase)
                        boundExtension = label
                        break
                    } catch (e: Exception) {
                        lastError = e
                        Log.w(Constants.logTag, "CameraX bind failed for extension=$label, trying fallback", e)
                    }
                }
                if (boundCamera == null) {
                    result.error("camera_bind_failed", lastError?.message ?: "Failed to bind CameraX photo use cases", null)
                    return
                }
                imageCapture = captureUseCase
                videoCapture = null
            } else {
                val qualitySelector = QualitySelector.from(
                    Quality.HIGHEST,
                    FallbackStrategy.lowerQualityOrHigherThan(Quality.SD),
                )
                val recorder = Recorder.Builder()
                    .setQualitySelector(qualitySelector)
                    .build()
                val videoUseCase = VideoCapture.Builder(recorder)
                    .setTargetRotation(displayRotation)
                    .build()

                boundCamera = provider.bindToLifecycle(activity, baseSelector, previewUseCase, videoUseCase)
                imageCapture = null
                videoCapture = videoUseCase
                if (boundCamera.cameraInfo.hasFlashUnit()) {
                    boundCamera.cameraControl.enableTorch(flashMode == "always")
                }
            }

            activeViewId = viewId
            preview = previewUseCase
            camera = boundCamera
            currentVideoMode = videoMode
            currentFlashMode = flashMode
            if (orientationListener.canDetectOrientation()) {
                orientationListener.enable()
            }

            val zoomState = boundCamera.cameraInfo.zoomState.value
            val minZoom = zoomState?.minZoomRatio?.toDouble() ?: 1.0
            val maxZoom = zoomState?.maxZoomRatio?.toDouble() ?: 1.0
            val initialZoom = 1.0f.coerceIn(minZoom.toFloat(), maxZoom.toFloat())
            boundCamera.cameraControl.setZoomRatio(initialZoom)

            Log.i(
                Constants.logTag,
                "GmsgCamera bound lens=${if (useFront) "front" else "back"} video=$videoMode ext=$boundExtension zoom=[$minZoom,$maxZoom]",
            )

            result.success(
                mapOf(
                    "minZoom" to minZoom,
                    "maxZoom" to maxZoom,
                    "hasFlash" to boundCamera.cameraInfo.hasFlashUnit(),
                    "hasBackCamera" to hasBack,
                    "hasFrontCamera" to hasFront,
                    "lensFacing" to if (useFront) "front" else "back",
                    "extensionMode" to boundExtension,
                ),
            )
        } catch (e: Exception) {
            Log.e(Constants.logTag, "GmsgCamera bindCamera error", e)
            result.error("camera_bind_failed", e.message, null)
        }
    }

    private fun setFlashMode(mode: String, result: MethodChannel.Result) {
        val cam = camera
        if (cam == null || !cam.cameraInfo.hasFlashUnit()) {
            result.error("no_flash", "Camera has no flash unit", null)
            return
        }
        currentFlashMode = mode
        imageCapture?.flashMode = mapFlashMode(mode)
        if (currentVideoMode) {
            cam.cameraControl.enableTorch(mode == "always")
        }
        result.success(null)
    }

    private fun setZoom(zoom: Float, result: MethodChannel.Result) {
        val cam = camera
        if (cam == null) {
            result.error("not_ready", "Camera not initialized", null)
            return
        }
        val state = cam.cameraInfo.zoomState.value
        val clamped = if (state != null) zoom.coerceIn(state.minZoomRatio, state.maxZoomRatio) else zoom
        cam.cameraControl.setZoomRatio(clamped)
        result.success(clamped.toDouble())
    }

    private fun takePicture(result: MethodChannel.Result) {
        val capture = imageCapture
        if (capture == null) {
            result.error("not_ready", "ImageCapture not initialized", null)
            return
        }
        val outFile = try {
            File.createTempFile("GMSG_IMG_", ".jpg", activity.cacheDir)
        } catch (e: Exception) {
            result.error("io_error", e.message, null)
            return
        }

        val replied = AtomicBoolean(false)
        val options = ImageCapture.OutputFileOptions.Builder(outFile).build()
        capture.takePicture(
            options,
            captureExecutor,
            object : ImageCapture.OnImageSavedCallback {
                override fun onImageSaved(outputFileResults: ImageCapture.OutputFileResults) {
                    if (!replied.compareAndSet(false, true)) return
                    mainHandler.post { result.success(outFile.absolutePath) }
                }

                override fun onError(exception: ImageCaptureException) {
                    outFile.delete()
                    if (!replied.compareAndSet(false, true)) return
                    mainHandler.post { result.error("capture_failed", exception.message, null) }
                }
            },
        )
    }

    private fun startVideoRecording(enableAudio: Boolean, result: MethodChannel.Result) {
        val videoUseCase = videoCapture
        if (videoUseCase == null) {
            result.error("not_ready", "VideoCapture not initialized", null)
            return
        }
        if (activeRecording != null) {
            result.error("already_recording", "Recording already in progress", null)
            return
        }
        val outFile = try {
            File.createTempFile("GMSG_VID_", ".mp4", activity.cacheDir)
        } catch (e: Exception) {
            result.error("io_error", e.message, null)
            return
        }

        val outputOptions = FileOutputOptions.Builder(outFile).build()
        var pending = videoUseCase.output.prepareRecording(activity, outputOptions)
        if (enableAudio && ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            pending = pending.withAudioEnabled()
        }

        var recording: Recording? = null
        recording = pending.start(mainExecutor) { event ->
            if (event is VideoRecordEvent.Finalize) {
                val stopResult = if (activeRecording === recording) pendingStopResult else null
                if (activeRecording === recording) {
                    pendingStopResult = null
                    activeRecording = null
                }
                if (event.hasError()) {
                    outFile.delete()
                    stopResult?.error("record_failed", "Video recording error (${event.error})", null)
                } else {
                    stopResult?.success(outFile.absolutePath)
                }
            }
        }
        activeRecording = recording
        result.success(null)
    }

    private fun stopVideoRecording(result: MethodChannel.Result) {
        val rec = activeRecording
        if (rec == null) {
            result.error("not_recording", "No active recording", null)
            return
        }
        pendingStopResult = result
        rec.stop()
    }

    private fun stopRecordingQuietly() {
        pendingStopResult?.error("cancelled", "Camera session closed", null)
        pendingStopResult = null
        runCatching { activeRecording?.stop() }
        activeRecording = null
    }

    private fun releaseCamera() {
        initGeneration++
        orientationListener.disable()
        stopRecordingQuietly()
        runCatching { cameraProvider?.unbindAll() }
        activeViewId = null
        camera = null
        preview = null
        imageCapture = null
        videoCapture = null
    }

    private fun mapFlashMode(mode: String): Int = when (mode) {
        "auto" -> ImageCapture.FLASH_MODE_AUTO
        "always" -> ImageCapture.FLASH_MODE_ON
        else -> ImageCapture.FLASH_MODE_OFF
    }
}
