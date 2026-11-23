package com.bluebubbles.messaging.services.telecom

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.media.AudioManager
import android.net.Uri
import android.os.Bundle
import android.telecom.Connection
import android.telecom.ConnectionRequest
import android.telecom.ConnectionService
import android.telecom.DisconnectCause
import android.telecom.PhoneAccount
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.telecom.VideoProfile
import androidx.core.content.ContextCompat
import com.bluebubbles.messaging.services.network.HttpService
import com.bluebubbles.messaging.services.wear.WearSyncManager
import com.bluebubbles.messaging.utils.PersistentLog
import java.util.concurrent.ConcurrentHashMap

class FaceTimeConnectionService : ConnectionService() {

    companion object {
        private const val TAG = "FaceTimeConnectionService"
        const val PHONE_ACCOUNT_ID = "BlueBubblesFaceTime"
        const val SCHEME_MAILTO = "mailto"
        const val EXTRA_CALL_UUID = "callUuid"
        const val EXTRA_CALLER_NAME = "callerName"
        const val EXTRA_CALLER_ADDRESS = "callerAddress"
        const val EXTRA_AUTO_ANSWER = "autoAnswer"
        const val EXTRA_IS_TELEPHONY = "isTelephony"
        const val EXTRA_IS_VIDEO = "isVideo"
        const val EXTRA_CALLER_AVATAR = "callerAvatar"

        private val connectionLock = Any()
        private val activeConnections = ConcurrentHashMap<String, FaceTimeConnection>()
        private val pendingOutgoingAvatars = ConcurrentHashMap<String, ByteArray>()
        private val pendingIncomingAvatars = ConcurrentHashMap<String, ByteArray>()
        private val pendingAnsweredUuids = BoundedUuidSet(32)
        private val pendingEndedUuids = BoundedUuidSet(32)

        internal fun registerActiveConnection(callUuid: String, connection: FaceTimeConnection) {
            var shouldDisconnect = false
            var shouldAnswer = false
            var replacedConnection: FaceTimeConnection? = null
            synchronized(connectionLock) {
                val previous = activeConnections.put(callUuid, connection)
                if (previous != null && previous !== connection) {
                    replacedConnection = previous
                }
                if (pendingEndedUuids.remove(callUuid)) {
                    pendingAnsweredUuids.remove(callUuid)
                    if (activeConnections.remove(callUuid, connection)) {
                        shouldDisconnect = true
                    }
                } else if (pendingAnsweredUuids.remove(callUuid)) {
                    shouldAnswer = true
                }
            }
            replacedConnection?.disconnectReplaced()
            if (shouldDisconnect) {
                connection.onRemoteDisconnect()
            } else if (shouldAnswer) {
                connection.onRemoteAnswered()
            }
        }

        internal fun unregisterActiveConnection(callUuid: String, connection: FaceTimeConnection) {
            synchronized(connectionLock) {
                activeConnections.remove(callUuid, connection)
            }
        }

        internal fun getActiveConnection(callUuid: String): FaceTimeConnection? {
            if (callUuid.isBlank()) return null
            return activeConnections[callUuid]
        }

        fun markCallActive(callUuid: String, recordIfPending: Boolean = false): Boolean {
            if (callUuid.isBlank()) return false
            val connToAnswer: FaceTimeConnection
            synchronized(connectionLock) {
                val conn = activeConnections[callUuid]
                if (conn != null) {
                    if (conn.state == Connection.STATE_DIALING) {
                        connToAnswer = conn
                    } else {
                        return false
                    }
                } else {
                    if (recordIfPending && !pendingEndedUuids.contains(callUuid)) {
                        pendingAnsweredUuids.add(callUuid)
                    }
                    return false
                }
            }
            connToAnswer.onRemoteAnswered()
            return true
        }

        fun setCallMuted(callUuid: String, muted: Boolean): Boolean {
            val conn = activeConnections[callUuid] ?: return false
            conn.setMutedFromUi(muted)
            return true
        }

        fun isCallMuted(callUuid: String?): Boolean {
            val conn = if (!callUuid.isNullOrBlank()) activeConnections[callUuid] else activeConnections.values.firstOrNull()
            return conn?.isMuted() ?: false
        }

        fun isCallActive(callUuid: String?): Boolean {
            if (callUuid.isNullOrBlank()) return false
            val conn = activeConnections[callUuid] ?: return false
            return !conn.isEnded && (conn.state == Connection.STATE_ACTIVE || conn.state == Connection.STATE_HOLDING)
        }

        fun hasActiveNonRingingCall(excludeUuid: String? = null): Boolean {
            synchronized(connectionLock) {
                return activeConnections.any { (uuid, conn) ->
                    uuid != excludeUuid &&
                        !conn.isEnded &&
                        conn.state != Connection.STATE_RINGING &&
                        conn.state != Connection.STATE_DISCONNECTED
                }
            }
        }

        internal fun isConnectionRegistered(callUuid: String?): Boolean {
            if (callUuid.isNullOrBlank()) return false
            synchronized(connectionLock) {
                val conn = activeConnections[callUuid] ?: return false
                return !conn.isEnded && conn.state != Connection.STATE_DISCONNECTED
            }
        }

        internal fun findRemainingOngoingConnection(excludeUuid: String?): FaceTimeConnection? {
            synchronized(connectionLock) {
                return activeConnections.entries.firstOrNull { (uuid, conn) ->
                    uuid != excludeUuid &&
                        !conn.isEnded &&
                        (conn.state == Connection.STATE_ACTIVE || conn.state == Connection.STATE_HOLDING)
                }?.value
            }
        }

        fun hangUpCall(callUuid: String): Boolean {
            if (callUuid.isBlank()) return false
            val conn = activeConnections[callUuid] ?: return false
            conn.onDisconnect()
            return true
        }

        fun setCallSpeakerphone(context: Context, callUuid: String?, enabled: Boolean): Boolean {
            val conn = if (!callUuid.isNullOrBlank()) activeConnections[callUuid] else activeConnections.values.firstOrNull()
            return conn?.setSpeakerphone(enabled) ?: false
        }

        fun isCallSpeakerphoneOn(context: Context, callUuid: String?): Boolean {
            val conn = if (!callUuid.isNullOrBlank()) activeConnections[callUuid] else activeConnections.values.firstOrNull()
            if (conn != null) {
                return conn.isSpeakerphoneOn()
            }
            @Suppress("DEPRECATION")
            return try {
                context.getSystemService(AudioManager::class.java)?.isSpeakerphoneOn == true
            } catch (_: Exception) {
                false
            }
        }

        fun getCallVideoTextureId(callUuid: String?): Long? {
            val conn = if (!callUuid.isNullOrBlank()) activeConnections[callUuid] else activeConnections.values.firstOrNull()
            return conn?.getRemoteVideoTextureId()
        }

        fun getCallLocalVideoTextureId(callUuid: String?): Long? {
            val conn = if (!callUuid.isNullOrBlank()) activeConnections[callUuid] else activeConnections.values.firstOrNull()
            return conn?.getLocalVideoTextureId()
        }

        fun getCallVideoTextures(callUuid: String?): Map<String, Any?> {
            val conn = if (!callUuid.isNullOrBlank()) activeConnections[callUuid] else activeConnections.values.firstOrNull()
            return mapOf(
                "remote_texture_id" to conn?.getRemoteVideoTextureId(),
                "remote_video_width" to conn?.getRemoteVideoWidth(),
                "remote_video_height" to conn?.getRemoteVideoHeight(),
                "local_texture_id" to conn?.getLocalVideoTextureId(),
                "local_video_width" to conn?.getLocalVideoWidth(),
                "local_video_height" to conn?.getLocalVideoHeight()
            )
        }

        fun setCallCameraEnabled(callUuid: String?, enabled: Boolean): Boolean {
            val conn = if (!callUuid.isNullOrBlank()) activeConnections[callUuid] else activeConnections.values.firstOrNull()
            return conn?.setCameraEnabled(enabled) ?: false
        }

        fun flipCallCamera(callUuid: String?): Boolean {
            val conn = if (!callUuid.isNullOrBlank()) activeConnections[callUuid] else activeConnections.values.firstOrNull()
            return conn?.flipCamera() ?: false
        }

        fun resumeCallVideo(callUuid: String?): Boolean {
            val conn = if (!callUuid.isNullOrBlank()) activeConnections[callUuid] else activeConnections.values.firstOrNull()
            return conn?.resumeVideo() ?: false
        }

        fun getCallAudioDevices(context: Context, callUuid: String?): Map<String, Any> {
            val conn = if (!callUuid.isNullOrBlank()) activeConnections[callUuid] else activeConnections.values.firstOrNull()
            if (conn != null) return conn.getAudioDevices()
            return FaceTimeAudioRouteManager(
                context = context.applicationContext,
                setTelecomRoute = {},
                requestTelecomBluetooth = {},
                getCallAudioState = { null },
                setPreferredInputDevice = {},
                onDevicesChanged = {}
            ).getAudioDevicesPayload()
        }

        fun setCallAudioOutput(callUuid: String?, deviceId: String): Boolean {
            val conn = if (!callUuid.isNullOrBlank()) activeConnections[callUuid] else activeConnections.values.firstOrNull()
            return conn?.selectAudioOutput(deviceId) ?: false
        }

        fun setCallAudioInput(callUuid: String?, deviceId: String): Boolean {
            val conn = if (!callUuid.isNullOrBlank()) activeConnections[callUuid] else activeConnections.values.firstOrNull()
            return conn?.selectAudioInput(deviceId) ?: false
        }

        fun transferCallAudioToWatch(context: Context, callUuid: String?): Boolean {
            val conn = (if (!callUuid.isNullOrBlank()) activeConnections[callUuid] else activeConnections.values.firstOrNull())
                ?: return false
            return conn.transferAudioToWatch()
        }

        fun transferCallAudioToPhone(callUuid: String?): Boolean {
            val conn = if (!callUuid.isNullOrBlank()) activeConnections[callUuid] else activeConnections.values.firstOrNull()
            val uuid = conn?.callUuid ?: callUuid
            if (!uuid.isNullOrBlank()) {
                WearSyncManager.clearWatchAnsweredCall(uuid)
            }
            return conn?.transferAudioToPhone() ?: false
        }

        fun setCallVoiceIsolation(callUuid: String?, enabled: Boolean): Boolean {
            val conn = if (!callUuid.isNullOrBlank()) activeConnections[callUuid] else activeConnections.values.firstOrNull()
            return conn?.setVoiceIsolation(enabled) ?: false
        }

        fun setCallVideoProcessing(
            callUuid: String?,
            effect: String?,
            denoise: Boolean,
            backgroundPath: String?
        ): Boolean {
            val conn = if (!callUuid.isNullOrBlank()) activeConnections[callUuid] else activeConnections.values.firstOrNull()
            return conn?.setVideoProcessing(effect, denoise, backgroundPath) ?: false
        }

        internal fun handleOutgoingCallSuccess(
            uuid: String?,
            isEnded: () -> Boolean,
            failOutgoing: (String) -> Unit,
            bindCallUuid: (String) -> Unit,
            unregisterActive: (String) -> Unit,
            leaveCall: (String) -> Unit,
            activateAndStart: () -> Unit
        ) {
            if (uuid.isNullOrBlank()) {
                failOutgoing("Server did not return a call UUID")
                return
            }
            if (isEnded()) {
                leaveCall(uuid)
                unregisterActive(uuid)
                return
            }
            bindCallUuid(uuid)
            if (isEnded()) {
                unregisterActive(uuid)
                leaveCall(uuid)
                return
            }
            activateAndStart()
        }

        internal fun shouldEndCallForState(state: Int, onlyIfRinging: Boolean): Boolean =
            !onlyIfRinging || state == Connection.STATE_RINGING

        fun endCall(callUuid: String, onlyIfRinging: Boolean = false, recordIfPending: Boolean = false): Boolean {
            val connToDisconnect: FaceTimeConnection
            synchronized(connectionLock) {
                pendingAnsweredUuids.remove(callUuid)
                val conn = activeConnections[callUuid]
                if (conn == null) {
                    if (recordIfPending && !onlyIfRinging && callUuid.isNotBlank()) {
                        pendingEndedUuids.add(callUuid)
                    }
                    return false
                }
                if (!shouldEndCallForState(conn.state, onlyIfRinging)) return false
                if (!activeConnections.remove(callUuid, conn)) return false
                connToDisconnect = conn
            }
            connToDisconnect.onRemoteDisconnect()
            return true
        }

        fun hasActiveConnection(callUuid: String?): Boolean {
            if (callUuid.isNullOrBlank()) return false
            synchronized(connectionLock) {
                return activeConnections.containsKey(callUuid)
            }
        }

        fun isCallPendingEnded(callUuid: String?): Boolean {
            if (callUuid.isNullOrBlank()) return false
            synchronized(connectionLock) {
                return pendingEndedUuids.contains(callUuid)
            }
        }

        fun resolveHandleScheme(address: String, isTelephony: Boolean = false): String =
            if (isTelephony || !address.contains("@")) PhoneAccount.SCHEME_TEL else SCHEME_MAILTO

        fun buildHandleUri(
            address: String?,
            fallbackName: String? = null,
            isTelephony: Boolean = false
        ): Uri {
            val raw = address?.takeIf { it.isNotBlank() }
                ?: fallbackName?.takeIf { it.isNotBlank() }
                ?: if (isTelephony) "iPhone" else "FaceTime"
            val scheme = resolveHandleScheme(raw, isTelephony = isTelephony)
            val part = if (scheme == PhoneAccount.SCHEME_TEL) raw.removePrefix("tel:") else raw.removePrefix("mailto:")
            return Uri.fromParts(scheme, part, null)
        }

        fun phoneAccountHandle(context: Context): PhoneAccountHandle {
            return PhoneAccountHandle(
                ComponentName(context.applicationContext, FaceTimeConnectionService::class.java),
                PHONE_ACCOUNT_ID
            )
        }

        internal fun phoneAccountCapabilities(): Int = PhoneAccount.CAPABILITY_SELF_MANAGED

        fun registerPhoneAccount(context: Context): PhoneAccountHandle {
            val handle = phoneAccountHandle(context)
            val telecomManager = context.getSystemService(TelecomManager::class.java)
            val account = PhoneAccount.builder(handle, "BlueBubbles FaceTime")
                .setCapabilities(phoneAccountCapabilities())
                .setSupportedUriSchemes(listOf(PhoneAccount.SCHEME_TEL, SCHEME_MAILTO))
                .setShortDescription("FaceTime Audio & iPhone Continuity")
                .setHighlightColor(Color.parseColor("#1E88E5"))
                .build()
            telecomManager.registerPhoneAccount(account)
            return handle
        }

        fun isPhoneAccountEnabled(context: Context): Boolean {
            return try {
                val telecomManager = context.getSystemService(TelecomManager::class.java) ?: return false
                val handle = phoneAccountHandle(context)
                val account = telecomManager.getPhoneAccount(handle) ?: return false
                account.isEnabled || (account.capabilities and PhoneAccount.CAPABILITY_SELF_MANAGED) != 0
            } catch (e: SecurityException) {
                PersistentLog.w(context, TAG, "Missing permission to inspect PhoneAccount state: ${e.message}")
                false
            } catch (e: Exception) {
                PersistentLog.w(context, TAG, "Failed to inspect PhoneAccount state: ${e.message}")
                false
            }
        }

        fun callingAccountsIntent(context: Context): Intent {
            registerPhoneAccount(context)
            return Intent(TelecomManager.ACTION_CHANGE_PHONE_ACCOUNTS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        }

        fun openCallingAccountsSettings(context: Context) {
            context.startActivity(callingAccountsIntent(context))
        }

        fun addIncomingCall(
            context: Context,
            callUuid: String,
            callerName: String,
            address: String?,
            callerAvatar: ByteArray? = null,
            autoAnswer: Boolean = false,
            isTelephony: Boolean = false,
            isVideo: Boolean = false
        ): Boolean {
            if (callUuid.isBlank()) return false
            val existing = activeConnections[callUuid]
            if (existing != null && existing.state != Connection.STATE_DISCONNECTED) {
                if (callerAvatar != null && callerAvatar.isNotEmpty()) {
                    existing.callerAvatar = callerAvatar
                }
                if (autoAnswer) {
                    existing.updateCallerInfo(isVideo = isVideo && !isTelephony, callerAvatar = callerAvatar)
                    existing.answerFromHandoff()
                }
                return true
            }
            if (callerAvatar != null && callerAvatar.isNotEmpty()) {
                pendingIncomingAvatars[callUuid] = callerAvatar
            }
            return try {
                val handle = registerPhoneAccount(context)
                val uri = buildHandleUri(address, callerName, isTelephony = isTelephony)
                val extras = Bundle().apply {
                    putParcelable(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS, uri)
                    putString(EXTRA_CALL_UUID, callUuid)
                    putString(EXTRA_CALLER_NAME, callerName)
                    putString(EXTRA_CALLER_ADDRESS, address ?: callerName)
                    if (callerAvatar != null && callerAvatar.isNotEmpty() && callerAvatar.size <= 256 * 1024) {
                        putByteArray(EXTRA_CALLER_AVATAR, callerAvatar)
                    }
                    putBoolean(EXTRA_AUTO_ANSWER, autoAnswer)
                    putBoolean(EXTRA_IS_TELEPHONY, isTelephony)
                    putBoolean(EXTRA_IS_VIDEO, isVideo)
                }
                val telecomManager = context.getSystemService(TelecomManager::class.java)
                telecomManager.addNewIncomingCall(handle, extras)
                true
            } catch (e: Exception) {
                PersistentLog.e(context, TAG, "addNewIncomingCall failed for $callUuid", e)
                false
            }
        }

        fun placeOutgoingCall(
            context: Context,
            address: String,
            callerName: String? = null,
            callerAvatar: ByteArray? = null,
            isTelephony: Boolean = false,
            isVideo: Boolean = false
        ): Boolean {
            if (address.isBlank()) return false
            val hasCallPhone = ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.CALL_PHONE
            ) == PackageManager.PERMISSION_GRANTED
            if (!hasCallPhone) {
                PersistentLog.w(context, TAG, "CALL_PHONE permission not granted for outgoing Telecom call")
                return false
            }

            if (callerAvatar != null && callerAvatar.isNotEmpty()) {
                pendingOutgoingAvatars[address] = callerAvatar
            }

            return try {
                val handle = registerPhoneAccount(context)
                val uri = buildHandleUri(address, callerName, isTelephony = isTelephony)
                val outgoingExtras = Bundle().apply {
                    putString(EXTRA_CALLER_NAME, callerName ?: address)
                    putString(EXTRA_CALLER_ADDRESS, address)
                    if (callerAvatar != null && callerAvatar.isNotEmpty() && callerAvatar.size <= 256 * 1024) {
                        putByteArray(EXTRA_CALLER_AVATAR, callerAvatar)
                    }
                    putBoolean(EXTRA_IS_TELEPHONY, isTelephony)
                    putBoolean(EXTRA_IS_VIDEO, isVideo)
                }
                val extras = Bundle().apply {
                    putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, handle)
                    putBundle(TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS, outgoingExtras)
                }
                val telecomManager = context.getSystemService(TelecomManager::class.java)
                telecomManager.placeCall(uri, extras)
                true
            } catch (e: Exception) {
                PersistentLog.e(context, TAG, "placeCall failed for $address", e)
                false
            }
        }
    }

    override fun onCreateIncomingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ): Connection {
        val extras = request?.extras ?: Bundle()
        val callUuid = extras.getString(EXTRA_CALL_UUID)
        val callerName = extras.getString(EXTRA_CALLER_NAME) ?: "Unknown Caller"
        val callerAddress = extras.getString(EXTRA_CALLER_ADDRESS)
        val callerAvatar = extras.getByteArray(EXTRA_CALLER_AVATAR)
            ?: (if (!callUuid.isNullOrBlank()) pendingIncomingAvatars.remove(callUuid) else null)
        val autoAnswer = extras.getBoolean(EXTRA_AUTO_ANSWER, false)
        val isTelephony = extras.getBoolean(EXTRA_IS_TELEPHONY, false)
        val isVideo = !isTelephony && extras.getBoolean(EXTRA_IS_VIDEO, false)
        val addressUri = if (isTelephony) {
            buildHandleUri(callerAddress, callerName, isTelephony = true)
        } else {
            request?.address ?: buildHandleUri(callerAddress, callerName)
        }

        if (callUuid.isNullOrBlank()) {
            return Connection.createFailedConnection(DisconnectCause(DisconnectCause.ERROR, "Missing callUuid"))
        }

        val connection = FaceTimeConnection(
            context = applicationContext,
            callUuid = callUuid,
            isTelephony = isTelephony,
            isVideo = isVideo,
            callerAddress = callerAddress,
            callerAvatar = callerAvatar
        ).apply {
            setAddress(addressUri, TelecomManager.PRESENTATION_ALLOWED)
            setCallerDisplayName(callerName, TelecomManager.PRESENTATION_ALLOWED)
            setVideoState(VideoProfile.STATE_AUDIO_ONLY)
            putExtras(Bundle().apply { putBoolean(EXTRA_IS_TELEPHONY, isTelephony) })
            connectionCapabilities = Connection.CAPABILITY_MUTE or
                Connection.CAPABILITY_HOLD or
                Connection.CAPABILITY_SUPPORT_HOLD
            connectionProperties = Connection.PROPERTY_SELF_MANAGED
            audioModeIsVoip = true
        }

        registerActiveConnection(callUuid, connection)
        if (connection.isEnded) return connection

        if (autoAnswer) {
            connection.answerFromHandoff()
        } else {
            connection.setRinging()
            CallTonePlayer.startIncomingRing(
                context = applicationContext,
                callUuid = callUuid,
                isCallInProgress = hasActiveNonRingingCall(callUuid)
            )
            connection.scheduleRingingTimeout()
        }
        return connection
    }

    override fun onCreateIncomingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ) {
        val callUuid = request?.extras?.getString(EXTRA_CALL_UUID)
        PersistentLog.e(applicationContext, TAG, "onCreateIncomingConnectionFailed: $callUuid")
        if (!callUuid.isNullOrBlank()) {
            WearSyncManager.notifyCallEnded(applicationContext, callUuid)
        }
    }

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ): Connection {
        val rawExtras = request?.extras ?: Bundle()
        val extras = rawExtras.getBundle(TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS) ?: rawExtras
        val address = extras.getString(EXTRA_CALLER_ADDRESS)
            ?: request?.address?.schemeSpecificPart
            ?: ""
        val callerName = extras.getString(EXTRA_CALLER_NAME) ?: address
        val callerAvatar = extras.getByteArray(EXTRA_CALLER_AVATAR)
            ?: (if (address.isNotBlank()) pendingOutgoingAvatars.remove(address) else null)
        val isTelephony = extras.getBoolean(EXTRA_IS_TELEPHONY, false)
        val isVideo = !isTelephony && extras.getBoolean(EXTRA_IS_VIDEO, false)

        if (address.isBlank()) {
            return Connection.createFailedConnection(DisconnectCause(DisconnectCause.ERROR, "Missing address"))
        }

        val addressUri = if (isTelephony) {
            buildHandleUri(address, callerName, isTelephony = true)
        } else {
            request?.address ?: buildHandleUri(address, callerName)
        }
        val connection = FaceTimeConnection(
            context = applicationContext,
            callUuid = null,
            isTelephony = isTelephony,
            isVideo = isVideo,
            callerAddress = address,
            callerAvatar = callerAvatar
        ).apply {
            setAddress(addressUri, TelecomManager.PRESENTATION_ALLOWED)
            setCallerDisplayName(callerName, TelecomManager.PRESENTATION_ALLOWED)
            setVideoState(VideoProfile.STATE_AUDIO_ONLY)
            putExtras(Bundle().apply { putBoolean(EXTRA_IS_TELEPHONY, isTelephony) })
            connectionCapabilities = Connection.CAPABILITY_MUTE or
                Connection.CAPABILITY_HOLD or
                Connection.CAPABILITY_SUPPORT_HOLD
            connectionProperties = Connection.PROPERTY_SELF_MANAGED
            audioModeIsVoip = true
            setDialing()
            startOutgoingRingback()
        }

        HttpService(applicationContext).placeFaceTimeCall(
            addresses = listOf(address),
            video = isVideo,
            isTelephony = isTelephony,
            onSuccess = { uuid ->
                handleOutgoingCallSuccess(
                    uuid = uuid,
                    isEnded = { connection.isEnded },
                    failOutgoing = connection::failOutgoing,
                    bindCallUuid = connection::bindCallUuid,
                    unregisterActive = { unregisterActiveConnection(it, connection) },
                    leaveCall = { HttpService(applicationContext).leaveFaceTimeCall(it) },
                    activateAndStart = {
                        // Stay in STATE_DIALING while warming WebRTC; status_id == 1 calls markCallActive -> setActive().
                        connection.startAudioBridge(answerCall = false)
                    }
                )
            },
            onError = { err ->
                connection.failOutgoing(err)
            }
        )

        return connection
    }

    override fun onCreateOutgoingConnectionFailed(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ) {
        PersistentLog.e(applicationContext, TAG, "onCreateOutgoingConnectionFailed: ${request?.address}")
    }
}

internal class BoundedUuidSet(private val maxSize: Int = 32) {
    private val set = LinkedHashSet<String>()

    @Synchronized
    fun add(uuid: String): Boolean {
        if (uuid.isBlank() || maxSize <= 0) return false
        set.remove(uuid)
        if (set.size >= maxSize) {
            val iterator = set.iterator()
            if (iterator.hasNext()) {
                iterator.next()
                iterator.remove()
            }
        }
        return set.add(uuid)
    }

    @Synchronized
    fun remove(uuid: String): Boolean = set.remove(uuid)

    @Synchronized
    fun contains(uuid: String): Boolean = set.contains(uuid)

    @Synchronized
    fun size(): Int = set.size

    @Synchronized
    fun clear() = set.clear()
}
