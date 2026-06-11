import Foundation
import Network

// Connects to ProxBuddyBridge over TCP/WiFi via Bonjour (_proxbuddy._tcp).
// Relays data between pm3's serial-port FD (provided by BinaryRunner) and the bridge.
// BinaryRunner owns the port pair; TcpTransport just does the TCP relay.

@MainActor
final class TcpTransport: ObservableObject {
    @Published var isReady = false
    @Published var statusMessage = "Searching for ProxBuddy-Bridge…"

    private var connection: NWConnection?
    private var browser: NWBrowser?
    private var portFD: Int32 = -1
    private let portWriteQueue = DispatchQueue(label: "com.proxbuddy.tcp.port", qos: .userInteractive)

    let readyStream: AsyncStream<Void>
    private let readyContinuation: AsyncStream<Void>.Continuation

    init() {
        (readyStream, readyContinuation) = AsyncStream.makeStream(of: Void.self)
        startBrowsing()
    }

    // MARK: - Port attachment

    /// Called by PM3Session after BinaryRunner spawns pm3.
    /// Starts reading pm3's serial output and forwarding it to the TCP bridge.
    func attach(portFD: Int32) {
        self.portFD = portFD
        startRelayLoop(fd: portFD)
    }

    private func startRelayLoop(fd: Int32) {
        Task.detached(priority: .high) { [weak self] in
            var buf = [UInt8](repeating: 0, count: 512)
            while true {
                let n = read(fd, &buf, buf.count)
                guard n > 0 else { break }
                await self?.sendTCP(Data(buf[..<n]))
            }
        }
    }

    private func sendTCP(_ data: Data) {
        guard let conn = connection, isReady else { return }
        conn.send(content: data, completion: .idempotent)
    }

    private func receivedFromBridge(_ data: Data) {
        let fd = portFD
        guard fd >= 0 else { return }
        portWriteQueue.async {
            data.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                _ = write(fd, base, data.count)
            }
        }
    }

    // MARK: - Bonjour discovery

    private func startBrowsing() {
        let b = NWBrowser(for: .bonjour(type: "_proxbuddy._tcp", domain: nil), using: .tcp)
        browser = b
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            if let first = results.first {
                Task { @MainActor in self.connect(to: first.endpoint) }
            }
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state {
                Task { @MainActor in self?.statusMessage = "Bonjour failed: \(e)" }
            }
        }
        b.start(queue: .main)
    }

    private func connect(to endpoint: NWEndpoint) {
        browser?.cancel()
        statusMessage = "Connecting to bridge…"
        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                switch state {
                case .ready:
                    self.isReady = true
                    self.statusMessage = "Connected to ProxBuddy-Bridge"
                    self.readyContinuation.yield(())
                    self.receiveLoop(conn)
                case .failed(let e):
                    self.isReady = false
                    self.statusMessage = "Connection failed: \(e)"
                    self.startBrowsing()
                case .cancelled:
                    self.isReady = false
                    self.statusMessage = "Disconnected"
                default: break
                }
            }
        }
        conn.start(queue: .main)
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 512) { [weak self] data, _, done, error in
            if let data, !data.isEmpty {
                Task { @MainActor in self?.receivedFromBridge(data) }
            }
            if !done && error == nil { self?.receiveLoop(conn) }
        }
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }
}
