//
//  BLEBridge.swift
//  ScooterBridge
//
//  A generic Bluetooth LE gateway. Knows nothing about any particular device:
//  it scans, connects, dumps GATT, subscribes to notifications and writes
//  bytes. Everything is driven over HTTP so a laptop can use the phone's radio.
//

import Foundation
import CoreBluetooth
import Network

@MainActor
final class BLEBridge: NSObject, ObservableObject {

    static let shared = BLEBridge()

    // MARK: Observable state

    @Published private(set) var isRunning = false
    @Published private(set) var port: UInt16 = 8081
    @Published private(set) var connectedName: String?
    @Published private(set) var connectedUUID: String?
    @Published private(set) var rxCount = 0
    @Published private(set) var bluetoothStateText: String = "unknown"

    var localIPAddress: String? { Self.currentWiFiAddress() }

    // MARK: CoreBluetooth

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristics: [String: CBCharacteristic] = [:]  // "FFF1" -> char
    private var pendingConnect: String?
    private var scanDeadline: Date?
    private var notifyChars: Set<String> = []

    // MARK: Buffers

    private struct RxFrame {
        let t: Double
        let char: String
        let hex: String
    }
    private var rxBuffer: [RxFrame] = []
    private var discovered: [String: [String: Any]] = [:]

    // MARK: HTTP

    private var listener: NWListener?
    private var openConnections: Set<ObjectIdentifier> = []

    // MARK: - Lifecycle

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func start(port: UInt16 = 8081) {
        guard !isRunning else { return }
        self.port = port
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            let l = try NWListener(using: params, on: nwPort)
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.isRunning = true
                    case .failed, .cancelled: self?.isRunning = false
                    default: break
                    }
                }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            isRunning = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        central.stopScan()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        connectedName = nil
        connectedUUID = nil
        characteristics.removeAll()
    }

    // MARK: - Helpers

    /// Best-effort IPv4 of the active Wi-Fi interface, for the UI only.
    private static func currentWiFiAddress() -> String? {
        var addr: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr = first
        while true {
            let flags = Int32(ptr.pointee.ifa_flags)
            let family = ptr.pointee.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET), (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                               &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addr = String(cString: host)
                }
            }
            guard let next = ptr.pointee.ifa_next else { break }
            ptr = next
        }
        return addr
    }

    /// Normalise a UUID string to the short 4-hex form used as a dict key
    /// when possible, otherwise keep the full string.
    func shortKey(_ uuid: CBUUID) -> String {
        let s = uuid.uuidString.uppercased()
        if s.hasPrefix("0000") && s.hasSuffix("-0000-1000-8000-00805F9B34FB") {
            return String(s.dropFirst(4).prefix(4))
        }
        return s
    }
}

// MARK: - HTTP server

extension BLEBridge {

    fileprivate func accept(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        openConnections.insert(id)
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed = state { self?.openConnections.remove(id) }
                if case .cancelled = state { self?.openConnections.remove(id) }
            }
        }
        conn.start(queue: .main)
        readRequest(conn, buffer: Data())
    }

    fileprivate func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, done, err in
            Task { @MainActor in
                guard let self else { return }
                var acc = buffer
                if let chunk { acc.append(chunk) }

                if let sep = acc.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: acc[..<sep.lowerBound], as: UTF8.self)
                    let result = await self.route(head)
                    self.reply(conn, result)
                    return
                }
                if done || err != nil || acc.count > 65536 { conn.cancel(); return }
                self.readRequest(conn, buffer: acc)
            }
        }
    }

    fileprivate func reply(_ conn: NWConnection, _ payload: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: payload,
                                                options: [.prettyPrinted, .sortedKeys]))
            ?? Data("{\"error\":\"encode\"}".utf8)
        var out = Data()
        out.append(Data("HTTP/1.1 200 OK\r\n".utf8))
        out.append(Data("Content-Type: application/json; charset=utf-8\r\n".utf8))
        out.append(Data("Content-Length: \(body.count)\r\n".utf8))
        out.append(Data("Access-Control-Allow-Origin: *\r\n".utf8))
        out.append(Data("Connection: close\r\n\r\n".utf8))
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    /// Split "GET /write?char=FFF2&data=00 HTTP/1.1" into path + query.
    fileprivate func route(_ head: String) async -> [String: Any] {
        let firstLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return ["ok": false, "error": "bad request"] }
        let target = String(parts[1])
        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            let qs = String(target[target.index(after: q)...])
            for pair in qs.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    query[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                } else if kv.count == 1 {
                    query[String(kv[0])] = ""
                }
            }
        }
        return await dispatch(path: path, query: query)
    }
}

