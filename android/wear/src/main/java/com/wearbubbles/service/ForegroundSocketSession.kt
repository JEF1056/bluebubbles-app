package com.wearbubbles.service

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import com.wearbubbles.WearBubblesApp
import com.wearbubbles.api.dto.TapbackType
import com.wearbubbles.api.dto.TapbackUtils
import com.wearbubbles.data.ContactRepository
import com.wearbubbles.data.SettingsDataStore
import com.wearbubbles.db.AppDatabase
import com.wearbubbles.notifications.CallNotificationHelper
import com.wearbubbles.notifications.NotificationHelper
import com.wearbubbles.relay.PhoneRelayClient
import com.wearbubbles.socket.SocketEvent
import com.wearbubbles.worker.MessageSyncWorker
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap

/**
 * Keeps the watch's direct Socket.IO connection alive only while the app is
 * in the foreground or a FaceTime call is active in standalone mode.
 */
class ForegroundSocketSession {

    companion object {
        internal fun shouldRunStandaloneSocket(
            resumed: Boolean,
            configured: Boolean,
            phoneConnected: Boolean,
            userDisconnected: Boolean,
            callActive: Boolean
        ): Boolean = configured && !phoneConnected && !userDisconnected && (resumed || callActive)
    }

    private data class SessionPolicy(
        val shouldRun: Boolean,
        val keepAlive: Boolean
    )

    private val stateLock = Any()
    private val isResumed = MutableStateFlow(false)
    private var resumeEpoch: Long = 0L
    private var activeApp: WearBubblesApp? = null
    private var sessionJob: Job? = null

    @Volatile
    private var hapticEnabled: Boolean = true
    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private val validatedNetworks = ConcurrentHashMap.newKeySet<Network>()

    fun start(app: WearBubblesApp): Long = synchronized(stateLock) {
        resumeEpoch += 1L
        activeApp = app
        isResumed.value = true
        if (sessionJob?.isActive != true) {
            val job = launchSession(app)
            sessionJob = job
            job.start()
        }
        resumeEpoch
    }

    fun currentEpoch(): Long = synchronized(stateLock) { resumeEpoch }

    fun pauseAfterGrace(expectedEpoch: Long) {
        synchronized(stateLock) {
            if (expectedEpoch != resumeEpoch) return
            isResumed.value = false
            if (CallNotificationHelper.activeCallState.value == null) {
                stopLocked()
            }
        }
    }

    fun stop() {
        synchronized(stateLock) {
            resumeEpoch += 1L
            stopLocked()
        }
    }

    private fun stopLocked() {
        isResumed.value = false
        sessionJob?.cancel()
        sessionJob = null
        unregisterNetworkCallbackLocked()
        activeApp?.socketManager?.disconnect()
    }

    private fun launchSession(app: WearBubblesApp): Job = app.applicationScope.launch(start = CoroutineStart.LAZY) {
        val ownerJob = coroutineContext[Job]
        val settings = SettingsDataStore(app)
        val db = AppDatabase.getInstance(app)
        val relay = app.phoneRelayClient
        val contactRepo = ContactRepository(app, db.contactDao(), settings, relay)

        val hapticJob = launch {
            settings.hapticEnabled.collect { hapticEnabled = it }
        }

        val eventJob = launch {
            app.socketManager.events.collect { event ->
                handleSocketEvent(app, db, relay, contactRepo, event)
            }
        }

        val policyJob = launch {
            combine(
                isResumed,
                settings.isConfigured,
                relay.isPhoneConnected,
                settings.userDisconnected,
                CallNotificationHelper.activeCallState
            ) { resumed, configured, phoneConnected, userDisconnected, activeCall ->
                val callActive = activeCall != null
                SessionPolicy(
                    shouldRun = shouldRunStandaloneSocket(
                        resumed = resumed,
                        configured = configured,
                        phoneConnected = phoneConnected,
                        userDisconnected = userDisconnected,
                        callActive = callActive
                    ),
                    keepAlive = resumed || callActive
                )
            }
                .distinctUntilChanged()
                .collectLatest { policy ->
                    if (policy.shouldRun) {
                        if (relay.refreshPhoneConnected()) {
                            return@collectLatest
                        }
                        val url = settings.getServerUrl()
                        val password = settings.getPassword()
                        val headers = settings.getCustomHeaders()
                        if (url.isNotBlank() && password.isNotBlank()) {
                            contactRepo.loadFromDb()
                            connectIfSessionOwner(app, relay, ownerJob, url, password, headers)
                        }
                    } else {
                        disconnectIfSessionOwner(app, ownerJob, stopIfIdle = !policy.keepAlive)
                    }
                }
        }

        try {
            policyJob.join()
        } finally {
            hapticJob.cancel()
            eventJob.cancel()
            policyJob.cancel()
            cleanupIfSessionOwner(ownerJob)
        }
    }

