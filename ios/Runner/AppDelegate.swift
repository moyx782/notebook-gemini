import CoreBluetooth
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var bleBridge: SyncCanvasIosBleBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "com.synccanvas/native_bridge",
      binaryMessenger: engineBridge.applicationRegistrar.messenger
    )
    bleBridge = SyncCanvasIosBleBridge(channel: channel)
  }
}

private final class SyncCanvasIosBleBridge: NSObject, CBCentralManagerDelegate, CBPeripheralManagerDelegate, CBPeripheralDelegate {
  private static let serviceUuid = CBUUID(string: "53594E43-4341-4E56-4153-303030303837")
  private static let charUuid = CBUUID(string: "53594E43-4341-4E56-4153-303030303838")

  private let channel: FlutterMethodChannel
  private var centralManager: CBCentralManager?
  private var peripheralManager: CBPeripheralManager?

  private var wantsAdvertising = false
  private var wantsScanning = false
  private var beaconData = Data()
  private var servicePublished = false
  private var pendingAdvertiseResult: FlutterResult?
  private var pendingScanResult: FlutterResult?

  private var trackedPeripherals: [UUID: CBPeripheral] = [:]
  private var peripheralRssi: [UUID: Int] = [:]
  private var lastReadAt: [UUID: Date] = [:]

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleCall(call, result: result)
    }
  }

  private func handleCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startBleAdvertising":
      let args = call.arguments as? [String: Any]
      let json = args?["beaconJson"] as? String ?? ""
      startAdvertising(json: json, result: result)
    case "stopBleAdvertising":
      stopAdvertising()
      result(true)
    case "startBleScanning":
      startScanning(result: result)
    case "stopBleScanning":
      stopScanning()
      result(true)
    case "setMulticastLock", "stopLocalHotspot", "unbindHotspot", "openSystemHotspotSettings":
      result(true)
    case "startLocalHotspot", "connectToHotspot":
      result(["ok": false, "error": "仅 Android 原生端支持自动热点切换"])
    case "getAppFilesDir", "pickImage", "scanQrCode":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startAdvertising(json: String, result: @escaping FlutterResult) {
    beaconData = Data(json.utf8)
    wantsAdvertising = true

    if peripheralManager == nil {
      pendingAdvertiseResult = result
      peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
      return
    }

    guard let pm = peripheralManager else {
      result(["ok": false, "error": "蓝牙初始化失败"])
      return
    }

    switch pm.state {
    case .poweredOn:
      publishAndAdvertise(pm: pm)
      result(["ok": true])
    case .unauthorized:
      wantsAdvertising = false
      result(["ok": false, "error": "请在系统设置中授予蓝牙权限"])
    case .unsupported:
      wantsAdvertising = false
      result(["ok": false, "error": "当前设备不支持 BLE 广播"])
    case .poweredOff:
      wantsAdvertising = false
      result(["ok": false, "error": "请先开启系统蓝牙"])
    default:
      pendingAdvertiseResult = result
    }
  }

  private func publishAndAdvertise(pm: CBPeripheralManager) {
    if !servicePublished {
      let char = CBMutableCharacteristic(
        type: Self.charUuid,
        properties: [.read],
        value: nil,
        permissions: [.readable]
      )
      let service = CBMutableService(type: Self.serviceUuid, primary: true)
      service.characteristics = [char]
      pm.add(service)
      servicePublished = true
    }
    if !pm.isAdvertising {
      pm.startAdvertising([
        CBAdvertisementDataServiceUUIDsKey: [Self.serviceUuid]
      ])
    }
  }

  private func stopAdvertising() {
    wantsAdvertising = false
    peripheralManager?.stopAdvertising()
  }

  private func startScanning(result: @escaping FlutterResult) {
    wantsScanning = true
    if centralManager == nil {
      pendingScanResult = result
      centralManager = CBCentralManager(delegate: self, queue: .main)
      return
    }

    guard let cm = centralManager else {
      result(["ok": false, "error": "蓝牙初始化失败"])
      return
    }

    switch cm.state {
    case .poweredOn:
      cm.scanForPeripherals(
        withServices: [Self.serviceUuid],
        options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
      )
      result(["ok": true])
    case .unauthorized:
      wantsScanning = false
      result(["ok": false, "error": "请在系统设置中授予蓝牙权限"])
    case .unsupported:
      wantsScanning = false
      result(["ok": false, "error": "当前设备不支持 BLE 扫描"])
    case .poweredOff:
      wantsScanning = false
      result(["ok": false, "error": "请先开启系统蓝牙"])
    default:
      pendingScanResult = result
    }
  }

  private func stopScanning() {
    wantsScanning = false
    centralManager?.stopScan()
    for peripheral in trackedPeripherals.values {
      centralManager?.cancelPeripheralConnection(peripheral)
    }
    trackedPeripherals.removeAll()
  }

  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    let callback = pendingAdvertiseResult
    pendingAdvertiseResult = nil

    switch peripheral.state {
    case .poweredOn:
      if wantsAdvertising {
        publishAndAdvertise(pm: peripheral)
      }
      callback?(["ok": true])
    case .poweredOff:
      wantsAdvertising = false
      callback?(["ok": false, "error": "请先开启系统蓝牙"])
    case .unauthorized:
      wantsAdvertising = false
      callback?(["ok": false, "error": "请在系统设置中授予蓝牙权限"])
    case .unsupported:
      wantsAdvertising = false
      callback?(["ok": false, "error": "当前设备不支持 BLE 广播"])
    default:
      break
    }
  }

  func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
    guard request.characteristic.uuid == Self.charUuid else {
      peripheral.respond(to: request, withResult: .attributeNotFound)
      return
    }
    if request.offset > beaconData.count {
      peripheral.respond(to: request, withResult: .invalidOffset)
      return
    }
    request.value = beaconData.subdata(in: request.offset..<beaconData.count)
    peripheral.respond(to: request, withResult: .success)
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    let callback = pendingScanResult
    pendingScanResult = nil

    switch central.state {
    case .poweredOn:
      if wantsScanning {
        central.scanForPeripherals(
          withServices: [Self.serviceUuid],
          options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
      }
      callback?(["ok": true])
    case .poweredOff:
      wantsScanning = false
      callback?(["ok": false, "error": "请先开启系统蓝牙"])
    case .unauthorized:
      wantsScanning = false
      callback?(["ok": false, "error": "请在系统设置中授予蓝牙权限"])
    case .unsupported:
      wantsScanning = false
      callback?(["ok": false, "error": "当前设备不支持 BLE 扫描"])
    default:
      break
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    let id = peripheral.identifier
    if let prev = lastReadAt[id], Date().timeIntervalSince(prev) < 6.0 {
      return
    }
    lastReadAt[id] = Date()
    peripheralRssi[id] = RSSI.intValue
    trackedPeripherals[id] = peripheral
    peripheral.delegate = self
    central.connect(peripheral, options: nil)
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    peripheral.discoverServices([Self.serviceUuid])
  }

  func centralManager(
    _ central: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: Error?
  ) {
    trackedPeripherals.removeValue(forKey: peripheral.identifier)
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    trackedPeripherals.removeValue(forKey: peripheral.identifier)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard error == nil,
          let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUuid })
    else {
      centralManager?.cancelPeripheralConnection(peripheral)
      return
    }
    peripheral.discoverCharacteristics([Self.charUuid], for: service)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    guard error == nil,
          let char = service.characteristics?.first(where: { $0.uuid == Self.charUuid })
    else {
      centralManager?.cancelPeripheralConnection(peripheral)
      return
    }
    peripheral.readValue(for: char)
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    if error == nil,
       let data = characteristic.value,
       let jsonStr = String(data: data, encoding: .utf8),
       !jsonStr.isEmpty {
      let rssi = peripheralRssi[peripheral.identifier] ?? -60
      channel.invokeMethod(
        "onBleBeaconDiscovered",
        arguments: ["json": jsonStr, "rssi": rssi]
      )
    }
    centralManager?.cancelPeripheralConnection(peripheral)
  }
}
