package com.bluebubbles.messaging.services.notifications

import android.content.ComponentName
import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.util.Log
import com.bluebubbles.messaging.Constants
import com.bluebubbles.messaging.services.backend_ui_interop.MethodCallHandler
import com.bluebubbles.messaging.utils.PersistentLog

import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/// Class used to listen for media notifications and fetch album art to update app theming
class NotificationListener: NotificationListenerService() {
    companion object {
        private val initLock = Any()
        @Volatile private var hasInit: Boolean = false

        fun init(context: Context) {
            if (hasInit) return
            synchronized(initLock) {
                if (hasInit) return
                val manager: MediaSessionManager = context.getSystemService(MediaSessionManager::class.java)
                val sessionListener = MediaSessionListener()
                sessionListener.init(context)
                manager.addOnActiveSessionsChangedListener(sessionListener, ComponentName(context, this::class.java))
                hasInit = true
            }
        }
    }
}

class MediaSessionListener: MediaSessionManager.OnActiveSessionsChangedListener {
    companion object {
        val callback = MediaControllerCallback()
        var oldControllers: MutableList<MediaController> = mutableListOf()
    }

    // Retained so onActiveSessionsChanged (an interface callback with no Context
    // parameter of its own) can still persist log entries.
    private var appContext: Context? = null

    fun init(context: Context) {
        appContext = context.applicationContext
        PersistentLog.d(context, Constants.logTag, "Initializing media session listener...")
        val manager: MediaSessionManager = context.getSystemService(MediaSessionManager::class.java)
        val controllers = manager.getActiveSessions(ComponentName(context, NotificationListener::class.java))
        onActiveSessionsChanged(controllers)
    }

    @Synchronized
    override fun onActiveSessionsChanged(controllers: MutableList<MediaController>?) {
        for (controller in oldControllers) {
            controller.unregisterCallback(callback)
        }
        if (controllers.isNullOrEmpty()) {
            oldControllers.clear()
            return
        }

        appContext?.let { PersistentLog.d(it, Constants.logTag, "Media session changed, unregistering and re-registering callbacks...") }
        oldControllers = controllers.toMutableList()
        for (controller in oldControllers) {
            controller.registerCallback(callback)
        }
    }
}

class MediaControllerCallback: MediaController.Callback() {
    companion object {
        internal const val MAX_ALBUM_ART_PX = 256
        private val artExecutor = Executors.newSingleThreadExecutor { r ->
            Thread(r, "MediaArtScaler").apply { isDaemon = true }
        }
        private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

        internal fun computeScaledDimensions(
            width: Int,
            height: Int,
            maxSize: Int = MAX_ALBUM_ART_PX
        ): Pair<Int, Int> {
            if (width <= 0 || height <= 0 || maxSize <= 0) return 0 to 0
            if (width <= maxSize && height <= maxSize) return width to height
            return if (width >= height) {
                val scaledHeight = ((height.toFloat() / width.toFloat()) * maxSize).toInt().coerceAtLeast(1)
                maxSize to scaledHeight
            } else {
                val scaledWidth = ((width.toFloat() / height.toFloat()) * maxSize).toInt().coerceAtLeast(1)
                scaledWidth to maxSize
            }
        }
    }

    override fun onMetadataChanged(metadata: MediaMetadata?) {
        super.onMetadataChanged(metadata)
        if (metadata == null) return
        Log.d(Constants.logTag, "Media metadata changed (new track ${metadata.getString(MediaMetadata.METADATA_KEY_TITLE)})")
        val art = metadata.getBitmap(MediaMetadata.METADATA_KEY_ART)
        val albumArt = metadata.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART)
        val source = art ?: albumArt

        if (source != null && !source.isRecycled) {
            artExecutor.execute {
                try {
                    if (source.isRecycled) return@execute
                    val (targetW, targetH) = computeScaledDimensions(source.width, source.height)
                    if (targetW <= 0 || targetH <= 0) return@execute
                    val scaled = if (targetW == source.width && targetH == source.height) {
                        source
                    } else {
                        Bitmap.createScaledBitmap(source, targetW, targetH, true)
                    }
                    val byteArray = try {
                        ByteArrayOutputStream().use { stream ->
                            scaled.compress(Bitmap.CompressFormat.PNG, 100, stream)
                            stream.toByteArray()
                        }
                    } finally {
                        if (scaled !== source && !scaled.isRecycled) {
                            scaled.recycle()
                        }
                    }
                    mainHandler.post {
                        Log.d(Constants.logTag, "Sending album art to Dart")
                        MethodCallHandler.invokeMethod("MediaColors", hashMapOf("albumArt" to byteArray))
                    }
                } catch (e: Exception) {
                    Log.w(Constants.logTag, "Failed to process album art", e)
                }
            }
        }
    }
}