    private fun connectIfSessionOwner(
        app: WearBubblesApp,
        relay: PhoneRelayClient,
        ownerJob: Job?,
        url: String,
        password: String,
        headers: Map<String, String>
    ) {
        synchronized(stateLock) {
            if (ownerJob == null || sessionJob !== ownerJob || !ownerJob.isActive) return
            app.socketManager.connect(url, password, headers)
            registerNetworkCallbackLocked(app, relay, ownerJob)
        }
    }

    private fun disconnectIfSessionOwner(
        app: WearBubblesApp,
        ownerJob: Job?,
        stopIfIdle: Boolean
    ) {
        synchronized(stateLock) {
            if (ownerJob == null || sessionJob !== ownerJob) return
            if (stopIfIdle) {
                if (!isResumed.value && CallNotificationHelper.activeCallState.value == null) {
                    stopLocked()
                }
                return
            }
            unregisterNetworkCallbackLocked()
            app.socketManager.disconnect()
        }
    }

    private fun cleanupIfSessionOwner(ownerJob: Job?) {
        synchronized(stateLock) {
            if (ownerJob == null || sessionJob !== ownerJob) return
            unregisterNetworkCallbackLocked()
            sessionJob = null
        }
    }

    private suspend fun handleSocketEvent(
        app: WearBubblesApp,
        db: AppDatabase,
        relay: PhoneRelayClient,
        contactRepo: ContactRepository,
        event: SocketEvent
    ) {
        when (event) {
            is SocketEvent.NewMessage -> {
                val msg = event.message
                val chatGuid = msg.chats?.firstOrNull()?.guid ?: return
                if (!msg.isFromMe && !TapbackUtils.isTapbackCode(msg.associatedMessageType)) {
                    val chat = db.chatDao().getChat(chatGuid)
                    val senderAddr = msg.handle?.address ?: chat?.chatIdentifier ?: "Message"
                    val senderName = contactRepo.resolveDisplayName(senderAddr)
                    val senderAvatar = contactRepo.resolveAvatarPath(senderAddr)
                    val firstAttachment = msg.attachments?.firstOrNull()
                    val cachedImagePath = firstAttachment
                        ?.takeIf { it.mimeType?.startsWith("image/") == true }
                        ?.let { relay.getCachedAttachmentFile(it.guid)?.absolutePath }
                    val bodyText = msg.text?.takeIf { it.isNotBlank() }
                        ?: firstAttachment?.let { att ->
                            when {
                                att.mimeType?.startsWith("image/") == true -> "Sent an image"
                                att.mimeType?.startsWith("video/") == true -> "Sent a video"
                                att.mimeType?.startsWith("audio/") == true -> "Sent a voice memo"
                                else -> "Sent an attachment"
                            }
                        } ?: "New message"

                    NotificationHelper.showMessageNotification(
                        context = app,
                        chatGuid = chatGuid,
                        senderName = senderName,
                        messageText = bodyText,
                        isGroup = chat?.isGroup ?: false,
                        groupTitle = chat?.displayName,
                        hapticEnabled = hapticEnabled,
                        timestamp = msg.dateCreated,
                        senderAddress = senderAddr,
                        senderAvatarPath = senderAvatar,
                        isTapback = false,
                        attachmentPath = cachedImagePath,
                        attachmentMimeType = firstAttachment?.mimeType
                    )
                } else if (!msg.isFromMe && TapbackUtils.isTapbackCode(msg.associatedMessageType)) {
                    val tapback = TapbackType.fromAddCode(msg.associatedMessageType)
                    val reactionLabel = if (tapback == TapbackType.EMOJI && !msg.associatedMessageEmoji.isNullOrBlank()) {
                        "Reacted ${msg.associatedMessageEmoji} to"
                    } else {
                        tapback?.label
                    }
                    if (reactionLabel != null) {
                        val chat = db.chatDao().getChat(chatGuid)
                        val senderAddr = msg.handle?.address ?: chat?.chatIdentifier ?: "Someone"
                        val senderName = contactRepo.resolveDisplayName(senderAddr)
                        val senderAvatar = contactRepo.resolveAvatarPath(senderAddr)
                        NotificationHelper.showMessageNotification(
                            context = app,
                            chatGuid = chatGuid,
                            senderName = senderName,
                            messageText = "$reactionLabel a message",
                            isGroup = chat?.isGroup ?: false,
                            groupTitle = chat?.displayName,
                            hapticEnabled = hapticEnabled,
                            timestamp = msg.dateCreated,
                            senderAddress = senderAddr,
                            senderAvatarPath = senderAvatar,
                            isTapback = true
                        )
                    }
                }
            }

            is SocketEvent.UpdatedMessage -> {}

            is SocketEvent.IncomingFaceTime -> {
                val resolvedName = if (event.callerAddress.isNotBlank()) {
                    contactRepo.resolveDisplayName(event.callerAddress)
                } else {
                    event.callerName
                }
                CallNotificationHelper.showIncomingCall(
                    context = app,
                    callUuid = event.callUuid,
                    callerName = resolvedName,
                    callerAddress = event.callerAddress,
                    isVideo = event.isVideo,
                    fromPhoneRelay = false,
                    isTelephony = event.isTelephony
                )
            }

            is SocketEvent.FaceTimeCallEnded -> {
                CallNotificationHelper.endCall(
                    app,
                    event.callUuid,
                    onlyIfRinging = event.onlyIfRinging
                )
            }

            is SocketEvent.Connected -> {
                MessageSyncWorker.runOnce(app)
            }

            else -> {}
        }
    }

