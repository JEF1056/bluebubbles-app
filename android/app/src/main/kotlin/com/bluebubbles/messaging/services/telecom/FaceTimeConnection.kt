package com.bluebubbles.messaging.services.telecom

import android.Manifest
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.OutcomeReceiver
import android.telecom.CallAudioState
import android.telecom.CallEndpoint
import android.telecom.CallEndpointException
import android.telecom.Connection
import android.telecom.DisconnectCause
import android.telecom.TelecomManager
import androidx.core.content.ContextCompat
import com.bluebubbles.messaging.services.network.HttpService
import com.bluebubbles.messaging.services.notifications.CreateIncomingFaceTimeNotification
import com.bluebubbles.messaging.services.notifications.NotificationChannelHandler
import com.bluebubbles.messaging.services.wear.WearSyncManager
import com.bluebubbles.messaging.utils.PersistentLog
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class FaceTimeConnection(
    private val context: Context,
    @Volatile var callUuid: String?,
    @Volatile var isTelephony: Boolean = false,
    @Volatile var isVideo: Boolean = false,
    @Volatile var isGroup: Boolean = false,
    @Volatile var callerAddress: String? = null,
    @Volatile var callerAvatar: ByteArray? = null
) : Connection() {

    companion object {
        private const val TAG = "FaceTimeConnection"
        private const val RINGING_TIMEOUT_MS = CreateIncomingFaceTimeNotification.INCOMING_CALL_TIMEOUT_MS
        private val DTMF_DIGIT_REGEX = Regex("^[0-9*#ABCD]$")
        private val audioExecutor = Executors.newSingleThreadExecutor()

        internal fun buildCallStatePayload(
            phase: String,
            uuid: String,
            isTelephony: Boolean,
            isVideo: Boolean,
            callerName: String? = null,
            muted: Boolean? = null
        ): HashMap<String, Any> = HashMap<String, Any>(6).apply {
            put("phase", phase)
            put("call_uuid", uuid)
            put("is_telephony", isTelephony)
            put("is_video", isVideo && !isTelephony)
            callerName?.takeIf { it.isNotBlank() }?.let { put("caller_name", it) }
            if (muted != null) put("muted", muted)
        }

        internal fun normalizeDtmfDigit(c: Char): String? {
            val digit = c.uppercaseChar().toString()
            return digit.takeIf { DTMF_DIGIT_REGEX.matches(it) }
        }

        internal data class WatchAudioCandidate<T>(
            val value: T,
            val name: String?,
            val address: String? = null,
            val isBluetooth: Boolean = true
        )

        internal fun <T> selectWatchAudioCandidate(
            candidates: List<WatchAudioCandidate<T>>,
            watchNodeNames: Set<String>,
            bondedWatchAddresses: Set<String> = emptySet(),
            bondedWatchNames: Set<String> = emptySet()
        ): T? {
            val btCandidates = candidates.filter { it.isBluetooth }
            if (btCandidates.isEmpty()) return null

            val normalizedNodeNames = watchNodeNames.map { it.trim().lowercase() }.filter { it.isNotEmpty() }
            if (normalizedNodeNames.isNotEmpty()) {
                btCandidates.firstOrNull { c ->
                    val name = c.name?.trim()?.lowercase() ?: return@firstOrNull false
                    normalizedNodeNames.any { it == name }
                }?.let { return it.value }

                btCandidates.firstOrNull { c ->
                    val name = c.name?.trim()?.lowercase() ?: return@firstOrNull false
                    normalizedNodeNames.any { node -> name.contains(node) || node.contains(name) }
                }?.let { return it.value }
            }

            val normalizedAddrs = bondedWatchAddresses.map { it.trim().lowercase() }.filter { it.isNotEmpty() }.toSet()
            if (normalizedAddrs.isNotEmpty()) {
                btCandidates.firstOrNull { c ->
                    val addr = c.address?.trim()?.lowercase() ?: return@firstOrNull false
                    addr in normalizedAddrs
                }?.let { return it.value }
            }

            val normalizedBondedNames = bondedWatchNames.map { it.trim().lowercase() }.filter { it.isNotEmpty() }
            if (normalizedBondedNames.isNotEmpty()) {
                btCandidates.firstOrNull { c ->
                    val name = c.name?.trim()?.lowercase() ?: return@firstOrNull false
                    normalizedBondedNames.any { it == name || name.contains(it) || it.contains(name) }
                }?.let { return it.value }
            }

            return btCandidates.firstOrNull { c ->
                c.name?.contains("watch", ignoreCase = true) == true
            }?.value
        }

        internal fun selectWatchBluetoothDevice(
            devices: Collection<BluetoothDevice>,
            watchNodeNames: Set<String>,
            bondedWatchAddresses: Set<String> = emptySet(),
            bondedWatchNames: Set<String> = emptySet(),
            nameProvider: (BluetoothDevice) -> String? = { dev ->
                try {
                    dev.name
                } catch (_: SecurityException) {
                    null
                }
            }
        ): BluetoothDevice? {
            val candidates = devices.map { dev ->
                WatchAudioCandidate(
                    value = dev,
                    name = nameProvider(dev),
                    address = dev.address,
                    isBluetooth = true
                )
            }
            return selectWatchAudioCandidate(candidates, watchNodeNames, bondedWatchAddresses, bondedWatchNames)
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val ringingTimeoutRunnable = Runnable {
        if (!ended.get() && state == STATE_RINGING) {
            PersistentLog.w(context, TAG, "Ringing timeout for $callUuid")
            onRemoteDisconnect()
        }
    }

    private val ended = AtomicBoolean(false)
    private val audioBridgeLock = Any()
    val isEnded: Boolean
        get() = ended.get()

    @Volatile
    private var webRtcClient: WebRtcAudioClient? = null

    @Volatile
    private var lastMuted: Boolean? = null

    @Volatile
    private var lastSpeaker: Boolean? = null

    @Volatile
    private var startedAtMs: Long = 0L

    @Volatile
    private var remoteVideoTextureId: Long? = null

    @Volatile
    private var localVideoTextureId: Long? = null

    @Volatile
    private var answeredFromWatch: Boolean = false

    @Volatile
    private var watchAudioRouteRequested: Boolean = false

    @Volatile
    private var latestCallEndpoints: List<CallEndpoint> = emptyList()

    private val toneToken: String = callUuid ?: "conn-${System.identityHashCode(this)}"

    private val audioRouteManager: FaceTimeAudioRouteManager by lazy {
        FaceTimeAudioRouteManager(
            context = context.applicationContext,
            setTelecomRoute = { route ->
                @Suppress("DEPRECATION")
                setAudioRoute(route)
            },
            requestTelecomBluetooth = { btDev ->
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    @Suppress("DEPRECATION")
                    requestBluetoothAudio(btDev)
                } else {
                    @Suppress("DEPRECATION")
                    setAudioRoute(CallAudioState.ROUTE_BLUETOOTH)
                }
            },
            getCallAudioState = {
                @Suppress("DEPRECATION")
                callAudioState
            },
            setPreferredInputDevice = { dev ->
                webRtcClient?.setPreferredInputDevice(dev)
            },
            onDevicesChanged = { payload ->
                callUuid?.let { emitAudioDevices(it, payload) }
            }
        )
    }

    fun getRemoteVideoTextureId(): Long? = webRtcClient?.getRemoteVideoTextureId() ?: remoteVideoTextureId

    fun getLocalVideoTextureId(): Long? = webRtcClient?.getLocalVideoTextureId() ?: localVideoTextureId

    fun getRemoteVideoWidth(): Int = webRtcClient?.getRemoteVideoWidth() ?: 0

    fun getRemoteVideoHeight(): Int = webRtcClient?.getRemoteVideoHeight() ?: 0

    fun getLocalVideoWidth(): Int = webRtcClient?.getLocalVideoWidth() ?: 0

    fun getLocalVideoHeight(): Int = webRtcClient?.getLocalVideoHeight() ?: 0

    fun bindCallUuid(uuid: String) {
        callUuid = uuid
        FaceTimeConnectionService.registerActiveConnection(uuid, this)
        if (!ended.get() && state == STATE_DIALING) {
            emitCallState("dialing", uuid)
        }
    }

    fun isMuted(): Boolean = lastMuted ?: (callAudioState?.isMuted == true)

    private fun ensureStartedAtMs(): Long {
        if (startedAtMs == 0L) {
            startedAtMs = System.currentTimeMillis()
        }
        return startedAtMs
    }

    internal fun startOrUpdateOngoingNotification(isStart: Boolean = false, speakerOverride: Boolean? = null) {
        val uuid = callUuid ?: return
        if (ended.get()) return
        val started = ensureStartedAtMs()
        val resolvedAddress = callerAddress?.takeIf { it.isNotBlank() }
            ?: address?.schemeSpecificPart?.takeIf { it.isNotBlank() }
        val effectiveVideo = isVideo && !isTelephony
        val kindLabel = FaceTimeCallForegroundService.callKindLabel(
            isVideo = effectiveVideo,
            isTelephony = isTelephony,
            isGroup = isGroup
        )
        val callerName = callerDisplayName?.toString()?.takeIf { it.isNotBlank() }
            ?: resolvedAddress
            ?: kindLabel
        val muted = isMuted()
        val speaker = speakerOverride ?: isSpeakerphoneOn()
        lastSpeaker = speaker
        if (isStart) {
            FaceTimeCallForegroundService.start(
                context = context,
                callUuid = uuid,
                callerName = callerName,
                isVideo = effectiveVideo,
                startedAtMs = started,
                muted = muted,
                speaker = speaker,
                isTelephony = isTelephony,
                isGroup = isGroup,
                callerAddress = resolvedAddress,
                callerAvatar = callerAvatar
            )
        } else {
            FaceTimeCallForegroundService.update(
                context = context,
                callUuid = uuid,
                callerName = callerName,
                isVideo = effectiveVideo,
                startedAtMs = started,
                muted = muted,
                speaker = speaker,
                isTelephony = isTelephony,
                isGroup = isGroup,
                callerAddress = resolvedAddress,
                callerAvatar = callerAvatar
            )
        }
        com.bluebubbles.messaging.services.wear.WearSyncManager.notifyCallActive(
            context = context,
            callUuid = uuid,
            startedAtMs = started,
            muted = muted,
            callerName = callerName,
            callerAddress = resolvedAddress,
            isVideo = effectiveVideo,
            isTelephony = isTelephony,
            isGroup = isGroup
        )
    }

    fun updateCallerInfo(
        callerName: String? = null,
        callerAddress: String? = null,
        callerAvatar: ByteArray? = null,
        isVideo: Boolean? = null,
        isGroup: Boolean? = null,
        isTelephony: Boolean? = null
    ) {
        if (ended.get()) return
        if (!callerName.isNullOrBlank()) {
            setCallerDisplayName(callerName, TelecomManager.PRESENTATION_ALLOWED)
        }
        if (!callerAddress.isNullOrBlank()) {
            this.callerAddress = callerAddress
        }
        if (callerAvatar != null && callerAvatar.isNotEmpty()) {
            this.callerAvatar = callerAvatar
        }
        if (isVideo != null) {
            this.isVideo = isVideo
        }
        if (isGroup != null) {
            this.isGroup = isGroup
        }
        if (isTelephony != null) {
            this.isTelephony = isTelephony
        }
        if (state == STATE_ACTIVE || startedAtMs != 0L) {
            startOrUpdateOngoingNotification(isStart = startedAtMs == 0L)
        }
    }

    internal fun startOutgoingRingback() {
        CallTonePlayer.startOutgoingRingback(context, toneToken)
    }

    fun onRemoteAnswered() {
        if (ended.get() || state != STATE_DIALING) return
        PersistentLog.d(context, TAG, "onRemoteAnswered for $callUuid")
        CallTonePlayer.stopOutgoingRingback(toneToken)
        setActive()
        startOrUpdateOngoingNotification(isStart = true)
        startAudioBridge(answerCall = false)
        callUuid?.let { emitCallState("active", it) }
    }

    fun setMutedFromUi(muted: Boolean) {
        if (ended.get()) return
        lastMuted = muted
        webRtcClient?.setMuted(muted)
        callUuid?.let { emitCallState("mute", it, muted = muted) }
        if (startedAtMs != 0L) {
            startOrUpdateOngoingNotification()
        }
    }

    fun setCameraEnabled(enabled: Boolean): Boolean {
        if (ended.get()) return false
        return webRtcClient?.setCameraEnabled(enabled) ?: false
    }

    fun flipCamera(): Boolean {
        if (ended.get()) return false
        return webRtcClient?.flipCamera() ?: false
    }

    fun resumeVideo(): Boolean {
        if (ended.get()) return false
        return webRtcClient?.resumeVideo() ?: false
    }

    fun setSpeakerphone(enabled: Boolean): Boolean {
        if (ended.get()) return false
        @Suppress("DEPRECATION")
        val route = if (enabled) {
            CallAudioState.ROUTE_SPEAKER
        } else if (((callAudioState?.supportedRouteMask ?: 0) and CallAudioState.ROUTE_BLUETOOTH) != 0) {
            CallAudioState.ROUTE_BLUETOOTH
        } else {
            CallAudioState.ROUTE_WIRED_OR_EARPIECE
        }
        @Suppress("DEPRECATION")
        try {
            setAudioRoute(route)
        } catch (_: Exception) {}
        @Suppress("DEPRECATION")
        val updated = try {
            val audioManager = context.getSystemService(AudioManager::class.java)
            audioManager?.isSpeakerphoneOn = enabled
            true
        } catch (_: Exception) {
            false
        }
        if (updated && startedAtMs != 0L) {
            startOrUpdateOngoingNotification(speakerOverride = enabled)
        }
        return updated
    }

    fun isSpeakerphoneOn(): Boolean {
        if (callAudioState?.route == CallAudioState.ROUTE_SPEAKER) return true
        @Suppress("DEPRECATION")
        return try {
            context.getSystemService(AudioManager::class.java)?.isSpeakerphoneOn == true
        } catch (_: Exception) {
            false
        }
    }

    fun getAudioDevices(): Map<String, Any> = audioRouteManager.getAudioDevicesPayload()

    fun selectAudioOutput(deviceId: String): Boolean {
        if (ended.get()) return false
        return audioRouteManager.selectOutput(deviceId)
    }

    fun selectAudioInput(deviceId: String): Boolean {
        if (ended.get()) return false
        return audioRouteManager.selectInput(deviceId)
    }

    fun setVoiceIsolation(enabled: Boolean): Boolean {
        if (ended.get()) return false
        return webRtcClient?.setVoiceIsolation(enabled) ?: false
    }

    fun setVideoProcessing(effect: String?, denoise: Boolean, backgroundPath: String?): Boolean {
        if (ended.get()) return false
        return webRtcClient?.setVideoProcessing(effect, denoise, backgroundPath) ?: false
    }

    private fun emitCallState(phase: String, uuid: String, muted: Boolean? = null) {
        val payload = buildCallStatePayload(
            phase = phase,
            uuid = uuid,
            isTelephony = isTelephony,
            isVideo = isVideo,
            callerName = callerDisplayName?.toString(),
            muted = muted
        )
        com.bluebubbles.messaging.services.backend_ui_interop.MethodCallHandler.invokeMethod(
            "facetime-call-state",
            payload
        )
    }

    private fun emitAudioDevices(uuid: String, devicesPayload: Map<String, Any>) {
        val payload = HashMap<String, Any>(devicesPayload.size + 2).apply {
            putAll(devicesPayload)
            put("phase", "audio-devices")
            put("call_uuid", uuid)
        }
        com.bluebubbles.messaging.services.backend_ui_interop.MethodCallHandler.invokeMethod(
            "facetime-call-state",
            payload
        )
    }

    fun scheduleRingingTimeout() {
        mainHandler.removeCallbacks(ringingTimeoutRunnable)
        mainHandler.postDelayed(ringingTimeoutRunnable, RINGING_TIMEOUT_MS)
    }

    fun startAudioBridge(answerCall: Boolean, wantVideo: Boolean = isVideo) {
        val uuid = callUuid ?: return
        val client: WebRtcAudioClient
        synchronized(audioBridgeLock) {
            if (ended.get() || webRtcClient != null) return
            client = WebRtcAudioClient(
                context = context,
                callUuid = uuid,
                answerCall = answerCall,
                wantVideo = wantVideo,
                onRemoteHangup = { onRemoteDisconnect() },
                onError = { err ->
                    PersistentLog.e(context, TAG, "Audio bridge error for $uuid: $err")
                    mainHandler.post {
                        finishCall(DisconnectCause(DisconnectCause.ERROR, err))
                    }
                },
                onRemoteVideoTexture = { textureId ->
                    remoteVideoTextureId = textureId
                },
                onLocalVideoTexture = { textureId ->
                    localVideoTextureId = textureId
                }
            )
            webRtcClient = client
            audioRouteManager.start()
        }
        audioExecutor.execute {
            val shouldStart = synchronized(audioBridgeLock) {
                !ended.get() && webRtcClient === client
            }
            if (shouldStart) {
                client.start()
            }
        }
    }

    fun answerFromHandoff() = onAnswer()

    override fun onShowIncomingCallUi() {
        val uuid = callUuid
        if (ended.get() || uuid.isNullOrBlank() || state == STATE_ACTIVE || WearSyncManager.isWatchAnsweredCall(uuid)) {
            return
        }
        val name = callerDisplayName?.toString()?.takeIf { it.isNotBlank() }
            ?: if (isTelephony) "iPhone Call" else "FaceTime Call"
        val addr = address?.schemeSpecificPart?.takeIf { it.isNotBlank() }
        val body = if (isTelephony) {
            "Incoming iPhone Call"
        } else {
            "Answer FaceTime ${if (isVideo) "Video" else "Audio"} Call"
        }
        CreateIncomingFaceTimeNotification.showIncomingCall(
            context = context,
            channelId = NotificationChannelHandler.FACETIME_CHANNEL_ID,
            notificationId = CreateIncomingFaceTimeNotification.computeFaceTimeNotificationId(uuid),
            callUuid = uuid,
            title = name,
            body = body,
            isVideo = isVideo,
            isTelephony = isTelephony,
            isOngoing = false,
            callerAddress = addr,
            callerName = name,
            callerIcon = callerAvatar,
            skipTelecomDirect = true
        )
    }

    override fun onAnswer() {
        if (ended.get()) return
        mainHandler.removeCallbacks(ringingTimeoutRunnable)
        CallTonePlayer.stopIncomingRing(callUuid)
        PersistentLog.d(context, TAG, "onAnswer for $callUuid")
        if (WearSyncManager.isWatchAnsweredCall(callUuid)) {
            answeredFromWatch = true
            WearSyncManager.refreshWatchNodeNamesAsync(context)
        }
        setActive()
        startOrUpdateOngoingNotification(isStart = true)
        startAudioBridge(answerCall = true)
        if (answeredFromWatch) {
            routeAudioToWatchIfAvailable()
        }
        callUuid?.let {
            emitCallState("active", it)
        }
    }

    override fun onReject() {
        PersistentLog.d(context, TAG, "onReject for $callUuid")
        finishCall(DisconnectCause(DisconnectCause.REJECTED)) { uuid, done ->
            HttpService(context).declineFaceTimeCall(
                callUuid = uuid,
                onSuccess = { done() },
                onError = { err ->
                    PersistentLog.w(context, TAG, "declineFaceTimeCall failed for $uuid: $err")
                    done()
                }
            )
        }
    }

    override fun onDisconnect() {
        endLocalCall(DisconnectCause.LOCAL)
    }

    override fun onAbort() {
        endLocalCall(DisconnectCause.CANCELED)
    }

    override fun onHold() {
        setOnHold()
        webRtcClient?.setMuted(true)
    }

    override fun onUnhold() {
        setActive()
        startOrUpdateOngoingNotification(isStart = startedAtMs == 0L)
        val isMuted = callAudioState?.isMuted ?: false
        webRtcClient?.setMuted(isMuted)
    }

    override fun onPlayDtmfTone(c: Char) {
        val uuid = callUuid ?: return
        if (ended.get()) return
        val digit = normalizeDtmfDigit(c) ?: return
        PersistentLog.d(context, TAG, "onPlayDtmfTone($digit) for $uuid (telephony=$isTelephony)")
        HttpService(context).sendFaceTimeDtmf(
            callUuid = uuid,
            digit = digit,
            onError = { err ->
                PersistentLog.w(context, TAG, "sendFaceTimeDtmf failed for $uuid: $err")
            }
        )
    }

    override fun onStopDtmfTone() {
        // Server plays discrete DTMF tones on onPlayDtmfTone.
    }

    override fun onCallAudioStateChanged(state: CallAudioState?) {
        if (state == null || ended.get()) return
        var audioChanged = false
        if (lastMuted != state.isMuted) {
            lastMuted = state.isMuted
            audioChanged = true
            webRtcClient?.setMuted(state.isMuted)
            callUuid?.let { emitCallState("mute", it, muted = state.isMuted) }
        }
        val speakerNow = (state.route == CallAudioState.ROUTE_SPEAKER)
        if (lastSpeaker != speakerNow) {
            lastSpeaker = speakerNow
            audioChanged = true
        }
        @Suppress("DEPRECATION")
        try {
            val audioManager = context.getSystemService(AudioManager::class.java)
            audioManager?.isSpeakerphoneOn = speakerNow
        } catch (_: Exception) {}
        audioRouteManager.onCallAudioStateChanged()
        if (answeredFromWatch && !watchAudioRouteRequested) {
            routeAudioToWatchIfAvailable(callAudioStateArg = state)
        }
        if (audioChanged && startedAtMs != 0L) {
            startOrUpdateOngoingNotification()
        }
    }

    override fun onAvailableCallEndpointsChanged(availableEndpoints: MutableList<CallEndpoint>) {
        if (ended.get()) return
        latestCallEndpoints = availableEndpoints.toList()
        if (answeredFromWatch && !watchAudioRouteRequested) {
            routeAudioToWatchIfAvailable()
        }
    }

    private fun getBondedWatchHints(watchNodeNames: Set<String>): Pair<Set<String>, Set<String>> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED
        ) {
            return emptySet<String>() to emptySet()
        }
        return try {
            val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter ?: return emptySet<String>() to emptySet()
            val normalizedNodes = watchNodeNames.map { it.trim().lowercase() }.filter { it.isNotEmpty() }
            val addrs = HashSet<String>()
            val names = HashSet<String>()
            for (dev in adapter.bondedDevices.orEmpty()) {
                val devName = dev.name ?: continue
                val lower = devName.trim().lowercase()
                val matchesNode = normalizedNodes.any { it == lower || lower.contains(it) || it.contains(lower) }
                if (matchesNode || lower.contains("watch")) {
                    dev.address?.let { addrs.add(it) }
                    names.add(devName)
                }
            }
            addrs to names
        } catch (_: SecurityException) {
            emptySet<String>() to emptySet()
        } catch (_: Exception) {
            emptySet<String>() to emptySet()
        }
    }

    private fun routeAudioToWatchIfAvailable(callAudioStateArg: CallAudioState? = null) {
        if (ended.get() || !answeredFromWatch || watchAudioRouteRequested) return
        val watchNodeNames = WearSyncManager.getCachedWatchNodeNames()
        val (bondedWatchAddresses, bondedWatchNames) = getBondedWatchHints(watchNodeNames)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && latestCallEndpoints.isNotEmpty()) {
            val endpointCandidates = latestCallEndpoints.map { ep ->
                WatchAudioCandidate(
                    value = ep,
                    name = ep.endpointName.toString(),
                    address = null,
                    isBluetooth = ep.endpointType == CallEndpoint.TYPE_BLUETOOTH
                )
            }
            val watchEndpoint = selectWatchAudioCandidate(
                candidates = endpointCandidates,
                watchNodeNames = watchNodeNames,
                bondedWatchAddresses = bondedWatchAddresses,
                bondedWatchNames = bondedWatchNames
            )
            if (watchEndpoint != null) {
                watchAudioRouteRequested = true
                requestCallEndpointChange(
                    watchEndpoint,
                    context.mainExecutor,
                    object : OutcomeReceiver<Void, CallEndpointException> {
                        override fun onResult(result: Void?) {
                            PersistentLog.d(context, TAG, "Routed call endpoint to watch (${watchEndpoint.endpointName}) for $callUuid")
                        }

                        override fun onError(error: CallEndpointException) {
                            PersistentLog.w(context, TAG, "requestCallEndpointChange to watch failed for $callUuid: ${error.message}")
                        }
                    }
                )
                return
            }
        }

        @Suppress("DEPRECATION")
        val audioState = callAudioStateArg ?: callAudioState
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            @Suppress("DEPRECATION")
            if (((audioState?.supportedRouteMask ?: 0) and CallAudioState.ROUTE_BLUETOOTH) != 0) {
                watchAudioRouteRequested = true
                @Suppress("DEPRECATION")
                setAudioRoute(CallAudioState.ROUTE_BLUETOOTH)
                PersistentLog.d(context, TAG, "Requested legacy Bluetooth audio route for $callUuid")
            }
            return
        }
        @Suppress("DEPRECATION")
        val btDevices = audioState?.supportedBluetoothDevices ?: emptyList()
        if (btDevices.isEmpty()) return
        val watchDev = selectWatchBluetoothDevice(
            devices = btDevices,
            watchNodeNames = watchNodeNames,
            bondedWatchAddresses = bondedWatchAddresses,
            bondedWatchNames = bondedWatchNames
        ) ?: return
        watchAudioRouteRequested = true
        @Suppress("DEPRECATION")
        requestBluetoothAudio(watchDev)
        PersistentLog.d(context, TAG, "Requested Bluetooth audio to watch ${watchDev.address} for $callUuid")
    }

    fun transferAudioToWatch(): Boolean {
        if (ended.get()) return false
        val uuid = callUuid
        answeredFromWatch = true
        watchAudioRouteRequested = false
        WearSyncManager.refreshWatchNodeNamesAsync(context)
        if (!uuid.isNullOrBlank()) {
            WearSyncManager.markWatchAnsweredCall(uuid)
            val resolvedAddress = callerAddress?.takeIf { it.isNotBlank() }
                ?: address?.schemeSpecificPart?.takeIf { it.isNotBlank() }
            val effectiveVideo = isVideo && !isTelephony
            val resolvedName = callerDisplayName?.toString()?.takeIf { it.isNotBlank() }
                ?: resolvedAddress
                ?: FaceTimeCallForegroundService.callKindLabel(effectiveVideo, isTelephony, isGroup)
            WearSyncManager.notifyCallActive(
                context = context,
                callUuid = uuid,
                startedAtMs = ensureStartedAtMs(),
                muted = isMuted(),
                callerName = resolvedName,
                callerAddress = resolvedAddress,
                isVideo = effectiveVideo,
                isTelephony = isTelephony,
                isGroup = isGroup
            )
        }
        routeAudioToWatchIfAvailable()
        return true
    }

    fun transferAudioToPhone(): Boolean {
        if (ended.get()) return false
        val uuid = callUuid
        answeredFromWatch = false
        watchAudioRouteRequested = false
        if (!uuid.isNullOrBlank()) {
            WearSyncManager.clearWatchAnsweredCall(uuid)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && latestCallEndpoints.isNotEmpty()) {
            val phoneEndpoint = latestCallEndpoints.firstOrNull { it.endpointType == CallEndpoint.TYPE_EARPIECE }
                ?: latestCallEndpoints.firstOrNull { it.endpointType == CallEndpoint.TYPE_SPEAKER }
            if (phoneEndpoint != null) {
                requestCallEndpointChange(
                    phoneEndpoint,
                    context.mainExecutor,
                    object : OutcomeReceiver<Void, CallEndpointException> {
                        override fun onResult(result: Void?) {
                            PersistentLog.d(context, TAG, "Transferred call endpoint to phone (${phoneEndpoint.endpointName}) for $callUuid")
                        }

                        override fun onError(error: CallEndpointException) {
                            PersistentLog.w(context, TAG, "requestCallEndpointChange to phone failed for $callUuid: ${error.message}")
                        }
                    }
                )
                return true
            }
        }
        @Suppress("DEPRECATION")
        try {
            setAudioRoute(CallAudioState.ROUTE_EARPIECE)
        } catch (_: Exception) {}
        @Suppress("DEPRECATION")
        try {
            context.getSystemService(AudioManager::class.java)?.isSpeakerphoneOn = false
        } catch (_: Exception) {}
        if (startedAtMs != 0L) {
            startOrUpdateOngoingNotification(speakerOverride = false)
        }
        return true
    }

    internal fun disconnectReplaced() {
        if (!ended.compareAndSet(false, true)) return
        val uuid = callUuid
        cleanupAudio(sendHangup = false)
        if (!uuid.isNullOrBlank()) {
            FaceTimeConnectionService.unregisterActiveConnection(uuid, this)
        }
        setDisconnected(DisconnectCause(DisconnectCause.CANCELED))
        destroy()
    }

    fun onRemoteDisconnect() {
        PersistentLog.d(context, TAG, "onRemoteDisconnect for $callUuid")
        finishCall(DisconnectCause(DisconnectCause.REMOTE))
    }

    fun failOutgoing(reason: String) {
        finishCall(DisconnectCause(DisconnectCause.ERROR, reason))
    }

    private fun endLocalCall(causeCode: Int) {
        PersistentLog.d(context, TAG, "endLocalCall($causeCode) for $callUuid")
        finishCall(DisconnectCause(causeCode), sendHangup = true) { uuid, done ->
            HttpService(context).leaveFaceTimeCall(
                callUuid = uuid,
                onSuccess = { done() },
                onError = { err ->
                    PersistentLog.w(context, TAG, "leaveFaceTimeCall failed for $uuid: $err")
                    done()
                }
            )
        }
    }

    private fun finishCall(
        cause: DisconnectCause,
        sendHangup: Boolean = false,
        onUuid: ((String, () -> Unit) -> Unit)? = null
    ) {
        if (!ended.compareAndSet(false, true)) return
        val wasDialingOrActive = state == STATE_DIALING ||
            state == STATE_ACTIVE ||
            state == STATE_HOLDING ||
            startedAtMs != 0L
        val uuid = callUuid
        cleanupAudio(sendHangup = sendHangup)
        if (CallTonePlayer.shouldPlayCallEndedTone(wasDialingOrActive, cause.code)) {
            CallTonePlayer.playCallEndedTone(context)
        }
        FaceTimeCallForegroundService.stop(context, uuid)
        if (!uuid.isNullOrBlank()) {
            FaceTimeConnectionService.unregisterActiveConnection(uuid, this)
            CreateIncomingFaceTimeNotification.cancelIncomingCallNotification(context, uuid)
            emitCallState("ended", uuid)
            com.bluebubbles.messaging.services.wear.WearSyncManager.notifyCallEnded(context, uuid)
        }
        com.bluebubbles.messaging.MainActivity.clearCallLockScreenFlags()
        setDisconnected(cause)
        if (onUuid != null && !uuid.isNullOrBlank()) {
            // Keep ConnectionService bound briefly until leave/decline HTTP completes or times out.
            var destroyed = false
            val destroyOnce: () -> Unit = {
                mainHandler.post {
                    if (!destroyed) {
                        destroyed = true
                        destroy()
                    }
                }
            }
            mainHandler.postDelayed({
                if (!destroyed) {
                    PersistentLog.w(context, TAG, "Timed out waiting for FaceTime end HTTP for $uuid; destroying connection")
                    destroyOnce()
                }
            }, 3_000L)
            onUuid(uuid, destroyOnce)
        } else {
            destroy()
        }
    }

    private fun cleanupAudio(sendHangup: Boolean) {
        mainHandler.removeCallbacks(ringingTimeoutRunnable)
        CallTonePlayer.stopIncomingRing(callUuid)
        CallTonePlayer.stopOutgoingRingback(toneToken)
        val clientToStop: WebRtcAudioClient?
        synchronized(audioBridgeLock) {
            audioRouteManager.release()
            clientToStop = webRtcClient
            webRtcClient = null
            remoteVideoTextureId = null
            localVideoTextureId = null
        }
        clientToStop?.stop(sendHangup = sendHangup)
    }
}
