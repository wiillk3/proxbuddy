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
    // CBPeripheral is not Sendable but we isolate access to MainActor
    nonisolated(unsafe) let peripheral: CBPeripheral
}

@MainActor
final class BLETransport: NSObject, ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var discoveredPeripherals: [DiscoveredPeripheral] = []
    @Published var connectedPeripheralName: String?
    @Published var negotiatedMTU: Int = 20
    @Published var ptyPath: String?

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var rxCharacteristic: CBCharacteristic?

    // PTY master fd — accessed only from MainActor or with ptyWriteQueue
    private var ptyMasterFD: Int32 = -1
    private let ptyWriteQueue = DispatchQueue(label: "com.proxbuddy.pty.write", qos: .userInteractive)

    let connectionEvents: AsyncStream<ConnectionState>
    private let connectionContinuation: AsyncStream<ConnectionState>.Continuation

    override init() {
        (connectionEvents, connectionContinuation) = AsyncStream.makeStream(of: ConnectionState.self)
        super.init()
        centralManager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.proxbuddy.central"]
        )
        setupPTY()
    }

    // MARK: - PTY

    private func setupPTY() {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0,
              grantpt(master) == 0,
              unlockpt(master) == 0 else { return }
        ptyMasterFD = master

        if let slaveName = ptsname(master) {
            ptyPath = String(cString: slaveName)
        }
        startPTYReadLoop(masterFD: master)
    }

    private func startPTYReadLoop(masterFD: Int32) {
        Task.detached(priority: .userInteractive) { [weak self] in
            var buf = [UInt8](repeating: 0, count: 512)
            while true {
                let n = read(masterFD, &buf, buf.count)
                guard n > 0 else { break }
                let data = Data(buf[..<n])
                await self?.writeToBLE(data: data)
            }
        }
    }

    // pm3client wrote to PTY slave → we forward to PM5 via BLE RX characteristic
    private func writeToBLE(data: Data) {
        guard let peripheral = connectedPeripheral,
              let rxChar = rxCharacteristic,
              connectionState == .ready else { return }

        let chunkSize = max(1, negotiatedMTU - 3)
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            peripheral.writeValue(data[offset..<end], for: rxChar, type: .withoutResponse)
            offset = end
        }
    }

    // PM5 sent data via TX notification → write to PTY master → pm3client reads from PTY slave
    private func receivedFromBLE(_ data: Data) {
        let fd = ptyMasterFD
        guard fd >= 0 else { return }
        ptyWriteQueue.async {
            data.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                _ = write(fd, base, data.count)
            }
        }
    }

    // MARK: - Public

    func startScanning() {
        discoveredPeripherals = []
        connectionState = .scanning
        centralManager.scanForPeripherals(
            withServices: [NUS.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
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
        if let p = connectedPeripheral { centralManager.cancelPeripheralConnection(p) }
    }

    func closePTY() {
        if ptyMasterFD >= 0 { close(ptyMasterFD); ptyMasterFD = -1 }
    }
}

// MARK: - CBCentralManagerDelegate
// All callbacks arrive on queue: .main (set in init), so assumeIsolated is safe.

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
            ?? "Unknown"
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
            connectedPeripheralName = peripheral.name
            peripheral.delegate = self
            peripheral.discoverServices([NUS.serviceUUID])
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
            txCharacteristic = nil
            rxCharacteristic = nil
            negotiatedMTU = 20
            _ = connectionContinuation.yield(.disconnected)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {}
}

// MARK: - CBPeripheralDelegate

extension BLETransport: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == NUS.serviceUUID })
        else {
            MainActor.assumeIsolated { connectionState = .error }
            return
        }
        peripheral.discoverCharacteristics([NUS.txCharUUID, NUS.rxCharUUID], for: service)
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil else {
            MainActor.assumeIsolated { connectionState = .error }
            return
        }
        var foundTX = false
        var foundRX = false
        for char in service.characteristics ?? [] {
            if char.uuid == NUS.txCharUUID {
                peripheral.setNotifyValue(true, for: char)
                MainActor.assumeIsolated { txCharacteristic = char }
                foundTX = true
            } else if char.uuid == NUS.rxCharUUID {
                MainActor.assumeIsolated { rxCharacteristic = char }
                foundRX = true
            }
        }
        guard foundTX && foundRX else {
            MainActor.assumeIsolated { connectionState = .error }
            return
        }
        let payloadMTU = peripheral.maximumWriteValueLength(for: .withoutResponse)
        MainActor.assumeIsolated {
            negotiatedMTU = payloadMTU + 3
            connectionState = .ready
            _ = connectionContinuation.yield(.ready)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil,
              characteristic.uuid == NUS.txCharUUID,
              let data = characteristic.value
        else { return }
        MainActor.assumeIsolated { receivedFromBLE(data) }
    }
}
