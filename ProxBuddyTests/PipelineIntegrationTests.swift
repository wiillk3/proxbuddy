/// PipelineIntegrationTests.swift
///
/// End-to-end test of the full iOS app pipeline:
///
///   BLETransport (real CoreBluetooth scan/connect)
///     → PTY slave → BinaryRunner (posix_spawn pm3client)
///       → TerminalEngine (AsyncStream line accumulation)
///
/// Hardware setup required:
///   iOS device with a Proxmark5 advertising over BLE
///
/// Skip behaviour:
///   If no matching BLE peripheral is found within SCAN_TIMEOUT seconds the
///   test calls XCTSkip so the suite still passes in CI / without hardware.

import XCTest
@testable import ProxBuddy

// ── Config ────────────────────────────────────────────────────────────────────

/// Name the peripheral advertises.
private let PERIPHERAL_NAME = "Proxmark5"

/// UID of the card under test. Override via PROXBUDDY_TEST_UID env var.
private var EXPECTED_UID: String {
    ProcessInfo.processInfo.environment["PROXBUDDY_TEST_UID"] ?? "C5 EC A5 9A"
}

private let SCAN_TIMEOUT:    TimeInterval = 12
private let CONNECT_TIMEOUT: TimeInterval = 10
private let PM3_BOOT_TIMEOUT: TimeInterval = 15   // time for pm3client to show prompt
private let CMD_TIMEOUT:     TimeInterval = 20

// ── Test case ─────────────────────────────────────────────────────────────────

@MainActor
final class PipelineIntegrationTests: XCTestCase {

    private var ble: BLETransport!
    private var runner: BinaryRunner!
    private var engine: TerminalEngine!
    private var outputTask: Task<Void, Never>?

    override func setUp() async throws {
        try await super.setUp()
        ble    = BLETransport()
        runner = BinaryRunner()
        engine = TerminalEngine()
    }

    override func tearDown() async throws {
        outputTask?.cancel()
        runner.terminate()
        ble.disconnect()
        ble.closePTY()
        try await super.tearDown()
    }

    // MARK: - Tests

    /// Validates the complete app pipeline end-to-end:
    ///   connect → pm3 prompt → hf mf info → card fingerprint in TerminalEngine output
    func test_pipeline_hfMfInfo() async throws {
        // ── 1. Scan & connect ─────────────────────────────────────────────

        let peripheral = try await scanForPeripheral(named: PERIPHERAL_NAME, timeout: SCAN_TIMEOUT)
        ble.connect(to: peripheral)
        try await waitForBLEReady(timeout: CONNECT_TIMEOUT)

        // ── 2. Launch pm3client with PTY slave ────────────────────────────

        let ptyPath = try XCTUnwrap(ble.ptyPath, "BLETransport did not create PTY")
        try await runner.launch(ptyPath: ptyPath)

        // Wire runner output into engine in background
        outputTask = Task { await engine.connect(to: runner, startSession: false) }

        // ── 3. Wait for pm3 prompt ────────────────────────────────────────

        try await waitForOutput(containing: "pm3", timeout: PM3_BOOT_TIMEOUT,
                                description: "pm3 prompt after connect")

        // ── 4. Send hf mf info ────────────────────────────────────────────

        engine.sendCommand("hf mf info")

        // ── 5. Assert card output in TerminalEngine lines ─────────────────

        try await waitForOutput(containing: "FM11RF08", timeout: CMD_TIMEOUT,
                                description: "FM11RF08 card fingerprint")

        let allOutput = engine.lines.map(\.raw).joined(separator: "\n")

        XCTAssertTrue(allOutput.contains(EXPECTED_UID),
                      "Expected UID '\(EXPECTED_UID)' in output:\n\(allOutput)")
        XCTAssertTrue(allOutput.contains("00 04"),
                      "Expected ATQA 00 04")
        XCTAssertTrue(allOutput.contains("SAK: 08"),
                      "Expected SAK 08 (MIFARE Classic 1K)")
        XCTAssertTrue(allOutput.contains("weak"),
                      "Expected weak PRNG")
    }

    /// Smoke test: just validates pm3client starts and the PM5 is responsive.
    /// Run this first if the full test times out.
    func test_pipeline_hwPing() async throws {
        let peripheral = try await scanForPeripheral(named: PERIPHERAL_NAME, timeout: SCAN_TIMEOUT)
        ble.connect(to: peripheral)
        try await waitForBLEReady(timeout: CONNECT_TIMEOUT)

        let ptyPath = try XCTUnwrap(ble.ptyPath)
        try await runner.launch(ptyPath: ptyPath)
        outputTask = Task { await engine.connect(to: runner, startSession: false) }

        try await waitForOutput(containing: "pm3", timeout: PM3_BOOT_TIMEOUT,
                                description: "pm3 prompt")

        engine.sendCommand("hw ping")

        try await waitForOutput(containing: "pong", timeout: CMD_TIMEOUT,
                                description: "hw ping → pong")
    }

    // MARK: - Helpers

    private func scanForPeripheral(named name: String, timeout: TimeInterval) async throws -> DiscoveredPeripheral {
        ble.startScanning()
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let found = ble.discoveredPeripherals.first(where: { $0.name.contains(name) }) {
                ble.stopScanning()
                return found
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        ble.stopScanning()
        throw XCTSkip("\(name) not found within \(Int(timeout))s — connect a Proxmark5 first")
    }

    private func waitForBLEReady(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if ble.connectionState == .ready { return }
            if ble.connectionState == .error {
                XCTFail("BLE connection error")
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("BLE not ready after \(Int(timeout))s (state: \(ble.connectionState.rawValue))")
    }

    private func waitForOutput(containing needle: String, timeout: TimeInterval, description: String) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let allText = engine.lines.map(\.raw).joined(separator: "\n")
            if allText.contains(needle) { return }
            try await Task.sleep(for: .milliseconds(300))
        }
        let allText = engine.lines.map(\.raw).joined(separator: "\n")
        XCTFail("Timeout waiting for '\(description)' (needle: '\(needle)')\nOutput so far:\n\(allText)")
    }
}
