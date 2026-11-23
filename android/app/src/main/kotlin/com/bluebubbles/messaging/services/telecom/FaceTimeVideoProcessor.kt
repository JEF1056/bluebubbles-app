package com.bluebubbles.messaging.services.telecom

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Shader
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLUtils
import android.os.Handler
import android.os.HandlerThread
import com.bluebubbles.messaging.utils.PersistentLog
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.Segmentation
import com.google.mlkit.vision.segmentation.Segmenter
import com.google.mlkit.vision.segmentation.selfie.SelfieSegmenterOptions
import org.webrtc.EglBase
import org.webrtc.RendererCommon
import org.webrtc.ThreadUtils
import org.webrtc.TextureBufferImpl
import org.webrtc.VideoFrame
import org.webrtc.VideoProcessor
import org.webrtc.VideoSink
import org.webrtc.YuvConverter
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

enum class FaceTimeVideoEffect {
    NONE,
    BLUR_LIGHT,
    BLUR_STRONG,
    VIRTUAL_BACKGROUND;

    companion object {
        fun parse(raw: String?): FaceTimeVideoEffect = when (raw?.trim()?.lowercase()) {
            "blurlight", "blur_light" -> BLUR_LIGHT
            "blurstrong", "blur_strong" -> BLUR_STRONG
            "virtualbackground", "virtual_background" -> VIRTUAL_BACKGROUND
            else -> NONE
        }
    }
}

/**
 * Meet-style lightweight VideoProcessor:
 * - Zero-copy passthrough when effect == NONE && !denoiseEnabled.
 * - Async drop-if-busy ML Kit Selfie Segmentation (256x256 STREAM_MODE) + EMA mask smoothing.
 * - OpenGL ES 2.0 shaders on WebRTC's shared EglBase.Context (bilateral denoise, Dual-Kawase blur, virtual bg).
 * - Zero-CPU-readback TextureBufferImpl output directly to HW MediaCodec H.264 encoder & local preview.
 */
