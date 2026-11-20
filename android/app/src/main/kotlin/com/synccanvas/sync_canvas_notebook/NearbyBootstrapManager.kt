package com.synccanvas.sync_canvas_notebook

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque
import java.util.UUID

class NearbyBootstrapManager(
    private val activity: Activity,
    private val channel: MethodChannel,
) {
    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("53594E43-4341-4E56-4153-303030303837")
        val BEACON_CHAR_UUID: UUID = UUID.fromString("53594E43-4341-4E56-4153-303030303838")

        const val REQ_BLE_ADVERTISE = 9301
        const val REQ_BLE_SCAN = 9302
        const val REQ_HOTSPOT = 9303
    }

    private data class QueuedGattTarget(
        val device: BluetoothDevice,
        val rssi: Int,
    )

    private val mainHandler = Handler(Looper.getMainLooper())
    private val bluetoothManager: BluetoothManager?
        get() = activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val wifiManager: WifiManager?
        get() = activity.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    private val connectivityManager: ConnectivityManager?
        get() = activity.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager

    private var multicastLock: WifiManager.MulticastLock? = null

    // BLE Advertising state
    private var gattServer: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var advertisedBytes: ByteArray = ByteArray(0)
    private var pendingAdvertiseJson: String? = null
    private var pendingAdvertiseResult: MethodChannel.Result? = null

    // BLE Scanning state
    private var scanner: BluetoothLeScanner? = null
    private var scanCallback: ScanCallback? = null
    private var isScanning = false
    private var pendingScanResult: MethodChannel.Result? = null
    private val lastDeviceReadMs = HashMap<String, Long>()
    private val gattQueue = ArrayDeque<QueuedGattTarget>()
    private var activeGatt: BluetoothGatt? = null
    private var activeGattTimeout: Runnable? = null

    // LocalOnlyHotspot state
    private var hotspotReservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var pendingHotspotResult: MethodChannel.Result? = null

    // Client Hotspot network binding state
    private var hotspotNetworkCallback: ConnectivityManager.NetworkCallback? = null
    private var pendingConnectResult: MethodChannel.Result? = null

    fun setMulticastLock(enabled: Boolean) {
        try {
            if (enabled) {
                if (multicastLock == null) {
                    multicastLock = wifiManager?.createMulticastLock("SyncCanvasUdpDiscovery")?.apply {
                        setReferenceCounted(false)
                    }
                }
                if (multicastLock?.isHeld == false) {
                    multicastLock?.acquire()
                }
            } else {
                if (multicastLock?.isHeld == true) {
                    multicastLock?.release()
                }
            }
        } catch (_: Exception) {
        }
    }

    fun startBleAdvertising(beaconJson: String, result: MethodChannel.Result) {
        val missing = missingBlePermissions(forAdvertise = true)
        if (missing.isNotEmpty()) {
            pendingAdvertiseResult?.success(mapOf("ok" to false, "error" to "已取消"))
            pendingAdvertiseResult = result
            pendingAdvertiseJson = beaconJson
            activity.requestPermissions(missing.toTypedArray(), REQ_BLE_ADVERTISE)
            return
        }
        startBleAdvertisingInternal(beaconJson, result)
    }

    @SuppressLint("MissingPermission")
    private fun startBleAdvertisingInternal(beaconJson: String, result: MethodChannel.Result) {
        val manager = bluetoothManager
        val adapter: BluetoothAdapter? = manager?.adapter
        if (adapter == null || !adapter.isEnabled) {
            result.success(mapOf("ok" to false, "error" to "请先开启系统蓝牙"))
            return
        }

        advertisedBytes = beaconJson.toByteArray(Charsets.UTF_8)

        // If already advertising, just update the characteristic payload in place.
        if (gattServer != null && advertiseCallback != null) {
            result.success(mapOf("ok" to true))
            return
        }

        val bleAdvertiser = adapter.bluetoothLeAdvertiser
        if (bleAdvertiser == null) {
            result.success(mapOf("ok" to false, "error" to "当前设备不支持 BLE 外设广播"))
            return
        }

        stopBleAdvertising()
        advertisedBytes = beaconJson.toByteArray(Charsets.UTF_8)

        try {
            val server = manager.openGattServer(
                activity,
                object : BluetoothGattServerCallback() {
                    override fun onCharacteristicReadRequest(
                        device: BluetoothDevice,
                        requestId: Int,
                        offset: Int,
                        characteristic: BluetoothGattCharacteristic,
                    ) {
                        if (characteristic.uuid != BEACON_CHAR_UUID) {
                            gattServer?.sendResponse(
                                device,
                                requestId,
                                BluetoothGatt.GATT_FAILURE,
                                offset,
                                null,
                            )
                            return
                        }
                        val bytes = advertisedBytes
                        val slice = if (offset >= bytes.size) {
                            ByteArray(0)
                        } else {
                            bytes.copyOfRange(offset, bytes.size)
                        }
                        gattServer?.sendResponse(
                            device,
                            requestId,
                            BluetoothGatt.GATT_SUCCESS,
                            offset,
                            slice,
                        )
                    }
                },
            )
            if (server == null) {
                result.success(mapOf("ok" to false, "error" to "无法创建 BLE GATT 服务"))
                return
            }

            val service = BluetoothGattService(
                SERVICE_UUID,
                BluetoothGattService.SERVICE_TYPE_PRIMARY,
            )
            val char = BluetoothGattCharacteristic(
                BEACON_CHAR_UUID,
                BluetoothGattCharacteristic.PROPERTY_READ,
                BluetoothGattCharacteristic.PERMISSION_READ,
            )
            service.addCharacteristic(char)
            server.addService(service)
            gattServer = server

            val settings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
                .setConnectable(true)
                .setTimeout(0)
                .build()

            val data = AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .addServiceUuid(ParcelUuid(SERVICE_UUID))
                .build()

            var replied = false
            val cb = object : AdvertiseCallback() {
                override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                    if (!replied) {
                        replied = true
                        mainHandler.post { result.success(mapOf("ok" to true)) }
                    }
                }

                override fun onStartFailure(errorCode: Int) {
                    if (!replied) {
                        replied = true
                        mainHandler.post {
                            result.success(mapOf("ok" to false, "error" to "BLE 广播启动失败 ($errorCode)"))
                        }
                    }
                }
            }
            advertiseCallback = cb
            advertiser = bleAdvertiser
            bleAdvertiser.startAdvertising(settings, data, cb)
        } catch (e: Exception) {
            stopBleAdvertising()
            result.success(mapOf("ok" to false, "error" to (e.message ?: "BLE 广播异常")))
        }
    }

    @SuppressLint("MissingPermission")
    fun stopBleAdvertising() {
        try {
            advertiseCallback?.let { advertiser?.stopAdvertising(it) }
        } catch (_: Exception) {
        }
        advertiseCallback = null
        advertiser = null
        try {
            gattServer?.close()
        } catch (_: Exception) {
        }
        gattServer = null
    }

    fun startBleScanning(result: MethodChannel.Result) {
        val missing = missingBlePermissions(forAdvertise = false)
        if (missing.isNotEmpty()) {
            pendingScanResult?.success(mapOf("ok" to false, "error" to "已取消"))
            pendingScanResult = result
            activity.requestPermissions(missing.toTypedArray(), REQ_BLE_SCAN)
            return
        }
        startBleScanningInternal(result)
    }

    @SuppressLint("MissingPermission")
    private fun startBleScanningInternal(result: MethodChannel.Result) {
        val adapter = bluetoothManager?.adapter
        if (adapter == null || !adapter.isEnabled) {
            result.success(mapOf("ok" to false, "error" to "请先开启系统蓝牙"))
            return
        }
        val leScanner = adapter.bluetoothLeScanner
        if (leScanner == null) {
            result.success(mapOf("ok" to false, "error" to "当前设备不支持 BLE 扫描"))
            return
        }

        if (isScanning) {
            result.success(mapOf("ok" to true))
            return
        }

        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, scanResult: ScanResult) {
                val device = scanResult.device ?: return
                val address = device.address ?: return
                val now = SystemClock.elapsedRealtime()
                val last = lastDeviceReadMs[address] ?: 0L
                if (now - last < 6000L) return
                lastDeviceReadMs[address] = now

                if (gattQueue.none { it.device.address == address }) {
                    gattQueue.addLast(QueuedGattTarget(device, scanResult.rssi))
                    drainGattQueue()
                }
            }
        }

        try {
            scanCallback = cb
            scanner = leScanner
            isScanning = true
            leScanner.startScan(listOf(filter), settings, cb)
            result.success(mapOf("ok" to true))
        } catch (e: Exception) {
            isScanning = false
            scanCallback = null
            result.success(mapOf("ok" to false, "error" to (e.message ?: "BLE 扫描失败")))
        }
    }

    @SuppressLint("MissingPermission")
    fun stopBleScanning() {
        isScanning = false
        try {
            scanCallback?.let { scanner?.stopScan(it) }
        } catch (_: Exception) {
        }
        scanCallback = null
        scanner = null
        gattQueue.clear()
        cleanupActiveGatt()
    }

    @SuppressLint("MissingPermission")
    private fun drainGattQueue() {
        if (activeGatt != null) return
        val next = gattQueue.pollFirst() ?: return

        val timeoutRunnable = Runnable {
            cleanupActiveGatt()
            drainGattQueue()
        }
        activeGattTimeout = timeoutRunnable
        mainHandler.postDelayed(timeoutRunnable, 5500L)

        var handledRead = false
        val cb = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
                if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) {
                    mainHandler.post {
                        cleanupActiveGatt()
                        drainGattQueue()
                    }
                    return
                }
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    if (!gatt.requestMtu(512)) {
                        gatt.discoverServices()
                    }
                }
            }

            override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
                gatt.discoverServices()
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    mainHandler.post {
                        cleanupActiveGatt()
                        drainGattQueue()
                    }
                    return
                }
                val service = gatt.getService(SERVICE_UUID)
                val char = service?.getCharacteristic(BEACON_CHAR_UUID)
                if (char == null || !gatt.readCharacteristic(char)) {
                    mainHandler.post {
                        cleanupActiveGatt()
                        drainGattQueue()
                    }
                }
            }

            @Deprecated("Used on API < 33")
            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                @Suppress("DEPRECATION")
                val bytes = characteristic.value
                handleCharacteristicBytes(characteristic, bytes, status)
            }

            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray,
                status: Int,
            ) {
                handleCharacteristicBytes(characteristic, value, status)
            }

            private fun handleCharacteristicBytes(
                characteristic: BluetoothGattCharacteristic,
                bytes: ByteArray?,
                status: Int,
            ) {
                if (handledRead) return
                handledRead = true
                if (status == BluetoothGatt.GATT_SUCCESS &&
                    characteristic.uuid == BEACON_CHAR_UUID &&
                    bytes != null &&
                    bytes.isNotEmpty()
                ) {
                    val jsonText = String(bytes, Charsets.UTF_8)
                    mainHandler.post {
                        channel.invokeMethod(
                            "onBleBeaconDiscovered",
                            mapOf("json" to jsonText, "rssi" to next.rssi),
                        )
                    }
                }
                mainHandler.post {
                    cleanupActiveGatt()
                    drainGattQueue()
                }
            }
        }

        try {
            activeGatt = next.device.connectGatt(
                activity,
                false,
                cb,
                BluetoothDevice.TRANSPORT_LE,
            )
            if (activeGatt == null) {
                cleanupActiveGatt()
                drainGattQueue()
            }
        } catch (_: Exception) {
            cleanupActiveGatt()
            drainGattQueue()
        }
    }

    @SuppressLint("MissingPermission")
    private fun cleanupActiveGatt() {
        activeGattTimeout?.let { mainHandler.removeCallbacks(it) }
        activeGattTimeout = null
        try {
            activeGatt?.disconnect()
            activeGatt?.close()
        } catch (_: Exception) {
        }
        activeGatt = null
    }

    fun startLocalHotspot(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(mapOf("ok" to false, "error" to "本地直连热点需要 Android 8.0 及以上系统"))
            return
        }
        val missing = missingHotspotPermissions()
        if (missing.isNotEmpty()) {
            pendingHotspotResult?.success(mapOf("ok" to false, "error" to "已取消"))
            pendingHotspotResult = result
            activity.requestPermissions(missing.toTypedArray(), REQ_HOTSPOT)
            return
        }
        startLocalHotspotInternal(result)
    }

    @SuppressLint("MissingPermission")
    private fun startLocalHotspotInternal(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(mapOf("ok" to false, "error" to "本地直连热点需要 Android 8.0 及以上系统"))
            return
        }
        val existing = hotspotReservation
        if (existing != null) {
            val creds = extractHotspotCredentials(existing)
            result.success(
                mapOf(
                    "ok" to true,
                    "ssid" to creds.first,
                    "password" to creds.second,
                ),
            )
            return
        }

        val wifi = wifiManager
        if (wifi == null) {
            result.success(mapOf("ok" to false, "error" to "无法获取系统 Wi-Fi 服务"))
            return
        }

        var replied = false
        try {
            wifi.startLocalOnlyHotspot(
                object : WifiManager.LocalOnlyHotspotCallback() {
                    override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation) {
                        hotspotReservation = reservation
                        val creds = extractHotspotCredentials(reservation)
                        if (!replied) {
                            replied = true
                            mainHandler.post {
                                result.success(
                                    mapOf(
                                        "ok" to true,
                                        "ssid" to creds.first,
                                        "password" to creds.second,
                                    ),
                                )
                            }
                        }
                    }

                    override fun onStopped() {
                        hotspotReservation = null
                    }

                    override fun onFailed(reason: Int) {
                        hotspotReservation = null
                        if (!replied) {
                            replied = true
                            val message = when (reason) {
                                ERROR_TETHERING_DISALLOWED -> "系统限制了本地热点，请改用系统个人热点"
                                ERROR_INCOMPATIBLE_MODE -> "请先关闭系统个人热点后再开启本地直连热点"
                                else -> "开启本地热点失败 ($reason)，可改用系统个人热点"
                            }
                            mainHandler.post {
                                result.success(mapOf("ok" to false, "error" to message))
                            }
                        }
                    }
                },
                mainHandler,
            )
        } catch (e: Exception) {
            result.success(mapOf("ok" to false, "error" to (e.message ?: "无法开启本地热点")))
        }
    }

    private fun extractHotspotCredentials(
        reservation: WifiManager.LocalOnlyHotspotReservation,
    ): Pair<String, String> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val cfg = reservation.softApConfiguration
            if (cfg != null) {
                val rawSsid = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    cfg.wifiSsid?.bytes?.toString(Charsets.UTF_8) ?: ""
                } else {
                    @Suppress("DEPRECATION")
                    cfg.ssid ?: ""
                }
                val cleanSsid = rawSsid.trim().removeSurrounding("\"")
                val pass = cfg.passphrase ?: ""
                return cleanSsid to pass
            }
        }
        @Suppress("DEPRECATION")
        val wc = reservation.wifiConfiguration
        @Suppress("DEPRECATION")
        val cleanSsid = (wc?.SSID ?: "").trim().removeSurrounding("\"")
        @Suppress("DEPRECATION")
        val pass = wc?.preSharedKey ?: ""
        return cleanSsid to pass
    }

    fun stopLocalHotspot() {
        try {
            hotspotReservation?.close()
        } catch (_: Exception) {
        }
        hotspotReservation = null
    }

    fun connectToHotspot(ssid: String, password: String, result: MethodChannel.Result) {
        if (ssid.isBlank()) {
            result.success(mapOf("ok" to false, "error" to "热点名称为空"))
            return
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            copyToClipboard("Wi-Fi 密码", password)
            try {
                activity.startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
            } catch (_: Exception) {
            }
            result.success(
                mapOf(
                    "ok" to false,
                    "manualRequired" to true,
                    "error" to "已复制热点密码，请在系统 Wi-Fi 中连接 $ssid",
                ),
            )
            return
        }

        val cm = connectivityManager
        if (cm == null) {
            result.success(mapOf("ok" to false, "error" to "无法获取 ConnectivityManager"))
            return
        }

        unbindHotspot()
        pendingConnectResult?.success(mapOf("ok" to false, "error" to "已发起新的连接"))
        pendingConnectResult = result

        val specBuilder = WifiNetworkSpecifier.Builder().setSsid(ssid)
        if (password.isNotEmpty()) {
            specBuilder.setWpa2Passphrase(password)
        }
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specBuilder.build())
            .build()

        var finished = false
        val timeoutRunnable = Runnable {
            if (!finished) {
                finished = true
                pendingConnectResult = null
                unbindHotspot()
                result.success(mapOf("ok" to false, "error" to "连接热点超时或被取消"))
            }
        }
        mainHandler.postDelayed(timeoutRunnable, 25_000L)

        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                cm.bindProcessToNetwork(network)
                if (!finished) {
                    finished = true
                    mainHandler.removeCallbacks(timeoutRunnable)
                    pendingConnectResult = null
                    mainHandler.post { result.success(mapOf("ok" to true)) }
                }
            }

            override fun onUnavailable() {
                if (!finished) {
                    finished = true
                    mainHandler.removeCallbacks(timeoutRunnable)
                    pendingConnectResult = null
                    mainHandler.post {
                        result.success(mapOf("ok" to false, "error" to "未能连接到热点 $ssid"))
                    }
                }
            }

            override fun onLost(network: Network) {
                cm.bindProcessToNetwork(null)
            }
        }

        hotspotNetworkCallback = cb
        try {
            cm.requestNetwork(request, cb)
        } catch (e: Exception) {
            finished = true
            mainHandler.removeCallbacks(timeoutRunnable)
            pendingConnectResult = null
            hotspotNetworkCallback = null
            result.success(mapOf("ok" to false, "error" to (e.message ?: "请求热点网络失败")))
        }
    }

    fun unbindHotspot() {
        try {
            connectivityManager?.bindProcessToNetwork(null)
        } catch (_: Exception) {
        }
        try {
            hotspotNetworkCallback?.let { connectivityManager?.unregisterNetworkCallback(it) }
        } catch (_: Exception) {
        }
        hotspotNetworkCallback = null
    }

    fun openSystemHotspotSettings() {
        val candidates = listOf(
            Intent("android.settings.TETHER_SETTINGS"),
            Intent(Settings.ACTION_WIRELESS_SETTINGS),
            Intent(Settings.ACTION_SETTINGS),
        )
        for (intent in candidates) {
            try {
                activity.startActivity(intent)
                return
            } catch (_: Exception) {
            }
        }
    }

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray) {
        val granted = grantResults.isNotEmpty() &&
            grantResults.all { it == PackageManager.PERMISSION_GRANTED }

        when (requestCode) {
            REQ_BLE_ADVERTISE -> {
                val cb = pendingAdvertiseResult
                val json = pendingAdvertiseJson
                pendingAdvertiseResult = null
                pendingAdvertiseJson = null
                if (cb != null) {
                    if (granted && json != null) {
                        startBleAdvertisingInternal(json, cb)
                    } else {
                        cb.success(mapOf("ok" to false, "error" to "未授予蓝牙广播权限"))
                    }
                }
            }
            REQ_BLE_SCAN -> {
                val cb = pendingScanResult
                pendingScanResult = null
                if (cb != null) {
                    if (granted) {
                        startBleScanningInternal(cb)
                    } else {
                        cb.success(mapOf("ok" to false, "error" to "未授予蓝牙扫描权限"))
                    }
                }
            }
            REQ_HOTSPOT -> {
                val cb = pendingHotspotResult
                pendingHotspotResult = null
                if (cb != null) {
                    if (granted) {
                        startLocalHotspotInternal(cb)
                    } else {
                        cb.success(mapOf("ok" to false, "error" to "未授予开启本地热点的附近设备/定位权限"))
                    }
                }
            }
        }
    }

    fun dispose() {
        stopBleScanning()
        stopBleAdvertising()
        stopLocalHotspot()
        unbindHotspot()
        setMulticastLock(false)
        mainHandler.removeCallbacksAndMessages(null)
    }

    private fun missingBlePermissions(forAdvertise: Boolean): List<String> {
        val needed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (forAdvertise) {
                listOf(
                    Manifest.permission.BLUETOOTH_ADVERTISE,
                    Manifest.permission.BLUETOOTH_CONNECT,
                )
            } else {
                listOf(
                    Manifest.permission.BLUETOOTH_SCAN,
                    Manifest.permission.BLUETOOTH_CONNECT,
                )
            }
        } else {
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        return needed.filter {
            activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
    }

    private fun missingHotspotPermissions(): List<String> {
        val needed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            listOf(Manifest.permission.NEARBY_WIFI_DEVICES)
        } else {
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        return needed.filter {
            activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
    }

    private fun copyToClipboard(label: String, text: String) {
        val cm = activity.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        cm?.setPrimaryClip(ClipData.newPlainText(label, text))
    }
}
