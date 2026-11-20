package com.bluebubbles.messaging.services.system

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.SoundPool
import android.util.Log
import com.bluebubbles.messaging.R
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Low-latency Android UI sound player for message send/receive and voice recording chimes.
 * Uses SoundPool (with MediaPlayer fallback for oversized custom files) instead of audio_waveforms
 * PlayerController so UI chimes do not allocate ExoPlayer/WaveformExtractor or disrupt RecorderController.
 */
object AppSoundPlayer {
    const val tag = "play-app-sound"
    private const val LOG_TAG = "AppSoundPlayer"

    private data class PendingPlay(val volume: Float, val result: MethodChannel.Result?)

    private val rawAssetMap = mapOf(
        "assets/sounds/message_sent.wav" to R.raw.message_sent_v2,
        "assets/sounds/message_incoming.wav" to R.raw.message_incoming,
        "assets/sounds/recording_start_audio.wav" to R.raw.recording_start_audio,
        "assets/sounds/recording_stop_audio.wav" to R.raw.recording_stop_audio,
    )

    private val lock = Any()
    private var soundPool: SoundPool? = null
    private val rawSoundIds = HashMap<Int, Int>()
    private val customSoundIds = HashMap<String, Int>()
    private val loadedSoundIds = HashSet<Int>()
    private val pendingPlays = HashMap<Int, MutableList<PendingPlay>>()
    private val pendingCustomPaths = HashMap<Int, String>()

    private fun getOrCreatePoolLocked(context: Context): SoundPool {
        soundPool?.let { return it }
        // USAGE_MEDIA + CONTENT_TYPE_SONIFICATION avoids stealing audio focus and matches ExoPlayer stream behavior in vibrate mode.
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        val pool = SoundPool.Builder()
            .setMaxStreams(4)
            .setAudioAttributes(attrs)
            .build()
        pool.setOnLoadCompleteListener { sp, sampleId, status ->
            val queued: List<PendingPlay>?
            val customPath: String?
            synchronized(lock) {
                queued = pendingPlays.remove(sampleId)
                customPath = pendingCustomPaths.remove(sampleId)
                if (status == 0) {
                    loadedSoundIds.add(sampleId)
                } else {
                    loadedSoundIds.remove(sampleId)
                    customSoundIds.entries.removeIf { it.value == sampleId }
                    rawSoundIds.entries.removeIf { it.value == sampleId }
                }
            }
            if (status == 0) {
                queued?.forEach { req ->
                    val streamId = sp.play(sampleId, req.volume, req.volume, 1, 0, 1.0f)
                    if (streamId == 0 && customPath != null) {
                        req.result?.success(playWithMediaPlayer(customPath, req.volume))
                    } else {
                        req.result?.success(streamId != 0)
                    }
                }
            } else {
                Log.w(LOG_TAG, "SoundPool failed to load sampleId=$sampleId status=$status")
                try {
                    sp.unload(sampleId)
                } catch (_: Throwable) {
                }
                if (customPath != null) {
                    queued?.forEach { req ->
                        req.result?.success(playWithMediaPlayer(customPath, req.volume))
                    }
                } else {
                    queued?.forEach { it.result?.success(false) }
                }
            }
        }
        val appCtx = context.applicationContext
        for ((_, resId) in rawAssetMap) {
            if (!rawSoundIds.containsKey(resId)) {
                val id = pool.load(appCtx, resId, 1)
                if (id != 0) rawSoundIds[resId] = id
            }
        }
        soundPool = pool
        return pool
    }

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result, context: Context) {
        val assetPath = call.argument<String>("assetPath")
        val customPath = call.argument<String>("customPath")?.takeIf { it.isNotBlank() }
        val rawVolume = call.argument<Number>("volume")?.toFloat() ?: 1.0f
        val volume = rawVolume.coerceIn(0.0f, 1.0f)
        if (volume <= 0.0f) {
            result.success(true)
            return
        }

        val appCtx = context.applicationContext
        val pool: SoundPool
        val soundId: Int
        val fallbackPath: String?
        val readyToPlay: Boolean

        synchronized(lock) {
            pool = getOrCreatePoolLocked(appCtx)

            var resolvedId: Int? = null
            var resolvedFallback: String? = null

            if (customPath != null) {
                val file = File(customPath)
                if (!file.exists()) {
                    Log.w(LOG_TAG, "Custom sound missing at $customPath, falling back to bundled asset")
                } else {
                    val cacheKey = "${file.absolutePath}:${file.lastModified()}:${file.length()}"
                    val existingId = customSoundIds[cacheKey]
                    if (existingId != null) {
                        resolvedId = existingId
                        resolvedFallback = file.absolutePath
                    } else {
                        val loadedId = pool.load(file.absolutePath, 1)
                        if (loadedId == 0) {
                            resolvedId = 0
                            resolvedFallback = file.absolutePath
                        } else {
                            customSoundIds[cacheKey] = loadedId
                            pendingCustomPaths[loadedId] = file.absolutePath
                            resolvedId = loadedId
                            resolvedFallback = file.absolutePath
                        }
                    }
                }
            }

            if (resolvedId == null) {
                val resId = rawAssetMap[assetPath]
                if (resId == null) {
                    Log.w(LOG_TAG, "Unknown sound assetPath=$assetPath")
                    result.success(false)
                    return
                }
                val id = rawSoundIds[resId] ?: pool.load(appCtx, resId, 1).also {
                    if (it != 0) rawSoundIds[resId] = it
                }
                if (id == 0) {
                    result.success(false)
                    return
                }
                resolvedId = id
            }

            soundId = resolvedId
            fallbackPath = resolvedFallback

            if (soundId == 0) {
                readyToPlay = false
            } else if (loadedSoundIds.contains(soundId)) {
                readyToPlay = true
            } else {
                readyToPlay = false
                pendingPlays.getOrPut(soundId) { mutableListOf() }.add(PendingPlay(volume, result))
                if (fallbackPath != null && !pendingCustomPaths.containsKey(soundId)) {
                    pendingCustomPaths[soundId] = fallbackPath
                }
            }
        }

        if (soundId == 0 && fallbackPath != null) {
            result.success(playWithMediaPlayer(fallbackPath, volume))
            return
        }
        if (readyToPlay) {
            val streamId = pool.play(soundId, volume, volume, 1, 0, 1.0f)
            if (streamId == 0 && fallbackPath != null) {
                result.success(playWithMediaPlayer(fallbackPath, volume))
            } else {
                result.success(streamId != 0)
            }
        }
    }

    private fun playWithMediaPlayer(path: String, volume: Float): Boolean {
        return try {
            val mp = MediaPlayer()
            mp.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            mp.setDataSource(path)
            mp.setVolume(volume, volume)
            mp.setOnPreparedListener { it.start() }
            mp.setOnCompletionListener { it.release() }
            mp.setOnErrorListener { player, _, _ ->
                player.release()
                true
            }
            mp.prepareAsync()
            true
        } catch (e: Throwable) {
            Log.w(LOG_TAG, "MediaPlayer fallback failed for $path", e)
            false
        }
    }
}
