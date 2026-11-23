package com.bluebubbles.messaging.services.telecom

import android.bluetooth.BluetoothDevice
import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telecom.CallAudioState
import com.bluebubbles.messaging.utils.PersistentLog

data class AudioDeviceDescriptor(
    val id: String,
    val label: String,
    val kind: String,
    val isInput: Boolean,
    val isActive: Boolean
) {
    fun toMap(): Map<String, Any> = mapOf(
        "id" to id,
        "label" to label,
        "kind" to kind,
        "is_input" to isInput,
        "is_active" to isActive
    )
}

/**
 * Manages FaceTime audio output routes and microphone input selection:
 * - API 31+: AudioManager.availableCommunicationDevices + setCommunicationDevice
 * - API 26-30: Telecom CallAudioState fallback
 * - Inputs: AudioManager.getDevices(GET_DEVICES_INPUTS) -> JavaAudioDeviceModule.setPreferredInputDevice
 * - Hot-plug: AudioDeviceCallback + OnCommunicationDeviceChangedListener + CallAudioState updates
 */
class FaceTimeAudioRouteManager(
    private val context: Context,
    private val setTelecomRoute: (Int) -> Unit,
    private val requestTelecomBluetooth: (BluetoothDevice) -> Unit,
    private val getCallAudioState: () -> CallAudioState?,
    private val setPreferredInputDevice: (AudioDeviceInfo?) -> Unit,
    private val onDevicesChanged: (Map<String, Any>) -> Unit
) {
    companion object {
        private const val TAG = "FaceTimeAudioRouteManager"

        private const val KIND_EARPIECE = "earpiece"
        private const val KIND_SPEAKER = "speaker"
        private const val KIND_WIRED = "wired"
        private const val KIND_BLUETOOTH = "bluetooth"
        private const val KIND_USB = "usb"
        private const val KIND_BUILTIN_MIC = "builtinMic"
        private const val KIND_UNKNOWN = "unknown"

        private val SUPPORTED_INPUT_TYPES = setOf(
            AudioDeviceInfo.TYPE_BUILTIN_MIC,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_USB_DEVICE,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            26 // AudioDeviceInfo.TYPE_BLE_HEADSET (API 31+)
        )

        internal fun mapOutputDeviceKind(type: Int): String = when (type) {
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> KIND_EARPIECE
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> KIND_SPEAKER
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> KIND_WIRED
            AudioDeviceInfo.TYPE_USB_DEVICE,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_USB_ACCESSORY -> KIND_USB
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_HEARING_AID,
            26, // TYPE_BLE_HEADSET
            27  // TYPE_BLE_SPEAKER
            -> KIND_BLUETOOTH
            else -> KIND_UNKNOWN
        }

        internal fun mapInputDeviceKind(type: Int): String = when (type) {
            AudioDeviceInfo.TYPE_BUILTIN_MIC -> KIND_BUILTIN_MIC
            AudioDeviceInfo.TYPE_WIRED_HEADSET -> KIND_WIRED
            AudioDeviceInfo.TYPE_USB_DEVICE,
            AudioDeviceInfo.TYPE_USB_HEADSET -> KIND_USB
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            26 // TYPE_BLE_HEADSET
            -> KIND_BLUETOOTH
            else -> KIND_UNKNOWN
        }

        internal fun defaultLabelForKind(kind: String, isInput: Boolean): String = when (kind) {
            KIND_EARPIECE -> "Phone Earpiece"
            KIND_SPEAKER -> "Speaker"
            KIND_WIRED -> if (isInput) "Wired Mic" else "Wired Headset"
            KIND_USB -> if (isInput) "USB Mic" else "USB Audio"
            KIND_BLUETOOTH -> if (isInput) "Bluetooth Mic" else "Bluetooth"
            KIND_BUILTIN_MIC -> "Phone Mic"
            else -> if (isInput) "Microphone" else "Audio Output"
        }

        internal fun buildLegacyOutputs(
            supportedMask: Int,
            activeRoute: Int,
            btNamesAndAddrs: List<Pair<String, String>>,
            activeBtAddr: String?
        ): List<AudioDeviceDescriptor> {
            val out = mutableListOf<AudioDeviceDescriptor>()
            if ((supportedMask and CallAudioState.ROUTE_EARPIECE) != 0) {
                out.add(
                    AudioDeviceDescriptor(
                        id = "route:earpiece",
                        label = "Phone Earpiece",
                        kind = KIND_EARPIECE,
                        isInput = false,
                        isActive = activeRoute == CallAudioState.ROUTE_EARPIECE
                    )
                )
            }
            if ((supportedMask and CallAudioState.ROUTE_WIRED_HEADSET) != 0) {
                out.add(
                    AudioDeviceDescriptor(
                        id = "route:wired",
                        label = "Wired Headset",
                        kind = KIND_WIRED,
                        isInput = false,
                        isActive = activeRoute == CallAudioState.ROUTE_WIRED_HEADSET
                    )
                )
            }
            if ((supportedMask and CallAudioState.ROUTE_SPEAKER) != 0) {
                out.add(
                    AudioDeviceDescriptor(
                        id = "route:speaker",
                        label = "Speaker",
                        kind = KIND_SPEAKER,
                        isInput = false,
                        isActive = activeRoute == CallAudioState.ROUTE_SPEAKER
                    )
                )
            }
            if ((supportedMask and CallAudioState.ROUTE_BLUETOOTH) != 0) {
                if (btNamesAndAddrs.isEmpty()) {
                    out.add(
                        AudioDeviceDescriptor(
                            id = "route:bluetooth",
                            label = "Bluetooth",
                            kind = KIND_BLUETOOTH,
                            isInput = false,
                            isActive = activeRoute == CallAudioState.ROUTE_BLUETOOTH
                        )
                    )
                } else {
                    for ((name, addr) in btNamesAndAddrs) {
                        val active = activeRoute == CallAudioState.ROUTE_BLUETOOTH &&
                            (activeBtAddr == null || activeBtAddr == addr)
                        out.add(
                            AudioDeviceDescriptor(
                                id = "bt:$addr",
                                label = name.ifBlank { "Bluetooth" },
                                kind = KIND_BLUETOOTH,
                                isInput = false,
                                isActive = active
                            )
                        )
                    }
                }
            }
            return out
        }
    }

    private val audioManager: AudioManager? = context.getSystemService(AudioManager::class.java)
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var selectedInputId: String? = null

    private val lifecycleLock = Any()

    @Volatile
    private var started = false

    @Volatile
    private var commDeviceListener: Any? = null

    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) {
            if (started) emitCurrentDevices()
        }

        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) {
            if (!started) return
            val currentSelected = selectedInputId
            if (currentSelected != null && removedDevices != null) {
                val removed = removedDevices.any { "in:${it.id}" == currentSelected }
                if (removed) {
                    selectedInputId = null
                    setPreferredInputDevice(null)
                }
            }
            emitCurrentDevices()
        }
    }

    fun start() {
        synchronized(lifecycleLock) {
            if (started) return
            started = true
            val am = audioManager ?: return
            am.registerAudioDeviceCallback(deviceCallback, mainHandler)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val listener = AudioManager.OnCommunicationDeviceChangedListener {
                    if (started) emitCurrentDevices()
                }
                commDeviceListener = listener
                try {
                    am.addOnCommunicationDeviceChangedListener(context.mainExecutor, listener)
                } catch (_: Exception) {}
            }
        }
    }

    fun release() {
        synchronized(lifecycleLock) {
            if (!started) return
            started = false
            val am = audioManager
            if (am != null) {
                try {
                    am.unregisterAudioDeviceCallback(deviceCallback)
                } catch (_: Exception) {}
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    (commDeviceListener as? AudioManager.OnCommunicationDeviceChangedListener)?.let {
                        try {
                            am.removeOnCommunicationDeviceChangedListener(it)
                        } catch (_: Exception) {}
                    }
                    commDeviceListener = null
                    try {
                        am.clearCommunicationDevice()
                    } catch (_: Exception) {}
                }
            }
            selectedInputId = null
            try {
                setPreferredInputDevice(null)
            } catch (_: Exception) {}
        }
    }

    fun onCallAudioStateChanged() {
        if (started) emitCurrentDevices()
    }

    fun getAudioDevicesPayload(): Map<String, Any> {
        val outputs = enumerateOutputs()
        val inputs = enumerateInputs()
        val activeOutputId = outputs.firstOrNull { it.isActive }?.id ?: ""
        val activeInputId = inputs.firstOrNull { it.isActive }?.id ?: ""
        return mapOf(
            "outputs" to outputs.map { it.toMap() },
            "inputs" to inputs.map { it.toMap() },
            "active_output_id" to activeOutputId,
            "active_input_id" to activeInputId
        )
    }

    fun selectOutput(deviceId: String): Boolean {
        val am = audioManager ?: return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && deviceId.startsWith("out:")) {
            val numericId = deviceId.removePrefix("out:").toIntOrNull() ?: return false
            val target = am.availableCommunicationDevices.firstOrNull { it.id == numericId } ?: return false
            val telecomRoute = when (mapOutputDeviceKind(target.type)) {
                KIND_SPEAKER -> CallAudioState.ROUTE_SPEAKER
                KIND_BLUETOOTH -> CallAudioState.ROUTE_BLUETOOTH
                KIND_WIRED, KIND_USB -> CallAudioState.ROUTE_WIRED_HEADSET
                else -> CallAudioState.ROUTE_EARPIECE
            }
            try {
                setTelecomRoute(telecomRoute)
            } catch (_: Exception) {}
            val ok = try {
                am.setCommunicationDevice(target)
            } catch (e: Exception) {
                PersistentLog.w(context, TAG, "setCommunicationDevice($numericId) failed: ${e.message}")
                false
            }
            emitCurrentDevices()
            return ok
        }

        // Legacy API 26-30 or route:* fallback
        return try {
            when {
                deviceId == "route:speaker" -> setTelecomRoute(CallAudioState.ROUTE_SPEAKER)
                deviceId == "route:earpiece" -> setTelecomRoute(CallAudioState.ROUTE_EARPIECE)
                deviceId == "route:wired" -> setTelecomRoute(CallAudioState.ROUTE_WIRED_HEADSET)
                deviceId == "route:bluetooth" -> setTelecomRoute(CallAudioState.ROUTE_BLUETOOTH)
                deviceId.startsWith("bt:") -> {
                    val addr = deviceId.removePrefix("bt:")
                    val btDev = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        @Suppress("DEPRECATION")
                        getCallAudioState()?.supportedBluetoothDevices?.firstOrNull { it.address == addr }
                    } else {
                        null
                    }
                    if (btDev != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        requestTelecomBluetooth(btDev)
                    } else {
                        @Suppress("DEPRECATION")
                        setTelecomRoute(CallAudioState.ROUTE_BLUETOOTH)
                    }
                }
                else -> return false
            }
            emitCurrentDevices()
            true
        } catch (e: Exception) {
            PersistentLog.w(context, TAG, "selectOutput($deviceId) failed: ${e.message}")
            false
        }
    }

    fun selectInput(deviceId: String): Boolean {
        val am = audioManager ?: return false
        if (deviceId.isBlank() || deviceId == "default") {
            selectedInputId = null
            setPreferredInputDevice(null)
            emitCurrentDevices()
            return true
        }
        val numericId = deviceId.removePrefix("in:").toIntOrNull() ?: return false
        val target = am.getDevices(AudioManager.GET_DEVICES_INPUTS).firstOrNull { it.id == numericId }
            ?: return false
        selectedInputId = "in:${target.id}"
        setPreferredInputDevice(target)
        emitCurrentDevices()
        return true
    }

    private fun enumerateOutputs(): List<AudioDeviceDescriptor> {
        val am = audioManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && am != null) {
            val activeId = am.communicationDevice?.id
            return am.availableCommunicationDevices.map { dev ->
                val kind = mapOutputDeviceKind(dev.type)
                val productName = dev.productName?.toString()?.trim().orEmpty()
                val label = if (productName.isNotEmpty() && kind != KIND_SPEAKER && kind != KIND_EARPIECE) {
                    productName
                } else {
                    defaultLabelForKind(kind, isInput = false)
                }
                AudioDeviceDescriptor(
                    id = "out:${dev.id}",
                    label = label,
                    kind = kind,
                    isInput = false,
                    isActive = dev.id == activeId
                )
            }
        }
        @Suppress("DEPRECATION")
        val state = getCallAudioState() ?: return emptyList()
        @Suppress("DEPRECATION")
        val btDevices = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            state.supportedBluetoothDevices
        } else {
            emptyList()
        }
        val btList = btDevices.map { dev ->
            val name = try { dev.name ?: "Bluetooth" } catch (_: SecurityException) { "Bluetooth" }
            name to dev.address
        }
        @Suppress("DEPRECATION")
        val activeBtAddr = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            state.activeBluetoothDevice?.address
        } else {
            null
        }
        return buildLegacyOutputs(
            supportedMask = state.supportedRouteMask,
            activeRoute = state.route,
            btNamesAndAddrs = btList,
            activeBtAddr = activeBtAddr
        )
    }

    private fun enumerateInputs(): List<AudioDeviceDescriptor> {
        val am = audioManager ?: return emptyList()
        val devices = am.getDevices(AudioManager.GET_DEVICES_INPUTS)
            .filter { SUPPORTED_INPUT_TYPES.contains(it.type) }
        val activeId = selectedInputId
        var anyActive = false
        val list = devices.map { dev ->
            val kind = mapInputDeviceKind(dev.type)
            val id = "in:${dev.id}"
            val isActive = activeId == id
            if (isActive) anyActive = true
            val productName = dev.productName?.toString()?.trim().orEmpty()
            val label = if (productName.isNotEmpty() && kind != KIND_BUILTIN_MIC) {
                productName
            } else {
                defaultLabelForKind(kind, isInput = true)
            }
            AudioDeviceDescriptor(
                id = id,
                label = label,
                kind = kind,
                isInput = true,
                isActive = isActive
            )
        }
        if (!anyActive && list.isNotEmpty()) {
            val defaultIdx = list.indexOfFirst { it.kind == KIND_BUILTIN_MIC }.takeIf { it >= 0 } ?: 0
            return list.mapIndexed { idx, d -> if (idx == defaultIdx) d.copy(isActive = true) else d }
        }
        return list
    }

    private fun emitCurrentDevices() {
        try {
            onDevicesChanged(getAudioDevicesPayload())
        } catch (_: Exception) {}
    }
}
