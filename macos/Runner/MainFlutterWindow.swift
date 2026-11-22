import Cocoa
import CoreBluetooth
import FlutterMacOS
import PDFKit
import UniformTypeIdentifiers

class MainFlutterWindow: NSWindow {
  private var bleBridge: SyncCanvasMacBleBridge?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "com.synccanvas/native_bridge",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    bleBridge = SyncCanvasMacBleBridge(channel: channel)

    super.awakeFromNib()
  }
}

private final class SyncCanvasMacBleBridge: NSObject, CBCentralManagerDelegate, CBPeripheralManagerDelegate, CBPeripheralDelegate {
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
    case "getAppFilesDir":
      let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first?.path
      result(appSupport)
    case "pickImage":
      pickImage(result: result)
    case "pickPdf":
      let args = call.arguments as? [String: Any]
      let maxPages = max(1, min(120, args?["maxPages"] as? Int ?? 30))
      pickPdf(maxPages: maxPages, result: result)
    case "scanQrCode":
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func pickImage(result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      let panel = NSOpenPanel()
      panel.canChooseFiles = true
      panel.canChooseDirectories = false
      panel.allowsMultipleSelection = false
      if #available(macOS 11.0, *) {
        panel.allowedContentTypes = [.image]
      } else {
        panel.allowedFileTypes = ["png", "jpg", "jpeg", "webp", "gif"]
      }
      panel.begin { response in
        guard response == .OK, let url = panel.url else {
          result(nil)
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          let dataUrl = Self.encodeImageToDataUrl(url: url)
          DispatchQueue.main.async {
            result(dataUrl)
          }
        }
      }
    }
  }

  private static func encodeImageToDataUrl(url: URL) -> String? {
    guard let image = NSImage(contentsOf: url) else { return nil }
    var proposedRect = NSRect(origin: .zero, size: image.size)
    guard let cgImg = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
      return nil
    }
    let rawW = max(1, cgImg.width)
    let rawH = max(1, cgImg.height)
    let maxSide = max(rawW, rawH)
    let scale = maxSide > 1600 ? (1600.0 / Double(maxSide)) : 1.0
    let targetW = max(1, Int((Double(rawW) * scale).rounded()))
    let targetH = max(1, Int((Double(rawH) * scale).rounded()))

    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: targetW,
      pixelsHigh: targetH,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else {
      return nil
    }

    NSGraphicsContext.saveGraphicsState()
    if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
      NSGraphicsContext.current = ctx
      ctx.imageInterpolation = .high
      NSImage(cgImage: cgImg, size: NSSize(width: targetW, height: targetH))
        .draw(in: NSRect(x: 0, y: 0, width: targetW, height: targetH))
    }
    NSGraphicsContext.restoreGraphicsState()

    let ext = url.pathExtension.lowercased()
    if ext == "png",
       max(targetW, targetH) <= 1200,
       let pngData = rep.representation(using: .png, properties: [:]),
       pngData.count <= 700_000 {
      return "data:image/png;base64,\(pngData.base64EncodedString())"
    }
    guard let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.86]) else {
      return nil
    }
    return "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
  }

  private func pickPdf(maxPages: Int, result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      let panel = NSOpenPanel()
      panel.canChooseFiles = true
      panel.canChooseDirectories = false
      panel.allowsMultipleSelection = false
      if #available(macOS 11.0, *) {
        panel.allowedContentTypes = [.pdf]
      } else {
        panel.allowedFileTypes = ["pdf"]
      }
      panel.begin { response in
        guard response == .OK, let url = panel.url else {
          result(nil)
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          let jsonStr = Self.renderPdfToJson(url: url, maxPages: maxPages)
          DispatchQueue.main.async {
            result(jsonStr)
          }
        }
      }
    }
  }

  private static func renderPdfToJson(url: URL, maxPages: Int) -> String {
    let fileName = url.lastPathComponent.isEmpty ? "document.pdf" : url.lastPathComponent
    guard let doc = PDFDocument(url: url) else {
      let errObj: [String: Any] = ["fileName": fileName, "error": "无法解析该 PDF 文件"]
      let data = (try? JSONSerialization.data(withJSONObject: errObj)) ?? Data()
      return String(data: data, encoding: .utf8) ?? "{}"
    }

    let totalPages = doc.pageCount
    let limit = min(totalPages, maxPages)
    var pagesJson: [[String: Any]] = []

    for i in 0..<limit {
      autoreleasepool {
        guard let page = doc.page(at: i) else { return }
        let rawBounds = page.bounds(for: .mediaBox)
        let rot = ((page.rotation % 360) + 360) % 360
        let pageW = (rot == 90 || rot == 270) ? rawBounds.height : rawBounds.width
        let pageH = (rot == 90 || rot == 270) ? rawBounds.width : rawBounds.height
        let safeW = max(1.0, Double(pageW))
        let safeH = max(1.0, Double(pageH))
        let maxSide = max(safeW, safeH)
        let scale = min(2.4, max(0.25, 1440.0 / maxSide))
        let pxW = max(1, Int((safeW * scale).rounded()))
        let pxH = max(1, Int((safeH * scale).rounded()))

        let thumb = page.thumbnail(of: NSSize(width: pxW, height: pxH), for: .mediaBox)
        guard let rep = NSBitmapImageRep(
          bitmapDataPlanes: nil,
          pixelsWide: pxW,
          pixelsHigh: pxH,
          bitsPerSample: 8,
          samplesPerPixel: 4,
          hasAlpha: true,
          isPlanar: false,
          colorSpaceName: .deviceRGB,
          bytesPerRow: 0,
          bitsPerPixel: 0
        ) else {
          return
        }

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
          NSGraphicsContext.current = ctx
          ctx.imageInterpolation = .high
          NSColor.white.setFill()
          NSRect(x: 0, y: 0, width: pxW, height: pxH).fill()
          thumb.draw(in: NSRect(x: 0, y: 0, width: pxW, height: pxH))
        }
        NSGraphicsContext.restoreGraphicsState()

        if let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.86]) {
          pagesJson.append([
            "pageNumber": i + 1,
            "width": pxW,
            "height": pxH,
            "dataUrl": "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
          ])
        }
      }
    }

    let payload: [String: Any] = [
      "fileName": fileName,
      "totalPages": totalPages,
      "pages": pagesJson
    ]
    guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
          let str = String(data: jsonData, encoding: .utf8)
    else {
      return "{}"
    }
    return str
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

  // MARK: - CBPeripheralManagerDelegate

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

  // MARK: - CBCentralManagerDelegate

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

  // MARK: - CBPeripheralDelegate

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
