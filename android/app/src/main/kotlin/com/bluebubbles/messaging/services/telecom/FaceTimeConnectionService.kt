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
import androidx.core.content.ContextCompat
import com.bluebubbles.messaging.services.network.HttpService
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

        internal fun registerActiveConnection(callUuid: String, connection: FaceTimeConnection) {
            activeConnections[callUuid] = connection
        }

        internal fun unregisterActiveConnection(callUuid: String, connection: FaceTimeConnection) {
            activeConnections.remove(callUuid, connection)
        }

        fun endCall(callUuid: String): Boolean {
            val conn = activeConnections.remove(callUuid) ?: return false
            conn.onRemoteDisconnect()
            return true
        }

        fun resolveHandleScheme(address: String): String =
            if (address.contains("@")) SCHEME_MAILTO else PhoneAccount.SCHEME_TEL

        fun buildHandleUri(address: String?, fallbackName: String? = null): Uri {
            val raw = address?.takeIf { it.isNotBlank() } ?: fallbackName?.takeIf { it.isNotBlank() } ?: "FaceTime"
            return Uri.fromParts(resolveHandleScheme(raw), raw, null)
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
            return try {
                val handle = registerPhoneAccount(context)
                if (!isPhoneAccountEnabled(context)) {
                    PersistentLog.d(context, TAG, "PhoneAccount not enabled; falling back to notification for $callUuid")
                    return false
                }
                val uri = buildHandleUri(address, callerName)
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
                val uri = buildHandleUri(address, callerName)
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
        val addressUri = request?.address ?: buildHandleUri(callerAddress, callerName)

        if (callUuid.isNullOrBlank()) {
            return Connection.createFailedConnection(DisconnectCause(DisconnectCause.ERROR, "Missing callUuid"))
        }

        val connection = FaceTimeConnection(
            context = applicationContext,
            callUuid = callUuid
        ).apply {
            setAddress(addressUri, TelecomManager.PRESENTATION_ALLOWED)
            setCallerDisplayName(callerName, TelecomManager.PRESENTATION_ALLOWED)
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
        PersistentLog.e(applicationContext, TAG, "onCreateIncomingConnectionFailed: ${request?.extras?.getString(EXTRA_CALL_UUID)}")
    }

    override fun onCreateOutgoingConnection(
        connectionManagerPhoneAccount: PhoneAccountHandle?,
        request: ConnectionRequest?
    ): Connection {
        val extras = request?.extras ?: Bundle()
        val address = extras.getString(EXTRA_CALLER_ADDRESS)
            ?: request?.address?.schemeSpecificPart
            ?: ""
        val callerName = extras.getString(EXTRA_CALLER_NAME) ?: address
        val isTelephony = extras.getBoolean(EXTRA_IS_TELEPHONY, false)

        if (address.isBlank()) {
            return Connection.createFailedConnection(DisconnectCause(DisconnectCause.ERROR, "Missing address"))
        }

        val addressUri = request?.address ?: buildHandleUri(address, callerName)
        val connection = FaceTimeConnection(
            context = applicationContext,
            callUuid = null
        ).apply {
            setAddress(addressUri, TelecomManager.PRESENTATION_ALLOWED)
            setCallerDisplayName(callerName, TelecomManager.PRESENTATION_ALLOWED)
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
                if (uuid.isNullOrBlank()) {
                    connection.failOutgoing("Server did not return a call UUID")
                    return@placeFaceTimeCall
                }
                connection.bindCallUuid(uuid)
                // shortcut: marks call active when Mac dials; upgrade to await status_id == 1 for real remote-answer timing
                connection.setActive()
                connection.startAudioBridge(answerCall = false)
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
