package com.bluebubbles.messaging.services.telecom

import android.Manifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
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

        private val activeConnections = ConcurrentHashMap<String, FaceTimeConnection>()
        private val pendingAnsweredUuids = ConcurrentHashMap.newKeySet<String>()
        private val pendingEndedUuids = ConcurrentHashMap.newKeySet<String>()

        internal fun registerActiveConnection(callUuid: String, connection: FaceTimeConnection) {
            activeConnections[callUuid] = connection
            if (pendingEndedUuids.remove(callUuid)) {
                pendingAnsweredUuids.remove(callUuid)
                if (activeConnections.remove(callUuid, connection)) {
                    connection.onRemoteDisconnect()
                }
                return
            }
            if (pendingAnsweredUuids.remove(callUuid)) {
                connection.onRemoteAnswered()
            }
        }

        internal fun unregisterActiveConnection(callUuid: String, connection: FaceTimeConnection) {
            activeConnections.remove(callUuid, connection)
        }

        fun markCallActive(callUuid: String, recordIfPending: Boolean = false): Boolean {
            if (callUuid.isBlank()) return false
            val conn = activeConnections[callUuid]
            if (conn != null) {
                if (conn.state == Connection.STATE_DIALING) {
                    conn.onRemoteAnswered()
                    return true
                }
                return false
            }
            if (recordIfPending && !pendingEndedUuids.contains(callUuid)) {
                if (pendingAnsweredUuids.size > 32) pendingAnsweredUuids.clear()
                pendingAnsweredUuids.add(callUuid)
            }
            return false
        }

        fun setCallMuted(callUuid: String, muted: Boolean): Boolean {
            val conn = activeConnections[callUuid] ?: return false
            conn.setMutedFromUi(muted)
            return true
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
            pendingAnsweredUuids.remove(callUuid)
            val conn = activeConnections[callUuid]
            if (conn == null) {
                if (recordIfPending && !onlyIfRinging && callUuid.isNotBlank()) {
                    if (pendingEndedUuids.size > 32) pendingEndedUuids.clear()
                    pendingEndedUuids.add(callUuid)
                }
                return false
            }
            if (!shouldEndCallForState(conn.state, onlyIfRinging)) return false
            if (!activeConnections.remove(callUuid, conn)) return false
            conn.onRemoteDisconnect()
            return true
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

        fun registerPhoneAccount(context: Context): PhoneAccountHandle {
            val handle = phoneAccountHandle(context)
            val telecomManager = context.getSystemService(TelecomManager::class.java)
            val account = PhoneAccount.builder(handle, "BlueBubbles FaceTime")
                .setCapabilities(PhoneAccount.CAPABILITY_CALL_PROVIDER)
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
                telecomManager.getPhoneAccount(handle)?.isEnabled == true
            } catch (e: SecurityException) {
                PersistentLog.w(context, TAG, "Missing permission to inspect PhoneAccount state: ${e.message}")
                false
            } catch (e: Exception) {
                PersistentLog.w(context, TAG, "Failed to inspect PhoneAccount state: ${e.message}")
                false
            }
        }

        fun openCallingAccountsSettings(context: Context) {
            registerPhoneAccount(context)
            val intent = Intent(TelecomManager.ACTION_CHANGE_PHONE_ACCOUNTS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
        }

        fun addIncomingCall(
            context: Context,
            callUuid: String,
            callerName: String,
            address: String?,
            autoAnswer: Boolean = false,
            isTelephony: Boolean = false
        ): Boolean {
            if (callUuid.isBlank()) return false
            val existing = activeConnections[callUuid]
            if (existing != null && existing.state != Connection.STATE_DISCONNECTED) {
                if (autoAnswer) {
                    existing.answerFromHandoff()
                }
                return true
            }
            return try {
                val handle = registerPhoneAccount(context)
                if (!isPhoneAccountEnabled(context)) {
                    PersistentLog.d(context, TAG, "PhoneAccount not enabled; falling back to notification for $callUuid")
                    return false
                }
                val uri = buildHandleUri(address, callerName, isTelephony = isTelephony)
                val extras = Bundle().apply {
                    putParcelable(TelecomManager.EXTRA_INCOMING_CALL_ADDRESS, uri)
                    putString(EXTRA_CALL_UUID, callUuid)
                    putString(EXTRA_CALLER_NAME, callerName)
                    putString(EXTRA_CALLER_ADDRESS, address ?: callerName)
                    putBoolean(EXTRA_AUTO_ANSWER, autoAnswer)
                    putBoolean(EXTRA_IS_TELEPHONY, isTelephony)
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
            isTelephony: Boolean = false
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

            return try {
                val handle = registerPhoneAccount(context)
                if (!isPhoneAccountEnabled(context)) {
                    PersistentLog.d(context, TAG, "PhoneAccount not enabled for outgoing call")
                    return false
                }
                val uri = buildHandleUri(address, callerName, isTelephony = isTelephony)
                val outgoingExtras = Bundle().apply {
                    putString(EXTRA_CALLER_NAME, callerName ?: address)
                    putString(EXTRA_CALLER_ADDRESS, address)
                    putBoolean(EXTRA_IS_TELEPHONY, isTelephony)
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
        val autoAnswer = extras.getBoolean(EXTRA_AUTO_ANSWER, false)
        val isTelephony = extras.getBoolean(EXTRA_IS_TELEPHONY, false)
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
            isTelephony = isTelephony
        ).apply {
            setAddress(addressUri, TelecomManager.PRESENTATION_ALLOWED)
            setCallerDisplayName(callerName, TelecomManager.PRESENTATION_ALLOWED)
            setVideoState(VideoProfile.STATE_AUDIO_ONLY)
            putExtras(Bundle().apply { putBoolean(EXTRA_IS_TELEPHONY, isTelephony) })
            connectionCapabilities = Connection.CAPABILITY_MUTE or
                Connection.CAPABILITY_HOLD or
                Connection.CAPABILITY_SUPPORT_HOLD
            audioModeIsVoip = true
        }

        registerActiveConnection(callUuid, connection)

        if (autoAnswer) {
            connection.answerFromHandoff()
        } else {
            connection.setRinging()
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
        val isTelephony = extras.getBoolean(EXTRA_IS_TELEPHONY, false)

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
            isTelephony = isTelephony
        ).apply {
            setAddress(addressUri, TelecomManager.PRESENTATION_ALLOWED)
            setCallerDisplayName(callerName, TelecomManager.PRESENTATION_ALLOWED)
            setVideoState(VideoProfile.STATE_AUDIO_ONLY)
            putExtras(Bundle().apply { putBoolean(EXTRA_IS_TELEPHONY, isTelephony) })
            connectionCapabilities = Connection.CAPABILITY_MUTE or
                Connection.CAPABILITY_HOLD or
                Connection.CAPABILITY_SUPPORT_HOLD
            audioModeIsVoip = true
            setDialing()
        }

        HttpService(applicationContext).placeFaceTimeCall(
            addresses = listOf(address),
            video = false,
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
