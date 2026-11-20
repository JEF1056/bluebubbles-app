package com.bluebubbles.messaging.services.findmy

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.util.Log
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import kotlin.math.pow

data class GoogleFmdnFrame(
    val frameType: Int,
    val eidHex: String,
    val eidByteLength: Int,
)

data class SamsungSmartTagFrame(
    val state: Int,
    val agingCounter: Int,
    val privacyIdHex: String,
    val uwbCapable: Boolean,
    val batteryLevel: Int,
)

class FindMyBleHost private constructor(
    private val activity: FlutterFragmentActivity,
) {
    companion object {
        private const val TAG = "FindMyBleHost"
        private const val METHOD_CHANNEL = "com.bluebubbles.messaging/findmy_ble"
        private const val EVENT_CHANNEL = "com.bluebubbles.messaging/findmy_ble_events"
        private const val PREFS_NAME = "findmy_ble_prefs"
        private const val PREF_SAMSUNG_LOCK_PREFIX = "samsung_privacy_id_"
        private const val PREF_UWB_PROMPTED = "uwb_permission_prompted"

        private const val SCAN_TIMEOUT_MS = 120_000L
        private const val EMIT_INTERVAL_MS = 250L
        private const val QUICK_SCAN_TIMEOUT_MS = 3_500L
        private const val GATT_TIMEOUT_MS = 10_000L

        val UUID_FEAA: UUID = UUID.fromString("0000FEAA-0000-1000-8000-00805F9B34FB")
        val UUID_FD5A: UUID = UUID.fromString("0000FD5A-0000-1000-8000-00805F9B34FB")
        val UUID_FAST_PAIR_SERVICE: UUID = UUID.fromString("0000FE2C-0000-1000-8000-00805F9B34FB")
        val UUID_BEACON_ACTIONS_CHAR: UUID = UUID.fromString("FE2C1238-8366-4814-8EB0-01DE32100BEA")
        val UUID_CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB")

        fun register(engine: FlutterEngine, activity: FlutterFragmentActivity) {
            val host = FindMyBleHost(activity)
            MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
                host.onMethodCall(call, result)
            }
            EventChannel(engine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(host.streamHandler)
        }

        fun parseGoogleFmdnServiceData(data: ByteArray): GoogleFmdnFrame? {
            if (data.isEmpty()) return null
            val header = data[0].toInt() and 0xFF
            if ((header and 0xF0) != 0x40) return null
            val eidLen = when {
                data.size >= 33 -> 32
                data.size >= 21 -> 20
                else -> return null
            }
            val eidHex = data.copyOfRange(1, 1 + eidLen).toHex()
            return GoogleFmdnFrame(frameType = header, eidHex = eidHex, eidByteLength = eidLen)
        }

        fun parseSamsungSmartTagServiceData(data: ByteArray): SamsungSmartTagFrame? {
            if (data.size < 20) return null
            val state = data[0].toInt() and 0xFF
            val agingCounter = ((data[1].toInt() and 0xFF) shl 16) or
                ((data[2].toInt() and 0xFF) shl 8) or
                (data[3].toInt() and 0xFF)
            val privacyIdHex = data.copyOfRange(4, 12).toHex()
            val flags = data[12].toInt() and 0xFF
            val uwbCapable = (flags and 0x04) != 0
            val batteryBits = (state shr 5) and 0x03
            return SamsungSmartTagFrame(
                state = state,
                agingCounter = agingCounter,
                privacyIdHex = privacyIdHex,
                uwbCapable = uwbCapable,
                batteryLevel = batteryBits,
            )
        }

        fun stateMaskForComponent(stop: Boolean, component: String?): Int {
            if (stop) return 0x00
            return when (component?.lowercase()) {
                "right", "r" -> 0x01
                "left", "l" -> 0x02
                "case" -> 0x04
                else -> 0xFF
            }
        }

        fun buildGoogleRingPacket(
            challenge9: ByteArray,
            ringKey: ByteArray,
            stateMask: Int,
            timeoutSeconds: Int = 600,
            volume: Int = 0,
        ): ByteArray {
            require(challenge9.size >= 9) { "Expected 9-byte challenge" }
            require(ringKey.isNotEmpty()) { "ringKey must not be empty" }

            val version = challenge9[0]
            val nonce = challenge9.copyOfRange(1, 9)
            val additionalData = byteArrayOf(
                (stateMask and 0xFF).toByte(),
                ((timeoutSeconds ushr 8) and 0xFF).toByte(),
                (timeoutSeconds and 0xFF).toByte(),
                (volume and 0xFF).toByte(),
            )

            // HMAC-SHA256(ringKey, version || nonce || 0x05 || 0x0C || additionalData)[0:8]
            val macInput = ByteArray(1 + 8 + 2 + additionalData.size)
            macInput[0] = version
            System.arraycopy(nonce, 0, macInput, 1, 8)
            macInput[9] = 0x05
            macInput[10] = 0x0C
            System.arraycopy(additionalData, 0, macInput, 11, additionalData.size)

            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(ringKey, "HmacSHA256"))
            val mac8 = mac.doFinal(macInput).copyOfRange(0, 8)

            val packet = ByteArray(14)
            packet[0] = 0x05
            packet[1] = 0x0C
            System.arraycopy(mac8, 0, packet, 2, 8)
            System.arraycopy(additionalData, 0, packet, 10, 4)
            return packet
        }

        fun estimateDistanceMeters(rssi: Double, txPower: Double = -59.0, n: Double = 2.4): Double {
            return 10.0.pow((txPower - rssi) / (10.0 * n)).coerceIn(0.1, 100.0)
        }

        fun zoneForDistance(meters: Double): String = when {
            meters <= 1.2 -> "here"
            meters <= 3.5 -> "near"
            meters <= 10.0 -> "not_far"
            else -> "far"
        }

        fun computeTrend(prevEma: Double?, nextEma: Double): String {
            if (prevEma == null) return "steady"
            val delta = nextEma - prevEma
            return when {
                delta >= 1.5 -> "stronger"
                delta <= -1.5 -> "weaker"
                else -> "steady"
            }
        }

        fun buildScanFilters(serviceUuid: UUID): List<ScanFilter> {
            val parcel = ParcelUuid(serviceUuid)
            // Match both AD 0x03 service UUIDs and AD 0x16 service-data-only beacons (0xFEAA/0xFD5A).
            return listOf(
                ScanFilter.Builder().setServiceUuid(parcel).build(),
                ScanFilter.Builder().setServiceData(parcel, byteArrayOf(0), byteArrayOf(0)).build(),
            )
        }

        fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

        fun hexToBytes(hex: String): ByteArray {
            val clean = hex.trim().lowercase()
            require(clean.length % 2 == 0) { "Odd hex length" }
            return ByteArray(clean.length / 2) { i ->
                clean.substring(i * 2, i * 2 + 2).toInt(16).toByte()
            }
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val workerExecutor = Executors.newSingleThreadExecutor()
    private val prefs by lazy { activity.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE) }

    private var pendingPermResult: MethodChannel.Result? = null
    private val permLauncher: ActivityResultLauncher<Array<String>> =
        activity.activityResultRegistry.register(
            "findmy_ble_permissions",
            ActivityResultContracts.RequestMultiplePermissions(),
        ) { grants ->
            val result = pendingPermResult
            pendingPermResult = null
            if (result != null) {
                val allGranted = grants.values.isNotEmpty() && grants.values.all { it }
                result.success(allGranted || hasBlePermissions())
            }
        }

    // Active scan state
    private var eventSink: EventChannel.EventSink? = null
    private var activeScanCallback: ScanCallback? = null
    private var activeScanner: BluetoothLeScanner? = null
    private var scanTimeoutRunnable: Runnable? = null
    private var emitRunnable: Runnable? = null

    private var scanProvider: String = "gfind"
    private var scanDeviceId: String = ""
    private var expectedEids: Set<String> = emptySet()
    private var expectedPrivacyIds: Set<String> = emptySet()
    private var lockedPrivacyId: String? = null
    private var matchedBleAddress: String? = null
    private var matchedProvider: String? = null
    private var matchedDeviceId: String? = null
    private var emaRssi: Double? = null
    private var prevEmittedEma: Double? = null
    private var lastSeenMs: Long = 0L

    private data class NearbyBeacon(
        val privacyId: String,
        val address: String,
        var rssi: Int,
        var lastSeenMs: Long,
        val uwbCapable: Boolean,
        val batteryLevel: Int,
    )

    private val nearbySamsungBeacons = HashMap<String, NearbyBeacon>()

    private val lifecycleObserver = object : DefaultLifecycleObserver {
        override fun onPause(owner: LifecycleOwner) {
            stopScan()
        }

        override fun onDestroy(owner: LifecycleOwner) {
            stopScan()
            workerExecutor.shutdownNow()
        }
    }

    init {
        activity.lifecycle.addObserver(lifecycleObserver)
    }

    private fun requiredPermissions(): Array<String> {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }
    }

    private fun hasUwbHardware(): Boolean {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            activity.packageManager.hasSystemFeature(PackageManager.FEATURE_UWB)
    }

    private fun requestablePermissions(): Array<String> {
        val base = requiredPermissions()
        if (!hasUwbHardware()) return base
        return base + Manifest.permission.UWB_RANGING
    }

    private fun hasBlePermissions(): Boolean {
        return requiredPermissions().all {
            ContextCompat.checkSelfPermission(activity, it) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun needsUwbPrompt(): Boolean {
        if (!hasUwbHardware()) return false
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.UWB_RANGING) == PackageManager.PERMISSION_GRANTED) {
            return false
        }
        return !prefs.getBoolean(PREF_UWB_PROMPTED, false)
    }

    private fun bluetoothAdapter(): BluetoothAdapter? {
        val bm = activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        return bm?.adapter
    }

    private val streamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
            eventSink = events
            @Suppress("UNCHECKED_CAST")
            val args = arguments as? Map<String, Any?> ?: emptyMap()
            startScan(args)
        }

        override fun onCancel(arguments: Any?) {
            stopScan()
            eventSink = null
        }
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "checkPermissions" -> result.success(hasBlePermissions())
            "requestPermissions" -> {
                val promptUwb = needsUwbPrompt()
                if (hasBlePermissions() && !promptUwb) {
                    result.success(true)
                    return
                }
                if (pendingPermResult != null) {
                    result.error("busy", "Permission request already in progress", null)
                    return
                }
                if (promptUwb) {
                    prefs.edit().putBoolean(PREF_UWB_PROMPTED, true).apply()
                }
                pendingPermResult = result
                try {
                    permLauncher.launch(requestablePermissions())
                } catch (e: Throwable) {
                    pendingPermResult = null
                    result.error("permission_error", e.message ?: "Failed to launch permission prompt", null)
                }
            }
            "isBluetoothEnabled" -> result.success(bluetoothAdapter()?.isEnabled == true)
            "lockSamsungBeacon" -> {
                val deviceId = call.argument<String>("deviceId")
                val privacyIdHex = call.argument<String>("privacyIdHex")?.lowercase()
                if (deviceId.isNullOrBlank() || privacyIdHex.isNullOrBlank()) {
                    result.error("invalid_args", "Missing deviceId or privacyIdHex", null)
                    return
                }
                prefs.edit().putString("$PREF_SAMSUNG_LOCK_PREFIX$deviceId", privacyIdHex).apply()
                if (scanDeviceId == deviceId) {
                    lockedPrivacyId = privacyIdHex
                    val promoted = nearbySamsungBeacons.remove(privacyIdHex)
                    if (promoted != null) {
                        matchedBleAddress = promoted.address
                        matchedProvider = "utag"
                        matchedDeviceId = deviceId
                        updateRssi(promoted.rssi, promoted.lastSeenMs)
                        mainHandler.post { emitScanState() }
                    }
                }
                result.success(true)
            }
            "ringGoogleTag" -> handleRingGoogleTag(call, result)
            "canLaunchUwbApp" -> {
                val intent = buildUwbIntent(
                    provider = call.argument<String>("provider") ?: "",
                    rawId = "probe",
                    uwbPackage = call.argument<String>("uwbPackage"),
                    uwbAction = call.argument<String>("uwbAction"),
                    uwbClass = call.argument<String>("uwbClass"),
                    uwbExtraKey = call.argument<String>("uwbExtraKey"),
                    uwbFallbackPackage = call.argument<String>("uwbFallbackPackage"),
                )
                result.success(intent != null)
            }
            "launchUwbApp" -> {
                val intent = buildUwbIntent(
                    provider = call.argument<String>("provider") ?: "",
                    rawId = call.argument<String>("rawId") ?: "",
                    uwbPackage = call.argument<String>("uwbPackage"),
                    uwbAction = call.argument<String>("uwbAction"),
                    uwbClass = call.argument<String>("uwbClass"),
                    uwbExtraKey = call.argument<String>("uwbExtraKey"),
                    uwbFallbackPackage = call.argument<String>("uwbFallbackPackage"),
                )
                if (intent == null) {
                    result.success(false)
                } else {
                    try {
                        activity.startActivity(intent)
                        result.success(true)
                    } catch (e: Throwable) {
                        Log.w(TAG, "Failed to launch UWB app", e)
                        result.success(false)
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun buildUwbIntent(
        provider: String,
        rawId: String,
        uwbPackage: String?,
        uwbAction: String?,
        uwbClass: String?,
        uwbExtraKey: String?,
        uwbFallbackPackage: String?,
    ): Intent? {
        val pm = activity.packageManager
        if (provider == "utag") {
            val pkg = uwbPackage?.takeIf { it.isNotBlank() } ?: "com.kieronquinn.app.utag"
            if (pkg == "com.kieronquinn.app.utag" || !uwbClass.isNullOrBlank()) {
                val action = uwbAction?.takeIf { it.isNotBlank() } ?: "com.kieronquinn.app.utag.MAP"
                val cls = uwbClass?.takeIf { it.isNotBlank() } ?: "com.kieronquinn.app.utag.ui.activities.TagActivity"
                val extraKey = uwbExtraKey?.takeIf { it.isNotBlank() } ?: "target_id"
                val uTagIntent = Intent(action).apply {
                    component = ComponentName(pkg, cls)
                    if (rawId.isNotBlank()) putExtra(extraKey, rawId)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                if (pm.resolveActivity(uTagIntent, 0) != null) {
                    return uTagIntent
                }
            }
            if (pkg != "com.kieronquinn.app.utag") {
                pm.getLaunchIntentForPackage(pkg)?.let {
                    return it.apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
                }
            }
            val fallbackPkg = uwbFallbackPackage?.takeIf { it.isNotBlank() } ?: "com.samsung.android.oneconnect"
            return pm.getLaunchIntentForPackage(fallbackPkg)?.apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        }
        if (provider == "gfind") {
            val pkg = uwbPackage ?: "com.google.android.apps.adm"
            return pm.getLaunchIntentForPackage(pkg)?.apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        }
        return null
    }

    @SuppressLint("MissingPermission")
    private fun startScan(args: Map<String, Any?>) {
        stopScan()
        if (!hasBlePermissions()) {
            eventSink?.error("permission_denied", "Bluetooth scan permission not granted", null)
            return
        }
        val adapter = bluetoothAdapter()
        if (adapter == null || !adapter.isEnabled) {
            eventSink?.error("bluetooth_disabled", "Bluetooth is turned off", null)
            return
        }
        val scanner = adapter.bluetoothLeScanner
        if (scanner == null) {
            eventSink?.error("scanner_unavailable", "BLE scanner unavailable", null)
            return
        }

        scanProvider = (args["provider"] as? String) ?: "gfind"
        scanDeviceId = (args["deviceId"] as? String) ?: ""
        expectedEids = (args["eidsHex"] as? List<*>)?.mapNotNull { (it as? String)?.lowercase() }?.toSet() ?: emptySet()
        expectedPrivacyIds = (args["expectedPrivacyIdsHex"] as? List<*>)?.mapNotNull { (it as? String)?.lowercase() }?.toSet() ?: emptySet()
        lockedPrivacyId = prefs.getString("$PREF_SAMSUNG_LOCK_PREFIX$scanDeviceId", null)?.lowercase()
        matchedBleAddress = null
        matchedProvider = null
        matchedDeviceId = null
        emaRssi = null
        prevEmittedEma = null
        lastSeenMs = 0L
        nearbySamsungBeacons.clear()

        val targetUuid = if (scanProvider == "utag") UUID_FD5A else UUID_FEAA
        val filters = buildScanFilters(targetUuid)
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                handleScanResult(result)
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                results.forEach(::handleScanResult)
            }

            override fun onScanFailed(errorCode: Int) {
                mainHandler.post {
                    eventSink?.error("scan_failed", "BLE scan failed ($errorCode)", null)
                    stopScan()
                }
            }
        }

        activeScanner = scanner
        activeScanCallback = callback
        try {
            scanner.startScan(filters, settings, callback)
        } catch (e: Throwable) {
            eventSink?.error("scan_failed", e.message ?: "Failed to start BLE scan", null)
            return
        }

        val timeoutRunnable = Runnable {
            eventSink?.success(mapOf("type" to "timeout"))
            stopScan()
        }
        scanTimeoutRunnable = timeoutRunnable
        mainHandler.postDelayed(timeoutRunnable, SCAN_TIMEOUT_MS)

        val periodicEmit = object : Runnable {
            override fun run() {
                emitScanState()
                if (activeScanCallback != null) {
                    mainHandler.postDelayed(this, EMIT_INTERVAL_MS)
                }
            }
        }
        emitRunnable = periodicEmit
        mainHandler.postDelayed(periodicEmit, EMIT_INTERVAL_MS)
    }

    @SuppressLint("MissingPermission")
    private fun stopScan() {
        scanTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        scanTimeoutRunnable = null
        emitRunnable?.let { mainHandler.removeCallbacks(it) }
        emitRunnable = null
        val cb = activeScanCallback
        val scanner = activeScanner
        activeScanCallback = null
        activeScanner = null
        scanDeviceId = ""
        expectedEids = emptySet()
        expectedPrivacyIds = emptySet()
        lockedPrivacyId = null
        matchedBleAddress = null
        matchedProvider = null
        matchedDeviceId = null
        emaRssi = null
        prevEmittedEma = null
        lastSeenMs = 0L
        nearbySamsungBeacons.clear()
        if (cb != null && scanner != null) {
            try {
                scanner.stopScan(cb)
            } catch (_: Throwable) {
            }
        }
    }

    private fun handleScanResult(result: ScanResult) {
        val record = result.scanRecord ?: return
        val now = System.currentTimeMillis()
        val rssi = result.rssi
        val address = result.device?.address ?: return

        if (scanProvider == "gfind") {
            val data = record.getServiceData(ParcelUuid(UUID_FEAA)) ?: return
            val frame = parseGoogleFmdnServiceData(data) ?: return
            if (expectedEids.isNotEmpty() && frame.eidHex !in expectedEids) return
            matchedBleAddress = address
            matchedProvider = "gfind"
            matchedDeviceId = scanDeviceId
            updateRssi(rssi, now)
        } else if (scanProvider == "utag") {
            val data = record.getServiceData(ParcelUuid(UUID_FD5A)) ?: return
            val frame = parseSamsungSmartTagServiceData(data) ?: return
            val isExpected = frame.privacyIdHex in expectedPrivacyIds ||
                (lockedPrivacyId != null && frame.privacyIdHex == lockedPrivacyId)
            if (isExpected) {
                nearbySamsungBeacons.remove(frame.privacyIdHex)
                matchedBleAddress = address
                matchedProvider = "utag"
                matchedDeviceId = scanDeviceId
                updateRssi(rssi, now)
            } else {
                nearbySamsungBeacons[frame.privacyIdHex] = NearbyBeacon(
                    privacyId = frame.privacyIdHex,
                    address = address,
                    rssi = rssi,
                    lastSeenMs = now,
                    uwbCapable = frame.uwbCapable,
                    batteryLevel = frame.batteryLevel,
                )
            }
        }
    }

    private fun updateRssi(rssi: Int, now: Long) {
        val current = emaRssi
        emaRssi = if (current == null) rssi.toDouble() else current * 0.65 + rssi * 0.35
        lastSeenMs = now
    }

    private fun emitScanState() {
        val sink = eventSink ?: return
        val now = System.currentTimeMillis()
        val currentEma = emaRssi

        val nearbyList = nearbySamsungBeacons.values
            .filter { now - it.lastSeenMs <= 6_000L }
            .sortedByDescending { it.rssi }
            .take(5)
            .map {
                mapOf(
                    "privacyIdHex" to it.privacyId,
                    "bleAddress" to it.address,
                    "rssi" to it.rssi,
                    "uwbCapable" to it.uwbCapable,
                )
            }

        if (currentEma == null || (now - lastSeenMs) > 4_000L) {
            sink.success(
                mapOf(
                    "matched" to false,
                    "gattRingReady" to false,
                    "nearbyBeacons" to nearbyList,
                ),
            )
            return
        }

        val meters = estimateDistanceMeters(currentEma)
        val zone = zoneForDistance(meters)
        val trend = computeTrend(prevEmittedEma, currentEma)
        prevEmittedEma = currentEma

        sink.success(
            mapOf(
                "matched" to true,
                "rssi" to currentEma,
                "meters" to meters,
                "zone" to zone,
                "trend" to trend,
                "bleAddress" to matchedBleAddress,
                "gattRingReady" to (scanProvider == "gfind" && matchedBleAddress != null),
                "nearbyBeacons" to nearbyList,
            ),
        )
    }

    @SuppressLint("MissingPermission")
    private fun handleRingGoogleTag(call: MethodCall, result: MethodChannel.Result) {
        if (!hasBlePermissions()) {
            result.error("permission_denied", "Bluetooth permissions required", null)
            return
        }
        val adapter = bluetoothAdapter()
        if (adapter == null || !adapter.isEnabled) {
            result.error("bluetooth_disabled", "Bluetooth is turned off", null)
            return
        }
        val ringKeyHex = call.argument<String>("ringKeyHex")
        if (ringKeyHex.isNullOrBlank()) {
            result.error("invalid_args", "Missing ringKeyHex", null)
            return
        }
        val requestedDeviceId = call.argument<String>("deviceId")?.takeIf { it.isNotBlank() }
        val eidsHex = call.argument<List<String>>("eidsHex")?.map { it.lowercase() }?.toSet() ?: emptySet()
        val providedAddr = call.argument<String>("bleAddress")?.takeIf { it.isNotBlank() }
        val stop = call.argument<Boolean>("stop") ?: false
        val component = call.argument<String>("component")

        workerExecutor.execute {
            try {
                val activeMatchAddr = if (
                    matchedProvider == "gfind" &&
                    matchedDeviceId != null &&
                    (requestedDeviceId == null || requestedDeviceId == matchedDeviceId)
                ) {
                    matchedBleAddress
                } else {
                    null
                }
                val cachedAddr = providedAddr ?: activeMatchAddr
                var targetAddr = cachedAddr ?: findGoogleTagAddress(adapter, eidsHex)
                if (targetAddr == null) {
                    mainHandler.post { result.error("not_found", "Tag not found in BLE range", null) }
                    return@execute
                }
                val ringKey = hexToBytes(ringKeyHex)
                val stateMask = stateMaskForComponent(stop = stop, component = component)
                var ok = executeGattRing(adapter.getRemoteDevice(targetAddr), ringKey, stateMask)
                // Cached RPA addresses rotate; rescan once by EID before failing.
                if (!ok && cachedAddr != null && eidsHex.isNotEmpty()) {
                    val freshAddr = findGoogleTagAddress(adapter, eidsHex)
                    if (freshAddr != null && freshAddr != targetAddr) {
                        targetAddr = freshAddr
                        ok = executeGattRing(adapter.getRemoteDevice(freshAddr), ringKey, stateMask)
                        if (ok && activeScanCallback != null && scanProvider == "gfind" &&
                            (requestedDeviceId == null || requestedDeviceId == scanDeviceId)
                        ) {
                            matchedBleAddress = freshAddr
                            matchedProvider = "gfind"
                            matchedDeviceId = scanDeviceId
                        }
                    }
                }
                mainHandler.post {
                    if (ok) {
                        result.success(mapOf("ok" to true, "bleAddress" to targetAddr))
                    } else {
                        result.error("gatt_failed", "Direct BLE GATT ring failed", null)
                    }
                }
            } catch (e: Throwable) {
                Log.w(TAG, "ringGoogleTag error", e)
                mainHandler.post { result.error("gatt_error", e.message ?: "BLE ring error", null) }
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun findGoogleTagAddress(adapter: BluetoothAdapter, eidsHex: Set<String>): String? {
        if (eidsHex.isEmpty()) return null
        val scanner = adapter.bluetoothLeScanner ?: return null
        val latch = CountDownLatch(1)
        val found = AtomicReference<String?>(null)
        val filters = buildScanFilters(UUID_FEAA)
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val data = result.scanRecord?.getServiceData(ParcelUuid(UUID_FEAA)) ?: return
                val frame = parseGoogleFmdnServiceData(data) ?: return
                if (frame.eidHex in eidsHex) {
                    if (found.compareAndSet(null, result.device?.address)) {
                        latch.countDown()
                    }
                }
            }
        }
        try {
            scanner.startScan(filters, settings, cb)
            latch.await(QUICK_SCAN_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } finally {
            try {
                scanner.stopScan(cb)
            } catch (_: Throwable) {
            }
        }
        return found.get()
    }

    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    private fun executeGattRing(device: BluetoothDevice, ringKey: ByteArray, stateMask: Int): Boolean {
        val doneLatch = CountDownLatch(1)
        val succeeded = AtomicBoolean(false)
        val gattRef = AtomicReference<BluetoothGatt?>(null)
        val actionCharRef = AtomicReference<BluetoothGattCharacteristic?>(null)
        val challengeSent = AtomicBoolean(false)

        fun finish(ok: Boolean) {
            if (ok) succeeded.set(true)
            doneLatch.countDown()
        }

        val callback = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    finish(false)
                    return
                }
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    gatt.discoverServices()
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    doneLatch.countDown()
                }
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    finish(false)
                    return
                }
                val service = gatt.getService(UUID_FAST_PAIR_SERVICE)
                val char = service?.getCharacteristic(UUID_BEACON_ACTIONS_CHAR)
                if (char == null) {
                    finish(false)
                    return
                }
                actionCharRef.set(char)
                gatt.setCharacteristicNotification(char, true)
                val cccd = char.getDescriptor(UUID_CCCD)
                if (cccd != null) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        gatt.writeDescriptor(cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                    } else {
                        cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                        gatt.writeDescriptor(cccd)
                    }
                } else {
                    gatt.readCharacteristic(char)
                }
            }

            override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    finish(false)
                    return
                }
                val char = actionCharRef.get()
                if (char == null || !gatt.readCharacteristic(char)) {
                    finish(false)
                }
            }

            private fun handleChallengeRead(gatt: BluetoothGatt, value: ByteArray, status: Int) {
                if (status != BluetoothGatt.GATT_SUCCESS || value.size < 9) {
                    finish(false)
                    return
                }
                val char = actionCharRef.get() ?: run {
                    finish(false)
                    return
                }
                try {
                    val packet = buildGoogleRingPacket(value, ringKey, stateMask)
                    challengeSent.set(true)
                    val started = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        gatt.writeCharacteristic(
                            char,
                            packet,
                            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
                        ) == BluetoothGatt.GATT_SUCCESS
                    } else {
                        char.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                        char.value = packet
                        gatt.writeCharacteristic(char)
                    }
                    if (!started) finish(false)
                } catch (e: Throwable) {
                    Log.w(TAG, "Failed to build/write ring packet", e)
                    finish(false)
                }
            }

            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray,
                status: Int,
            ) {
                handleChallengeRead(gatt, value, status)
            }

            @Deprecated("Deprecated in API 33")
            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                handleChallengeRead(gatt, characteristic.value ?: ByteArray(0), status)
            }

            override fun onCharacteristicWrite(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                if (challengeSent.get()) {
                    finish(status == BluetoothGatt.GATT_SUCCESS)
                }
            }

            override fun onCharacteristicChanged(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray,
            ) {
                if (challengeSent.get()) finish(true)
            }

            @Deprecated("Deprecated in API 33")
            override fun onCharacteristicChanged(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
            ) {
                if (challengeSent.get()) finish(true)
            }
        }

        try {
            val gatt = device.connectGatt(activity, false, callback, BluetoothDevice.TRANSPORT_LE)
            gattRef.set(gatt)
            doneLatch.await(GATT_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } finally {
            gattRef.get()?.let { g ->
                try {
                    g.disconnect()
                } catch (_: Throwable) {
                }
                try {
                    g.close()
                } catch (_: Throwable) {
                }
            }
        }
        return succeeded.get()
    }
}