// MARK: - Request dispatch

extension BLEBridge {

    fileprivate func dispatch(path: String, query: [String: String]) async -> [String: Any] {
        switch path {
        case "/", "":
            return [
                "ok": true,
                "app": "ScooterBridge",
                "port": Int(port),
                "bluetooth": bluetoothStateText,
                "endpoints": [
                    "GET  /status",
                    "GET  /scan",
                    "POST /connect?uuid=UUID",
                    "POST /disconnect",
                    "GET  /services",
                    "POST /subscribe?char=FFF1",
                    "POST /write?char=FFF2&data=55AABB&type=cmd|req",
                    "GET  /rx?clear=1"
                ]
            ]

        case "/status":
            return [
                "ok": true,
                "bluetooth": bluetoothStateText,
                "connected": peripheral?.state == .connected,
                "name": connectedName ?? NSNull(),
                "uuid": connectedUUID ?? NSNull(),
                "rx": rxCount,
                "chars": Array(characteristics.keys).sorted()
            ]

        case "/scan":
            guard central.state == .poweredOn else {
                return ["ok": false, "error": "bluetooth \(bluetoothStateText)"]
            }
            discovered.removeAll()
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            central.stopScan()
            var list: [[String: Any]] = []
            for (_, info) in discovered { list.append(info) }
            list.sort { ($0["rssi"] as? Int ?? -999) > ($1["rssi"] as? Int ?? -999) }
            return ["ok": true, "count": list.count, "devices": list]

        case "/connect":
            guard let uuidStr = query["uuid"], !uuidStr.isEmpty else {
                return ["ok": false, "error": "missing uuid"]
            }
            guard let target = discovered[uuidStr]?["peripheral"] as? CBPeripheral else {
                return ["ok": false, "error": "unknown uuid - run /scan first"]
            }
            central.connect(target, options: nil)
            for _ in 0..<40 {
                if target.state == .connected { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if target.state != .connected {
                return ["ok": false, "error": "connect timeout"]
            }
            return ["ok": true, "uuid": uuidStr, "name": target.name ?? "",
                    "message": "connected; call /services"]

        case "/disconnect":
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            return ["ok": true]

        case "/services":
            guard let p = peripheral else { return ["ok": false, "error": "not connected"] }
            var services: [[String: Any]] = []
            for s in p.services ?? [] {
                var chars: [[String: Any]] = []
                for c in s.characteristics ?? [] {
                    chars.append([
                        "uuid": shortKey(c.uuid),
                        "props": propsText(c.properties),
                        "notifying": notifyChars.contains(shortKey(c.uuid))
                    ])
                }
                services.append(["uuid": shortKey(s.uuid), "characteristics": chars])
            }
            return ["ok": true, "services": services]

        case "/subscribe":
            guard let p = peripheral, let key = query["char"] else {
                return ["ok": false, "error": "not connected or missing char"]
            }
            guard let c = characteristics[key.uppercased()] else {
                return ["ok": false, "error": "no such characteristic \(key)"]
            }
            p.setNotifyValue(true, for: c)
            notifyChars.insert(shortKey(c.uuid))
            return ["ok": true, "char": shortKey(c.uuid)]

        case "/write":
            guard let p = peripheral,
                  let key = query["char"]?.uppercased(),
                  let hex = query["data"],
                  let c = characteristics[key] else {
                return ["ok": false, "error": "need char + data, and a connection"]
            }
            guard let bytes = Self.hexToBytes(hex) else {
                return ["ok": false, "error": "data is not hex"]
            }
            let wantResponse = (query["type"] ?? "cmd").lowercased() == "req"
            let withoutResponse = c.properties.contains(.writeWithoutResponse)
            let withResponse = c.properties.contains(.write)
            let useResponse = wantResponse ? withResponse : (!withoutResponse && withResponse)
            let type: CBCharacteristicWriteType = useResponse ? .withResponse : .withoutResponse
            p.writeValue(Data(bytes), for: c, type: type)
            return ["ok": true, "char": key, "bytes": bytes.count,
                    "type": type == .withResponse ? "withResponse" : "withoutResponse"]

        case "/rx":
            let frames = rxBuffer.map { ["t": $0.t, "char": $0.char, "hex": $0.hex] }
            if (query["clear"] ?? "0") == "1" {
                rxBuffer.removeAll()
                rxCount = 0
            }
            return ["ok": true, "count": frames.count, "frames": frames]

        default:
            return ["ok": false, "error": "unknown path \(path)"]
        }
    }

    fileprivate func propsText(_ p: CBCharacteristicProperties) -> String {
        var out: [String] = []
        if p.contains(.read) { out.append("read") }
        if p.contains(.write) { out.append("write") }
        if p.contains(.writeWithoutResponse) { out.append("writeNoResp") }
        if p.contains(.notify) { out.append("notify") }
        if p.contains(.indicate) { out.append("indicate") }
        return out.joined(separator: ",")
    }

    static func hexToBytes(_ s: String) -> [UInt8]? {
        let clean = s.replacingOccurrences(of: " ", with: "")
                          .replacingOccurrences(of: "0x", with: "")
        guard clean.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let b = UInt8(clean[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        return out
    }
}

// MARK: - CoreBluetooth delegate

extension BLEBridge: CBCentralManagerDelegate, CBPeripheralDelegate {

    nonisolated func centralManagerDidUpdateState(_ sender: CBCentralManager) {
        let state = sender.state
        Task { @MainActor in
            switch state {
            case .poweredOn:  self.bluetoothStateText = "on"
            case .poweredOff: self.bluetoothStateText = "off"
            case .unauthorized: self.bluetoothStateText = "unauthorized"
            case .unsupported: self.bluetoothStateText = "unsupported"
            case .resetting: self.bluetoothStateText = "resetting"
            default: self.bluetoothStateText = "unknown"
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let uuid = peripheral.identifier.uuidString
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? ""
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            .map { $0.uuidString }
        let info: [String: Any] = [
            "uuid": uuid,
            "name": name,
            "rssi": RSSI.intValue,
            "services": services,
            "peripheral": peripheral
        ]
        Task { @MainActor in
            self.discovered[uuid] = info
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.peripheral = peripheral
            self.connectedUUID = peripheral.identifier.uuidString
            self.connectedName = peripheral.name ?? ""
            peripheral.delegate = self
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) { }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.peripheral = nil
            self.connectedName = nil
            self.connectedUUID = nil
            self.characteristics.removeAll()
            self.notifyChars.removeAll()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        for c in service.characteristics ?? [] {
            let uuid = c.uuid
            Task { @MainActor in
                self.characteristics[self.shortKey(uuid)] = c
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let data = characteristic.value else { return }
        let uuid = characteristic.uuid
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        let ts = Date().timeIntervalSince1970
        Task { @MainActor in
            self.rxBuffer.append(RxFrame(t: ts, char: self.shortKey(uuid), hex: hex))
            self.rxCount += 1
            if self.rxBuffer.count > 500 { self.rxBuffer.removeFirst(self.rxBuffer.count - 500) }
        }
    }
}