class FaceTimeVideoProcessor(
    private val context: Context,
    private val sharedEglContext: EglBase.Context
) : VideoProcessor {

    companion object {
        private const val TAG = "FaceTimeVideoProcessor"
        private const val MASK_INPUT_SIZE = 256
        private const val MASK_EMA_ALPHA_MIN = 0.35f
        private const val MASK_EMA_ALPHA_MAX = 0.90f
        private const val OUTPUT_POOL_SIZE = 5
        private const val THERMAL_FRAME_BUDGET_NS = 16_000_000L

        private const val GLSL_HIGHP_HEADER = """
            #ifdef GL_FRAGMENT_PRECISION_HIGH
            precision highp float;
            #else
            precision mediump float;
            #endif
        """

        private val FULLSCREEN_QUAD = floatArrayOf(
            -1f, -1f, 0f, 0f,
             1f, -1f, 1f, 0f,
            -1f,  1f, 0f, 1f,
             1f,  1f, 1f, 1f
        )

        private const val VERTEX_SHADER = """
            attribute vec4 aPos;
            attribute vec2 aTexCoord;
            uniform mat4 uTexMatrix;
            varying vec2 vTexCoord;
            void main() {
                gl_Position = aPos;
                vTexCoord = (uTexMatrix * vec4(aTexCoord, 0.0, 1.0)).xy;
            }
        """

        private const val FRAGMENT_PASSTHROUGH_OES = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            uniform samplerExternalOES uTex;
            varying vec2 vTexCoord;
            void main() {
                gl_FragColor = texture2D(uTex, vTexCoord);
            }
        """

        private const val FRAGMENT_PASSTHROUGH_2D = """
            precision mediump float;
            uniform sampler2D uTex;
            varying vec2 vTexCoord;
            void main() {
                gl_FragColor = texture2D(uTex, vTexCoord);
            }
        """

        private const val FRAGMENT_BILATERAL_OES = """
            #extension GL_OES_EGL_image_external : require
            $GLSL_HIGHP_HEADER
            uniform samplerExternalOES uTex;
            uniform vec2 uTexelSize;
            varying vec2 vTexCoord;
            void main() {
                vec3 center = texture2D(uTex, vTexCoord).rgb;
                float luma = dot(center, vec3(0.299, 0.587, 0.114));
                float rangeScale = mix(8.0, 22.0, smoothstep(0.08, 0.55, luma));
                vec3 sum = center;
                float wSum = 1.0;
                for (int x = -1; x <= 1; x++) {
                    for (int y = -1; y <= 1; y++) {
                        if (x == 0 && y == 0) continue;
                        vec3 s = texture2D(uTex, vTexCoord + vec2(float(x), float(y)) * uTexelSize).rgb;
                        vec3 diff = s - center;
                        float spatialW = exp(-float(x * x + y * y) * 0.35);
                        float rangeW = exp(-dot(diff, diff) * rangeScale);
                        float w = spatialW * rangeW;
                        sum += s * w;
                        wSum += w;
                    }
                }
                gl_FragColor = vec4(sum / wSum, 1.0);
            }
        """

        private const val FRAGMENT_BILATERAL_2D = """
            $GLSL_HIGHP_HEADER
            uniform sampler2D uTex;
            uniform vec2 uTexelSize;
            varying vec2 vTexCoord;
            void main() {
                vec3 center = texture2D(uTex, vTexCoord).rgb;
                float luma = dot(center, vec3(0.299, 0.587, 0.114));
                float rangeScale = mix(8.0, 22.0, smoothstep(0.08, 0.55, luma));
                vec3 sum = center;
                float wSum = 1.0;
                for (int x = -1; x <= 1; x++) {
                    for (int y = -1; y <= 1; y++) {
                        if (x == 0 && y == 0) continue;
                        vec3 s = texture2D(uTex, vTexCoord + vec2(float(x), float(y)) * uTexelSize).rgb;
                        vec3 diff = s - center;
                        float spatialW = exp(-float(x * x + y * y) * 0.35);
                        float rangeW = exp(-dot(diff, diff) * rangeScale);
                        float w = spatialW * rangeW;
                        sum += s * w;
                        wSum += w;
                    }
                }
                gl_FragColor = vec4(sum / wSum, 1.0);
            }
        """

        private const val FRAGMENT_TEMPORAL_DENOISE = """
            $GLSL_HIGHP_HEADER
            uniform sampler2D uTex;
            uniform sampler2D uHistTex;
            uniform vec2 uTexelSize;
            uniform float uHasHistory;
            varying vec2 vTexCoord;
            void main() {
                vec3 curr = texture2D(uTex, vTexCoord).rgb;
                if (uHasHistory < 0.5) {
                    gl_FragColor = vec4(curr, 1.0);
                    return;
                }
                vec3 prev = texture2D(uHistTex, vTexCoord).rgb;
                vec2 dx = vec2(uTexelSize.x, 0.0);
                vec2 dy = vec2(0.0, uTexelSize.y);
                vec3 currAvg = (curr
                    + texture2D(uTex, vTexCoord + dx).rgb
                    + texture2D(uTex, vTexCoord - dx).rgb
                    + texture2D(uTex, vTexCoord + dy).rgb
                    + texture2D(uTex, vTexCoord - dy).rgb) * 0.2;
                vec3 prevAvg = (prev
                    + texture2D(uHistTex, vTexCoord + dx).rgb
                    + texture2D(uHistTex, vTexCoord - dx).rgb
                    + texture2D(uHistTex, vTexCoord + dy).rgb
                    + texture2D(uHistTex, vTexCoord - dy).rgb) * 0.2;

                float meanLumaDiff = abs(dot(currAvg - prevAvg, vec3(0.299, 0.587, 0.114)));
                vec3 absDiff = abs(curr - prev);
                float maxChromaDiff = max(max(absDiff.r, absDiff.g), absDiff.b);
                float motion = max(meanLumaDiff, maxChromaDiff * 0.45);

                float luma = dot(curr, vec3(0.299, 0.587, 0.114));
                float baseCurrW = mix(0.18, 0.30, smoothstep(0.08, 0.55, luma));
                float currWeight = mix(baseCurrW, 1.0, smoothstep(0.025, 0.13, motion));
                gl_FragColor = vec4(mix(prev, curr, currWeight), 1.0);
            }
        """

        private const val FRAGMENT_MASK_REFINE = """
            $GLSL_HIGHP_HEADER
            uniform sampler2D uFgTex;
            uniform sampler2D uMaskTex;
            uniform vec2 uTexelSize;
            varying vec2 vTexCoord;
            void main() {
                vec3 centerColor = texture2D(uFgTex, vTexCoord).rgb;
                vec2 maskUv = vec2(vTexCoord.x, 1.0 - vTexCoord.y);
                float maskSum = 0.0;
                float wSum = 0.0;
                for (int x = -1; x <= 1; x++) {
                    for (int y = -1; y <= 1; y++) {
                        vec2 off = vec2(float(x), float(y)) * uTexelSize;
                        vec3 sampleColor = texture2D(uFgTex, vTexCoord + off).rgb;
                        float sampleMask = texture2D(uMaskTex, maskUv + vec2(off.x, -off.y)).r;
                        vec3 diff = sampleColor - centerColor;
                        float spatialW = exp(-float(x * x + y * y) * 0.4);
                        float rangeW = exp(-dot(diff, diff) * 28.0);
                        float w = spatialW * rangeW;
                        maskSum += sampleMask * w;
                        wSum += w;
                    }
                }
                float refined = maskSum / max(wSum, 0.0001);
                float alpha = smoothstep(0.32, 0.72, refined);
                gl_FragColor = vec4(alpha, alpha, alpha, 1.0);
            }
        """

        private const val FRAGMENT_BG_MASK_PREP = """
            precision mediump float;
            uniform sampler2D uFgTex;
            uniform sampler2D uMaskTex;
            uniform vec2 uSrcTexelSize;
            varying vec2 vTexCoord;
            void main() {
                vec2 d = uSrcTexelSize * 0.75;
                vec2 offsets[4];
                offsets[0] = vec2(-d.x, -d.y);
                offsets[1] = vec2( d.x, -d.y);
                offsets[2] = vec2(-d.x,  d.y);
                offsets[3] = vec2( d.x,  d.y);
                vec3 colorSum = vec3(0.0);
                float weightSum = 0.0;
                for (int i = 0; i < 4; i++) {
                    vec2 uv = clamp(vTexCoord + offsets[i], 0.0, 1.0);
                    vec3 c = texture2D(uFgTex, uv).rgb;
                    float bgW = 1.0 - texture2D(uMaskTex, uv).r;
                    colorSum += c * bgW;
                    weightSum += bgW;
                }
                gl_FragColor = vec4(colorSum * 0.25, weightSum * 0.25);
            }
        """

        private const val FRAGMENT_KAWASE_DOWN = """
            precision mediump float;
            uniform sampler2D uTex;
            uniform vec2 uHalfPixel;
            uniform float uOffset;
            varying vec2 vTexCoord;
            void main() {
                vec4 sum = texture2D(uTex, vTexCoord) * 4.0;
                sum += texture2D(uTex, vTexCoord - uHalfPixel * uOffset);
                sum += texture2D(uTex, vTexCoord + uHalfPixel * uOffset);
                sum += texture2D(uTex, vTexCoord + vec2(uHalfPixel.x, -uHalfPixel.y) * uOffset);
                sum += texture2D(uTex, vTexCoord - vec2(uHalfPixel.x, -uHalfPixel.y) * uOffset);
                gl_FragColor = sum / 8.0;
            }
        """

        private const val FRAGMENT_KAWASE_UP = """
            precision mediump float;
            uniform sampler2D uTex;
            uniform vec2 uHalfPixel;
            uniform float uOffset;
            varying vec2 vTexCoord;
            void main() {
                vec2 hp = uHalfPixel * uOffset;
                vec4 sum = texture2D(uTex, vTexCoord + vec2(-hp.x * 2.0, 0.0));
                sum += texture2D(uTex, vTexCoord + vec2(-hp.x, hp.y)) * 2.0;
                sum += texture2D(uTex, vTexCoord + vec2(0.0, hp.y * 2.0));
                sum += texture2D(uTex, vTexCoord + vec2(hp.x, hp.y)) * 2.0;
                sum += texture2D(uTex, vTexCoord + vec2(hp.x * 2.0, 0.0));
                sum += texture2D(uTex, vTexCoord + vec2(hp.x, -hp.y)) * 2.0;
                sum += texture2D(uTex, vTexCoord + vec2(0.0, -hp.y * 2.0));
                sum += texture2D(uTex, vTexCoord + vec2(-hp.x, -hp.y)) * 2.0;
                gl_FragColor = sum / 12.0;
            }
        """

        private const val FRAGMENT_COMPOSITE = """
            precision mediump float;
            uniform sampler2D uFgTex;
            uniform sampler2D uBgTex;
            uniform sampler2D uMaskTex;
            uniform vec4 uBgUvTransform; // xy = scale, zw = offset (cover fit)
            uniform float uBgPremul;
            varying vec2 vTexCoord;
            void main() {
                vec3 fg = texture2D(uFgTex, vTexCoord).rgb;
                vec2 bgUv = vTexCoord * uBgUvTransform.xy + uBgUvTransform.zw;
                vec4 bgSample = texture2D(uBgTex, clamp(bgUv, 0.0, 1.0));
                vec3 bg = bgSample.rgb;
                if (uBgPremul > 0.5) {
                    vec3 unpremul = bgSample.rgb / max(bgSample.a, 0.02);
                    bg = mix(fg, unpremul, smoothstep(0.0, 0.05, bgSample.a));
                }
                float alpha = texture2D(uMaskTex, vTexCoord).r;
                gl_FragColor = vec4(mix(bg, fg, alpha), 1.0);
            }
        """
    }

    private data class FboTex(
        val fbo: Int,
        val tex: Int,
        val width: Int,
        val height: Int
    )

    @Volatile
    private var sink: VideoSink? = null

    @Volatile
    private var effect: FaceTimeVideoEffect = FaceTimeVideoEffect.NONE

    @Volatile
    private var denoiseEnabled: Boolean = false

    @Volatile
    private var pendingBgPath: String? = null

    @Volatile
    private var bgDirty = false

    @Volatile
    private var released = false

    private var glThread: HandlerThread? = null
    private var glHandler: Handler? = null
    private var eglBase: EglBase? = null
    private var yuvConverter: YuvConverter? = null

    private var quadBuffer: FloatBuffer? = null
    private var passthroughOesProg = 0
    private var passthrough2dProg = 0
    private var bilateralOesProg = 0
    private var bilateral2dProg = 0
    private var temporalDenoiseProg = 0
    private var maskRefineProg = 0
    private var bgMaskPrepProg = 0
    private var kawaseDownProg = 0
    private var kawaseUpProg = 0
    private var compositeProg = 0
    private var programsReady = false

    private var workFbo: FboTex? = null
    private var denoiseSpatialFbo: FboTex? = null
    private var denoiseHistReadFbo: FboTex? = null
    private var denoiseHistWriteFbo: FboTex? = null
    private var hasDenoiseHistory = false
    private var maskRefinedFbo: FboTex? = null
    private var blurDown1: FboTex? = null
    private var blurDown2: FboTex? = null
    private var blurDown3: FboTex? = null
    private var blurUp2: FboTex? = null
    private var blurUp1: FboTex? = null
    private var maskFbo: FboTex? = null

    private val outputPool = ArrayBlockingQueue<FboTex>(OUTPUT_POOL_SIZE)
    private var poolWidth = 0
    private var poolHeight = 0

    // ML Kit segmentation state
    private val mlExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "bb-mlkit-seg").apply { isDaemon = true }
    }
    private val segmenterBusy = AtomicBoolean(false)
    private var segmenter: Segmenter? = null
    private var maskTexId = 0
    private var virtualBgTexId = 0
    private var virtualBgWidth = 0
    private var virtualBgHeight = 0
    private var emaMask: FloatArray? = null
    private var maskUploadBuf: ByteBuffer? = null
    private var readbackBuf: ByteBuffer? = null
    private var readbackBitmap: Bitmap? = null
    private var frameCounter = 0
    private var lastFrameProcessNs = 0L

    @Volatile
    private var latestMaskBytes: ByteArray? = null
    @Volatile
    private var latestMaskW = 0
    @Volatile
    private var latestMaskH = 0
    @Volatile
    private var maskTextureDirty = false

    fun updateConfig(effectName: String?, denoise: Boolean, backgroundPath: String?) {
        effect = FaceTimeVideoEffect.parse(effectName)
        denoiseEnabled = denoise
        if (backgroundPath != pendingBgPath) {
            pendingBgPath = backgroundPath
            bgDirty = true
        }
    }

    override fun setSink(sink: VideoSink?) {
        this.sink = sink
    }

    override fun onCapturerStarted(success: Boolean) {
        // VideoSink only consumes frames via onFrame(VideoFrame).
    }

    override fun onCapturerStopped() {
        // VideoSink only consumes frames via onFrame(VideoFrame).
    }

    override fun onFrameCaptured(frame: VideoFrame) {
        sink?.onFrame(frame)
    }

    override fun onFrameCaptured(frame: VideoFrame, parameters: VideoProcessor.FrameAdaptationParameters) {
        if (released) return
        val adapted = VideoProcessor.applyFrameAdaptationParameters(frame, parameters) ?: return
        val currentEffect = effect
        val currentDenoise = denoiseEnabled

        if (currentEffect == FaceTimeVideoEffect.NONE && !currentDenoise && adapted.rotation == 0) {
            sink?.onFrame(adapted)
            adapted.release()
            return
        }

        val buffer = adapted.buffer
        if (buffer !is VideoFrame.TextureBuffer) {
            sink?.onFrame(adapted)
            adapted.release()
            return
        }

        val handler = ensureGlThread() ?: run {
            adapted.release()
            return
        }
        var outputFrame: VideoFrame? = null
        try {
            ThreadUtils.invokeAtFrontUninterruptibly(handler) {
                outputFrame = processFrameOnGl(adapted, buffer, currentEffect, currentDenoise)
            }
        } catch (e: Exception) {
            PersistentLog.w(context, TAG, "GLES processing failed; falling back to passthrough: ${e.message}")
        }

        if (outputFrame == null && adapted.rotation != 0) {
            adapted.release()
            return
        }

        val toEmit = outputFrame ?: adapted
        sink?.onFrame(toEmit)
        if (outputFrame != null) {
            outputFrame?.release()
        }
        adapted.release()
    }

    fun release() {
        val handler: Handler?
        val thread: HandlerThread?
        synchronized(this) {
            if (released) return
            released = true
            handler = glHandler
            thread = glThread
            glThread = null
            glHandler = null
        }
        if (handler != null) {
            try {
                ThreadUtils.invokeAtFrontUninterruptibly(handler) {
                    cleanupGl()
                }
            } catch (_: Exception) {}
            thread?.quitSafely()
        }
        try {
            mlExecutor.execute {
                try {
                    segmenter?.close()
                } catch (_: Exception) {}
                segmenter = null
            }
            mlExecutor.shutdown()
        } catch (_: Exception) {}
    }

    private fun ensureGlThread(): Handler? {
        if (released) return null
        glHandler?.let { return it }
        synchronized(this) {
            if (released) return null
            glHandler?.let { return it }
            val thread = HandlerThread("bb-video-proc-gl").apply { start() }
            val handler = Handler(thread.looper)
            ThreadUtils.invokeAtFrontUninterruptibly(handler) {
                val egl = EglBase.create(sharedEglContext, EglBase.CONFIG_PLAIN)
                egl.createDummyPbufferSurface()
                egl.makeCurrent()
                eglBase = egl
                yuvConverter = YuvConverter()
                initPrograms()
            }
            glThread = thread
            glHandler = handler
            return handler
        }
    }

    private fun initPrograms() {
        quadBuffer = ByteBuffer.allocateDirect(FULLSCREEN_QUAD.size * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
            .apply {
                put(FULLSCREEN_QUAD)
                position(0)
            }

        passthroughOesProg = compileProgram(VERTEX_SHADER, FRAGMENT_PASSTHROUGH_OES)
        passthrough2dProg = compileProgram(VERTEX_SHADER, FRAGMENT_PASSTHROUGH_2D)
        bilateralOesProg = compileProgram(VERTEX_SHADER, FRAGMENT_BILATERAL_OES)
        bilateral2dProg = compileProgram(VERTEX_SHADER, FRAGMENT_BILATERAL_2D)
        temporalDenoiseProg = compileProgram(VERTEX_SHADER, FRAGMENT_TEMPORAL_DENOISE)
        maskRefineProg = compileProgram(VERTEX_SHADER, FRAGMENT_MASK_REFINE)
        bgMaskPrepProg = compileProgram(VERTEX_SHADER, FRAGMENT_BG_MASK_PREP)
        kawaseDownProg = compileProgram(VERTEX_SHADER, FRAGMENT_KAWASE_DOWN)
        kawaseUpProg = compileProgram(VERTEX_SHADER, FRAGMENT_KAWASE_UP)
        compositeProg = compileProgram(VERTEX_SHADER, FRAGMENT_COMPOSITE)
        programsReady = passthroughOesProg != 0 &&
            passthrough2dProg != 0 &&
            bilateralOesProg != 0 &&
            bilateral2dProg != 0 &&
            temporalDenoiseProg != 0 &&
            maskRefineProg != 0 &&
            bgMaskPrepProg != 0 &&
            kawaseDownProg != 0 &&
            kawaseUpProg != 0 &&
            compositeProg != 0
    }

    private fun processFrameOnGl(
        adapted: VideoFrame,
        texBuf: VideoFrame.TextureBuffer,
        currentEffect: FaceTimeVideoEffect,
        currentDenoise: Boolean
    ): VideoFrame? {
        if (!programsReady) return null
        val egl = eglBase ?: return null
        val converter = yuvConverter ?: return null
        val handler = glHandler ?: return null
        egl.makeCurrent()

        val srcW = texBuf.width
        val srcH = texBuf.height
        if (srcW <= 0 || srcH <= 0) return null

        // Bake sensor/device rotation into upright pixels (rotation=0) so RTP CVO stripping never leaves uplink sideways.
        val rot = ((adapted.rotation % 360) + 360) % 360
        val w = if (rot == 90 || rot == 270) srcH else srcW
        val h = if (rot == 90 || rot == 270) srcW else srcH

        val startNs = System.nanoTime()
        ensurePoolSize(w, h)
        val outSlot = outputPool.poll() ?: return null

        val isOes = texBuf.type == VideoFrame.TextureBuffer.Type.OES
        val rotatedMatrix = Matrix(texBuf.transformMatrix)
        if (rot != 0) {
            rotatedMatrix.preTranslate(0.5f, 0.5f)
            rotatedMatrix.preRotate(rot.toFloat())
            rotatedMatrix.preTranslate(-0.5f, -0.5f)
        }
        val texMatrix = RendererCommon.convertMatrixFromAndroidGraphicsMatrix(rotatedMatrix)

        if (currentEffect == FaceTimeVideoEffect.NONE && !currentDenoise) {
            // Rotation-bake passthrough directly to output slot
            val prog = if (isOes) passthroughOesProg else passthrough2dProg
            drawPass(
                fbo = outSlot.fbo,
                width = w,
                height = h,
                prog = prog,
                texTarget = if (isOes) GLES11Ext.GL_TEXTURE_EXTERNAL_OES else GLES20.GL_TEXTURE_2D,
                texId = texBuf.textureId,
                texMatrix = texMatrix
            ) {}
            hasDenoiseHistory = false
        } else {
            // Pass 1 (+ Pass 2 if denoise): spatial bilateral + temporal motion-aware denoise
            val fgTex = if (currentDenoise) {
                val spatial = ensureFbo(denoiseSpatialFbo, w, h).also { denoiseSpatialFbo = it }
                val spatialProg = if (isOes) bilateralOesProg else bilateral2dProg
                drawPass(
                    fbo = spatial.fbo,
                    width = w,
                    height = h,
                    prog = spatialProg,
                    texTarget = if (isOes) GLES11Ext.GL_TEXTURE_EXTERNAL_OES else GLES20.GL_TEXTURE_2D,
                    texId = texBuf.textureId,
                    texMatrix = texMatrix
                ) {
                    GLES20.glUniform2f(GLES20.glGetUniformLocation(spatialProg, "uTexelSize"), 1f / w, 1f / h)
                }

                val sizeChanged = denoiseHistReadFbo?.let { it.width != w || it.height != h } ?: true
                if (sizeChanged) hasDenoiseHistory = false
                val histRead = ensureFbo(denoiseHistReadFbo, w, h).also { denoiseHistReadFbo = it }
                val histWrite = ensureFbo(denoiseHistWriteFbo, w, h).also { denoiseHistWriteFbo = it }

                GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, histWrite.fbo)
                GLES20.glViewport(0, 0, w, h)
                GLES20.glUseProgram(temporalDenoiseProg)
                bindQuad(temporalDenoiseProg)
                GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(temporalDenoiseProg, "uTexMatrix"), 1, false, IDENTITY_MATRIX, 0)
                GLES20.glUniform2f(GLES20.glGetUniformLocation(temporalDenoiseProg, "uTexelSize"), 1f / w, 1f / h)
                GLES20.glUniform1f(GLES20.glGetUniformLocation(temporalDenoiseProg, "uHasHistory"), if (hasDenoiseHistory) 1f else 0f)

                GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, spatial.tex)
                GLES20.glUniform1i(GLES20.glGetUniformLocation(temporalDenoiseProg, "uTex"), 0)

                GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, histRead.tex)
                GLES20.glUniform1i(GLES20.glGetUniformLocation(temporalDenoiseProg, "uHistTex"), 1)

                GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
                GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)

                denoiseHistReadFbo = histWrite
                denoiseHistWriteFbo = histRead
                hasDenoiseHistory = true
                histWrite.tex
            } else {
                hasDenoiseHistory = false
                val work = ensureFbo(workFbo, w, h).also { workFbo = it }
                val pass1Prog = if (isOes) passthroughOesProg else passthrough2dProg
                drawPass(
                    fbo = work.fbo,
                    width = w,
                    height = h,
                    prog = pass1Prog,
                    texTarget = if (isOes) GLES11Ext.GL_TEXTURE_EXTERNAL_OES else GLES20.GL_TEXTURE_2D,
                    texId = texBuf.textureId,
                    texMatrix = texMatrix
                ) {}
                work.tex
            }

            if (currentEffect == FaceTimeVideoEffect.NONE) {
                drawPass(
                    fbo = outSlot.fbo,
                    width = w,
                    height = h,
                    prog = passthrough2dProg,
                    texTarget = GLES20.GL_TEXTURE_2D,
                    texId = fgTex,
                    texMatrix = IDENTITY_MATRIX
                ) {}
            } else {
                // Kick async segmentation (15Hz adaptive cadence if thermal/low-res)
                frameCounter++
                val lowCadence = lastFrameProcessNs > THERMAL_FRAME_BUDGET_NS || w * h <= 640 * 360
                if ((!lowCadence || frameCounter % 2 == 0) && segmenterBusy.compareAndSet(false, true)) {
                    dispatchSegmentation(fgTex, 0)
                }
                uploadPendingMaskIfAny()

                // Joint-bilateral mask refinement guided by full-res foreground edges
                val refinedMask = ensureFbo(maskRefinedFbo, w, h).also { maskRefinedFbo = it }
                GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, refinedMask.fbo)
                GLES20.glViewport(0, 0, w, h)
                GLES20.glUseProgram(maskRefineProg)
                bindQuad(maskRefineProg)
                GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(maskRefineProg, "uTexMatrix"), 1, false, IDENTITY_MATRIX, 0)
                GLES20.glUniform2f(GLES20.glGetUniformLocation(maskRefineProg, "uTexelSize"), 2f / w, 2f / h)
                GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, fgTex)
                GLES20.glUniform1i(GLES20.glGetUniformLocation(maskRefineProg, "uFgTex"), 0)
                GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTexId)
                GLES20.glUniform1i(GLES20.glGetUniformLocation(maskRefineProg, "uMaskTex"), 1)
                GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
                GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)

                val bgTex: Int
                var bgScaleX = 1f
                var bgScaleY = 1f
                var bgOffX = 0f
                var bgOffY = 0f
                var bgPremul = 0f

                if (currentEffect == FaceTimeVideoEffect.VIRTUAL_BACKGROUND) {
                    ensureVirtualBackgroundTexture()
                    bgTex = if (virtualBgTexId != 0) virtualBgTexId else fgTex
                    if (virtualBgTexId != 0 && virtualBgWidth > 0 && virtualBgHeight > 0) {
                        val frameAspect = w.toFloat() / h.toFloat()
                        val bgAspect = virtualBgWidth.toFloat() / virtualBgHeight.toFloat()
                        if (bgAspect > frameAspect) {
                            bgScaleX = frameAspect / bgAspect
                            bgOffX = (1f - bgScaleX) * 0.5f
                        } else {
                            bgScaleY = bgAspect / frameAspect
                            bgOffY = (1f - bgScaleY) * 0.5f
                        }
                        // GLUtils.texImage2D uploads top-down bitmap at GL v=0; flip Y for upright virtual background.
                        bgOffY = bgScaleY + bgOffY
                        bgScaleY = -bgScaleY
                    } else if (virtualBgTexId != 0) {
                        bgScaleY = -1f
                        bgOffY = 1f
                    }
                } else {
                    // 3-level ÷4 downsample background-only Dual-Kawase blur (premultiplied by 1 - alpha to prevent halos)
                    val offset = if (currentEffect == FaceTimeVideoEffect.BLUR_STRONG) 2.5f else 1.15f
                    val dw1 = (w / 4).coerceAtLeast(32)
                    val dh1 = (h / 4).coerceAtLeast(32)
                    val dw2 = (dw1 / 2).coerceAtLeast(16)
                    val dh2 = (dh1 / 2).coerceAtLeast(16)
                    val dw3 = (dw2 / 2).coerceAtLeast(8)
                    val dh3 = (dh2 / 2).coerceAtLeast(8)
                    val d1 = ensureFbo(blurDown1, dw1, dh1).also { blurDown1 = it }
                    val d2 = ensureFbo(blurDown2, dw2, dh2).also { blurDown2 = it }
                    val d3 = ensureFbo(blurDown3, dw3, dh3).also { blurDown3 = it }
                    val u2 = ensureFbo(blurUp2, dw2, dh2).also { blurUp2 = it }
                    val u1 = ensureFbo(blurUp1, dw1, dh1).also { blurUp1 = it }

                    GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, d1.fbo)
                    GLES20.glViewport(0, 0, dw1, dh1)
                    GLES20.glUseProgram(bgMaskPrepProg)
                    bindQuad(bgMaskPrepProg)
                    GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(bgMaskPrepProg, "uTexMatrix"), 1, false, IDENTITY_MATRIX, 0)
                    GLES20.glUniform2f(GLES20.glGetUniformLocation(bgMaskPrepProg, "uSrcTexelSize"), 1f / w, 1f / h)
                    GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
                    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, fgTex)
                    GLES20.glUniform1i(GLES20.glGetUniformLocation(bgMaskPrepProg, "uFgTex"), 0)
                    GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
                    GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, refinedMask.tex)
                    GLES20.glUniform1i(GLES20.glGetUniformLocation(bgMaskPrepProg, "uMaskTex"), 1)
                    GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
                    GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)

                    drawKawase(kawaseDownProg, d1.tex, d2, offset)
                    drawKawase(kawaseDownProg, d2.tex, d3, offset)
                    drawKawase(kawaseUpProg, d3.tex, u2, offset)
                    drawKawase(kawaseUpProg, u2.tex, u1, offset)
                    bgTex = u1.tex
                    bgPremul = 1f
                }

                // Composite foreground + background using edge-refined segmentation mask
                GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, outSlot.fbo)
                GLES20.glViewport(0, 0, w, h)
                GLES20.glUseProgram(compositeProg)
                bindQuad(compositeProg)
                GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(compositeProg, "uTexMatrix"), 1, false, IDENTITY_MATRIX, 0)
                GLES20.glUniform4f(GLES20.glGetUniformLocation(compositeProg, "uBgUvTransform"), bgScaleX, bgScaleY, bgOffX, bgOffY)
                GLES20.glUniform1f(GLES20.glGetUniformLocation(compositeProg, "uBgPremul"), bgPremul)

                GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, fgTex)
                GLES20.glUniform1i(GLES20.glGetUniformLocation(compositeProg, "uFgTex"), 0)

                GLES20.glActiveTexture(GLES20.GL_TEXTURE1)
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, bgTex)
                GLES20.glUniform1i(GLES20.glGetUniformLocation(compositeProg, "uBgTex"), 1)

                GLES20.glActiveTexture(GLES20.GL_TEXTURE2)
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, refinedMask.tex)
                GLES20.glUniform1i(GLES20.glGetUniformLocation(compositeProg, "uMaskTex"), 2)

                GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
                GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
            }
        }

        GLES20.glFinish()
        lastFrameProcessNs = System.nanoTime() - startNs

        val outBuffer = TextureBufferImpl(
            w,
            h,
            VideoFrame.TextureBuffer.Type.RGB,
            outSlot.tex,
            Matrix(),
            handler,
            converter
        ) {
            if (released) return@TextureBufferImpl
            if (outSlot.width == poolWidth && outSlot.height == poolHeight && outputPool.offer(outSlot)) {
                return@TextureBufferImpl
            }
            handler.post {
                try {
                    eglBase?.makeCurrent()
                    deleteFbo(outSlot)
                } catch (_: Exception) {}
            }
        }
        return VideoFrame(outBuffer, 0, adapted.timestampNs)
    }

    private fun dispatchSegmentation(sourceTex2d: Int, rotation: Int) {
        val mf = ensureFbo(maskFbo, MASK_INPUT_SIZE, MASK_INPUT_SIZE).also { maskFbo = it }
        drawPass(
            fbo = mf.fbo,
            width = MASK_INPUT_SIZE,
            height = MASK_INPUT_SIZE,
            prog = passthrough2dProg,
            texTarget = GLES20.GL_TEXTURE_2D,
            texId = sourceTex2d,
            texMatrix = Y_FLIP_MATRIX
        ) {}

        val buf = readbackBuf ?: ByteBuffer.allocateDirect(MASK_INPUT_SIZE * MASK_INPUT_SIZE * 4)
            .order(ByteOrder.nativeOrder())
            .also { readbackBuf = it }
        buf.rewind()
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, mf.fbo)
        GLES20.glReadPixels(0, 0, MASK_INPUT_SIZE, MASK_INPUT_SIZE, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, buf)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)

        val bmp = readbackBitmap ?: Bitmap.createBitmap(MASK_INPUT_SIZE, MASK_INPUT_SIZE, Bitmap.Config.ARGB_8888)
            .also { readbackBitmap = it }
        buf.rewind()
        bmp.copyPixelsFromBuffer(buf)

        mlExecutor.execute {
            if (released) {
                segmenterBusy.set(false)
                return@execute
            }
            try {
                val seg = segmenter ?: Segmentation.getClient(
                    SelfieSegmenterOptions.Builder()
                        .setDetectorMode(SelfieSegmenterOptions.STREAM_MODE)
                        .build()
                ).also { segmenter = it }

                val input = InputImage.fromBitmap(bmp, rotation)
                seg.process(input)
                    .addOnSuccessListener(mlExecutor) { mask ->
                        try {
                            val mw = mask.width
                            val mh = mask.height
                            val count = mw * mh
                            val fb = mask.buffer
                            fb.rewind()
                            val floatBuf = fb.asFloatBuffer()
                            val isFirstMask = emaMask == null || emaMask?.size != count
                            val ema = emaMask?.takeIf { it.size == count } ?: FloatArray(count).also { emaMask = it }
                            val outBytes = ByteArray(count)
                            for (i in 0 until count) {
                                val raw = floatBuf.get().coerceIn(0f, 1f)
                                val smoothed = if (isFirstMask) {
                                    raw
                                } else {
                                    val prev = ema[i]
                                    val delta = kotlin.math.abs(raw - prev)
                                    val t = ((delta - 0.05f) / 0.25f).coerceIn(0f, 1f)
                                    val alpha = MASK_EMA_ALPHA_MIN + t * (MASK_EMA_ALPHA_MAX - MASK_EMA_ALPHA_MIN)
                                    alpha * raw + (1f - alpha) * prev
                                }
                                ema[i] = smoothed
                                outBytes[i] = (smoothed * 255f).toInt().coerceIn(0, 255).toByte()
                            }
                            latestMaskW = mw
                            latestMaskH = mh
                            latestMaskBytes = outBytes
                            maskTextureDirty = true
                        } finally {
                            segmenterBusy.set(false)
                        }
                    }
                    .addOnFailureListener(mlExecutor) {
                        segmenterBusy.set(false)
                    }
            } catch (_: Exception) {
                segmenterBusy.set(false)
            }
        }
    }

    private fun uploadPendingMaskIfAny() {
        if (maskTexId == 0) {
            maskTexId = create2dTexture(1, 1)
            val defaultMask = ByteBuffer.allocateDirect(1).put(255.toByte()).apply { rewind() }
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTexId)
            GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_LUMINANCE, 1, 1, 0, GLES20.GL_LUMINANCE, GLES20.GL_UNSIGNED_BYTE, defaultMask)
        }
        if (!maskTextureDirty) return
        val bytes = latestMaskBytes ?: return
        val mw = latestMaskW
        val mh = latestMaskH
        if (mw <= 0 || mh <= 0 || bytes.size != mw * mh) return

        val uploadBuf = maskUploadBuf?.takeIf { it.capacity() == bytes.size }
            ?: ByteBuffer.allocateDirect(bytes.size).also { maskUploadBuf = it }
        uploadBuf.rewind()
        uploadBuf.put(bytes)
        uploadBuf.rewind()

        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, maskTexId)
        GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1)
        GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_LUMINANCE, mw, mh, 0, GLES20.GL_LUMINANCE, GLES20.GL_UNSIGNED_BYTE, uploadBuf)
        maskTextureDirty = false
    }

    private fun ensureVirtualBackgroundTexture() {
        if (!bgDirty && virtualBgTexId != 0) return
        bgDirty = false
        val path = pendingBgPath
        val bmp = loadBackgroundBitmap(path)
        if (virtualBgTexId == 0) {
            virtualBgTexId = create2dTexture(bmp.width, bmp.height)
        }
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, virtualBgTexId)
        GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bmp, 0)
        virtualBgWidth = bmp.width
        virtualBgHeight = bmp.height
        bmp.recycle()
    }

    private fun loadBackgroundBitmap(pathOrPreset: String?): Bitmap {
        if (!pathOrPreset.isNullOrBlank()) {
            val file = File(pathOrPreset)
            if (file.exists() && file.isFile) {
                BitmapFactory.decodeFile(file.absolutePath)?.let { return it }
            }
        }
        // Built-in gradient presets (matches FaceTimeBackgroundPreset ids)
        val (c1, c2) = when (pathOrPreset?.lowercase()) {
            "gradient_dusk", "dusk" -> 0xFF1A237E.toInt() to 0xFF4A148C.toInt()
            "gradient_ocean", "ocean", "ocean_calm" -> 0xFF0D47A1.toInt() to 0xFF00695C.toInt()
            "studio_warm", "warm" -> 0xFF3E2723.toInt() to 0xFF212121.toInt()
            "slate_minimal" -> 0xFF20252C.toInt() to 0xFF333B46.toInt()
            else -> 0xFF131314.toInt() to 0xFF282A2C.toInt()
        }
        val bmp = Bitmap.createBitmap(256, 256, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val paint = Paint().apply {
            shader = LinearGradient(0f, 0f, 256f, 256f, c1, c2, Shader.TileMode.CLAMP)
        }
        canvas.drawRect(0f, 0f, 256f, 256f, paint)
        return bmp
    }

    private fun drawKawase(prog: Int, srcTex: Int, dst: FboTex, offset: Float) {
        drawPass(
            fbo = dst.fbo,
            width = dst.width,
            height = dst.height,
            prog = prog,
            texTarget = GLES20.GL_TEXTURE_2D,
            texId = srcTex,
            texMatrix = IDENTITY_MATRIX
        ) {
            GLES20.glUniform2f(GLES20.glGetUniformLocation(prog, "uHalfPixel"), 0.5f / dst.width, 0.5f / dst.height)
            GLES20.glUniform1f(GLES20.glGetUniformLocation(prog, "uOffset"), offset)
        }
    }

    private inline fun drawPass(
        fbo: Int,
        width: Int,
        height: Int,
        prog: Int,
        texTarget: Int,
        texId: Int,
        texMatrix: FloatArray,
        uniforms: () -> Unit
    ) {
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo)
        GLES20.glViewport(0, 0, width, height)
        GLES20.glUseProgram(prog)
        bindQuad(prog)
        GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(prog, "uTexMatrix"), 1, false, texMatrix, 0)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(texTarget, texId)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(prog, "uTex"), 0)
        uniforms()
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
    }

    private fun bindQuad(prog: Int) {
        val qb = quadBuffer ?: return
        val posLoc = GLES20.glGetAttribLocation(prog, "aPos")
        val texLoc = GLES20.glGetAttribLocation(prog, "aTexCoord")
        qb.position(0)
        GLES20.glEnableVertexAttribArray(posLoc)
        GLES20.glVertexAttribPointer(posLoc, 2, GLES20.GL_FLOAT, false, 16, qb)
        qb.position(2)
        GLES20.glEnableVertexAttribArray(texLoc)
        GLES20.glVertexAttribPointer(texLoc, 2, GLES20.GL_FLOAT, false, 16, qb)
    }

    private fun ensurePoolSize(w: Int, h: Int) {
        if (poolWidth == w && poolHeight == h) return
        while (true) {
            val old = outputPool.poll() ?: break
            deleteFbo(old)
        }
        poolWidth = w
        poolHeight = h
        repeat(OUTPUT_POOL_SIZE) {
            outputPool.offer(createFbo(w, h))
        }
    }

    private fun ensureFbo(existing: FboTex?, w: Int, h: Int): FboTex {
        if (existing != null && existing.width == w && existing.height == h) return existing
        if (existing != null) deleteFbo(existing)
        return createFbo(w, h)
    }

    private fun createFbo(w: Int, h: Int): FboTex {
        val tex = create2dTexture(w, h)
        GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, w, h, 0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null)
        val fbos = IntArray(1)
        GLES20.glGenFramebuffers(1, fbos, 0)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbos[0])
        GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, tex, 0)
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        return FboTex(fbos[0], tex, w, h)
    }

    private fun deleteFbo(fboTex: FboTex) {
        GLES20.glDeleteFramebuffers(1, intArrayOf(fboTex.fbo), 0)
        GLES20.glDeleteTextures(1, intArrayOf(fboTex.tex), 0)
    }

    private fun create2dTexture(w: Int, h: Int): Int {
        val texs = IntArray(1)
        GLES20.glGenTextures(1, texs, 0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texs[0])
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        return texs[0]
    }

    private fun compileProgram(vsSrc: String, fsSrc: String): Int {
        val vs = compileShader(GLES20.GL_VERTEX_SHADER, vsSrc)
        val fs = compileShader(GLES20.GL_FRAGMENT_SHADER, fsSrc)
        if (vs == 0 || fs == 0) {
            if (vs != 0) GLES20.glDeleteShader(vs)
            if (fs != 0) GLES20.glDeleteShader(fs)
            return 0
        }
        val prog = GLES20.glCreateProgram()
        GLES20.glAttachShader(prog, vs)
        GLES20.glAttachShader(prog, fs)
        GLES20.glLinkProgram(prog)
        GLES20.glDeleteShader(vs)
        GLES20.glDeleteShader(fs)
        val status = IntArray(1)
        GLES20.glGetProgramiv(prog, GLES20.GL_LINK_STATUS, status, 0)
        if (status[0] == 0) {
            PersistentLog.w(context, TAG, "GLES program link failed: ${GLES20.glGetProgramInfoLog(prog)}")
            GLES20.glDeleteProgram(prog)
            return 0
        }
        return prog
    }

    private fun compileShader(type: Int, src: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, src)
        GLES20.glCompileShader(shader)
        val status = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            PersistentLog.w(context, TAG, "GLES shader compile failed ($type): ${GLES20.glGetShaderInfoLog(shader)}")
            GLES20.glDeleteShader(shader)
            return 0
        }
        return shader
    }

    private fun cleanupGl() {
        try {
            eglBase?.makeCurrent()
            workFbo?.let(::deleteFbo); workFbo = null
            denoiseSpatialFbo?.let(::deleteFbo); denoiseSpatialFbo = null
            denoiseHistReadFbo?.let(::deleteFbo); denoiseHistReadFbo = null
            denoiseHistWriteFbo?.let(::deleteFbo); denoiseHistWriteFbo = null
            hasDenoiseHistory = false
            maskRefinedFbo?.let(::deleteFbo); maskRefinedFbo = null
            blurDown1?.let(::deleteFbo); blurDown1 = null
            blurDown2?.let(::deleteFbo); blurDown2 = null
            blurDown3?.let(::deleteFbo); blurDown3 = null
            blurUp2?.let(::deleteFbo); blurUp2 = null
            blurUp1?.let(::deleteFbo); blurUp1 = null
            maskFbo?.let(::deleteFbo); maskFbo = null
            while (true) {
                val slot = outputPool.poll() ?: break
                deleteFbo(slot)
            }
            if (maskTexId != 0) {
                GLES20.glDeleteTextures(1, intArrayOf(maskTexId), 0)
                maskTexId = 0
            }
            if (virtualBgTexId != 0) {
                GLES20.glDeleteTextures(1, intArrayOf(virtualBgTexId), 0)
                virtualBgTexId = 0
            }
            listOf(
                passthroughOesProg, passthrough2dProg, bilateralOesProg,
                bilateral2dProg, temporalDenoiseProg, maskRefineProg, bgMaskPrepProg,
                kawaseDownProg, kawaseUpProg, compositeProg
            ).filter { it != 0 }.forEach { GLES20.glDeleteProgram(it) }
            yuvConverter?.release()
            yuvConverter = null
            eglBase?.release()
            eglBase = null
        } catch (_: Exception) {}
    }
}

private val IDENTITY_MATRIX = floatArrayOf(
    1f, 0f, 0f, 0f,
    0f, 1f, 0f, 0f,
    0f, 0f, 1f, 0f,
    0f, 0f, 0f, 1f
)

private val Y_FLIP_MATRIX = floatArrayOf(
    1f,  0f, 0f, 0f,
    0f, -1f, 0f, 0f,
    0f,  0f, 1f, 0f,
    0f,  1f, 0f, 1f
)
