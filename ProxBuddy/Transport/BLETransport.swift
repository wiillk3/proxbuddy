@preconcurrency import CoreBluetooth
import Foundation

enum ConnectionState: String, Equatable, Sendable {
    case disconnected
    case scanning
    case connecting
    case discoveringServices
    case ready
    case error
}

struct DiscoveredPeripheral: Identifiable, Sendable {
    let id: UUID
    let name: String
    let rssi: Int
    nonisolated(unsafe) let peripheral: CBPeripheral
}

@MainActor
final class BLETransport: NSObject, ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var discoveredPeripherals: [DiscoveredPeripheral] = []
    @Published var connectedPeripheralName: String?
    @Published var negotiatedMTU: Int = 20
    @Published var batteryLevel: Int? = nil

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var dataCharacteristic: CBCharacteristic?
    private var nusTxCharacteristic: CBCharacteristic?
    private var nusRxCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?

    private var portFD: Int32 = -1
    private let portWriteQueue = DispatchQueue(label: "com.proxbuddy.ble.port", qos: .userInteractive)

    let connectionEvents: AsyncStream<ConnectionState>
    private let connectionContinuation: AsyncStream<ConnectionState>.Continuation

    override init() {
        (connectionEvents, connectionContinuation) = AsyncStream.makeStream(of: ConnectionState.self)
        super.init()
        centralManager = CBCentralManager(
            delegate: self,
            queue: .main
        )
    }

    // MARK: - Port Attachment (Relay between pm3 & BLE)

    /// Called by PM3Session / BinaryRunner after launching the C engine loopback socket.
    func attach(portFD: Int32) {
        self.portFD = portFD
        startRelayLoop(fd: portFD)
    }

    private func startRelayLoop(fd: Int32) {
        Task.detached(priority: .userInteractive) { [weak self] in
            var buf = [UInt8](repeating: 0, count: 512)
            while true {
                let n = read(fd, &buf, buf.count)
                guard n > 0 else { break }
                let data = Data(buf[..<n])
                await self?.writeToBLE(data: data)
            }
        }
    }

    /// pm3 engine wrote bytes -> send out over BLE to PM5
    private func writeToBLE(data: Data) {
        guard let peripheral = connectedPeripheral, connectionState == .ready else { return }

        let targetChar = dataCharacteristic ?? nusRxCharacteristic
        guard let char = targetChar else { return }

        let chunkSize = max(1, negotiatedMTU - 3)
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data[offset..<end]
            let writeType: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            peripheral.writeValue(chunk, for: char, type: writeType)
            offset = end
        }
    }

    /// PM5 sent data via BLE notification -> write to pm3 engine socket
    private func receivedFromBLE(_ data: Data) {
        let fd = portFD
        guard fd >= 0 else { return }
        portWriteQueue.async {
            data.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                _ = write(fd, base, data.count)
            }
        }
    }

    // MARK: - Scanning & Connection Management

    func startScanning() {
        discoveredPeripherals = []
        connectionState = .scanning
        centralManager.scanForPeripherals(
            withServices: [PM5BLE.sppServiceUUID, PM5BLE.batteryServiceUUID, PM5BLE.nusServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScanning() {
        centralManager.stopScan()
        if connectionState == .scanning { connectionState = .disconnected }
    }

    func connect(to discovered: DiscoveredPeripheral) {
        stopScanning()
        connectionState = .connecting
        connectedPeripheral = discovered.peripheral
        centralManager.connect(discovered.peripheral, options: nil)
    }

    func disconnect() {
        if let p = connectedPeripheral {
            centralManager.cancelPeripheralConnection(p)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLETransport: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if central.state != .poweredOn && connectionState != .disconnected {
                connectionState = .error
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "Proxmark5"
        let id   = peripheral.identifier
        let rssi = RSSI.intValue

        MainActor.assumeIsolated {
            let discovered = DiscoveredPeripheral(id: id, name: name, rssi: rssi, peripheral: peripheral)
            if let idx = discoveredPeripherals.firstIndex(where: { $0.id == id }) {
                discoveredPeripherals[idx] = discovered
            } else {
                discoveredPeripherals.append(discovered)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            connectionState = .discoveringServices
            connectedPeripheralName = peripheral.name ?? "Proxmark5"
            peripheral.delegate = self
            peripheral.discoverServices([PM5BLE.sppServiceUUID, PM5BLE.batteryServiceUUID, PM5BLE.nusServiceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            connectionState = .error
            connectedPeripheral = nil
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            connectionState = .disconnected
            connectedPeripheral = nil
            connectedPeripheralName = nil
            dataCharacteristic = nil
            nusTxCharacteristic = nil
            nusRxCharacteristic = nil
            batteryCharacteristic = nil
            batteryLevel = nil
            negotiatedMTU = 20
            _ = connectionContinuation.yield(.disconnected)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {}
}

// MARK: - CBPeripheralDelegate

extension BLETransport: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            MainActor.assumeIsolated { connectionState = .error }
            return
        }

        for service in services {
            if service.uuid == PM5BLE.sppServiceUUID {
                peripheral.discoverCharacteristics([PM5BLE.sppDataCharUUID], for: service)
            } else if service.uuid == PM5BLE.batteryServiceUUID {
                peripheral.discoverCharacteristics([PM5BLE.batteryLevelCharUUID], for: service)
            } else if service.uuid == PM5BLE.nusServiceUUID {
                peripheral.discoverCharacteristics([PM5BLE.nusTxCharUUID, PM5BLE.nusRxCharUUID], for: service)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil, let characteristics = service.characteristics else { return }

        for char in characteristics {
            if char.uuid == PM5BLE.sppDataCharUUID {
                peripheral.setNotifyValue(true, for: char)
                MainActor.assumeIsolated { dataCharacteristic = char }
            } else if char.uuid == PM5BLE.batteryLevelCharUUID {
                peripheral.setNotifyValue(true, for: char)
                peripheral.readValue(for: char)
                MainActor.assumeIsolated { batteryCharacteristic = char }
            } else if char.uuid == PM5BLE.nusTxCharUUID {
                peripheral.setNotifyValue(true, for: char)
                MainActor.assumeIsolated { nusTxCharacteristic = char }
            } else if char.uuid == PM5BLE.nusRxCharUUID {
                MainActor.assumeIsolated { nusRxCharacteristic = char }
            }
        }

        let payloadMTU = peripheral.maximumWriteValueLength(for: .withoutResponse)
        MainActor.assumeIsolated {
            if dataCharacteristic != nil || (nusTxCharacteristic != nil && nusRxCharacteristic != nil) {
                negotiatedMTU = max(20, payloadMTU + 3)
                connectionState = .ready
                _ = connectionContinuation.yield(.ready)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }

        if characteristic.uuid == PM5BLE.sppDataCharUUID || characteristic.uuid == PM5BLE.nusTxCharUUID {
            MainActor.assumeIsolated { receivedFromBLE(data) }
        } else if characteristic.uuid == PM5BLE.batteryLevelCharUUID {
            if let firstByte = data.first {
                let level = Int(firstByte)
                MainActor.assumeIsolated { self.batteryLevel = level }
            }
        }
    }
}