    private fun registerNetworkCallbackLocked(
        app: WearBubblesApp,
        relay: PhoneRelayClient,
        ownerJob: Job
    ) {
        if (networkCallback != null) return
        val cm = app.getSystemService(ConnectivityManager::class.java) ?: return
        connectivityManager = cm
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                val hasInternet = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                synchronized(stateLock) {
                    if (sessionJob !== ownerJob || networkCallback !== this || !ownerJob.isActive) return
                    if (hasInternet) {
                        val wasEmpty = validatedNetworks.isEmpty()
                        validatedNetworks.add(network)
                        if (wasEmpty && !relay.isPhoneConnected.value) {
                            app.socketManager.reconnectIfConfigured()
                        }
                    } else {
                        validatedNetworks.remove(network)
                        if (validatedNetworks.isEmpty()) {
                            app.socketManager.disconnect()
                        }
                    }
                }
            }

            override fun onLost(network: Network) {
                synchronized(stateLock) {
                    if (sessionJob !== ownerJob || networkCallback !== this || !ownerJob.isActive) return
                    validatedNetworks.remove(network)
                    if (validatedNetworks.isEmpty()) {
                        app.socketManager.disconnect()
                    }
                }
            }
        }
        networkCallback = callback
        try {
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            cm.registerNetworkCallback(request, callback)
        } catch (_: Exception) {
            networkCallback = null
            validatedNetworks.clear()
        }
    }

    private fun unregisterNetworkCallbackLocked() {
        networkCallback?.let { cb ->
            try {
                connectivityManager?.unregisterNetworkCallback(cb)
            } catch (_: Exception) {
            }
        }
        networkCallback = null
        validatedNetworks.clear()
    }
}
