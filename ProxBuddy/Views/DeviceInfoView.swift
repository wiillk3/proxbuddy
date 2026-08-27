import SwiftUI

struct DeviceInfoSheet: View {
    @ObservedObject var session: PM3Session
    @Environment(\.dismiss) var dismiss

    @State private var isLoading = true
    @State private var error: String?
    @State private var versionReport = DeviceStatReport(sections: [])
    @State private var statusReport = DeviceStatReport(sections: [])

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView("Reading hardware…")
                            Spacer()
                        }
                        .padding(.vertical, 24)
                    }

                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.red)
                            .liquidGlassCard()
                    }

                    connectionCard
                    batteryCard
                    firmwareCard

                    ForEach(statusReport.sections.filter { !isBatterySection($0) }) { section in
                        statSectionCard(section)
                    }
                }
                .padding()
            }
            .hackerBackground()
            .navigationTitle("Device Specs & Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(.hackerGreen)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await refreshInfo() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.hackerGreen)
                    }
                    .disabled(isLoading)
                }
            }
            .task { await refreshInfo() }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Cards

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CONNECTION").hackerText().font(.caption).opacity(0.8)
            VStack(alignment: .leading, spacing: 8) {
                infoRow("Transport", session.statusMessage)
                infoRow("pm3 client", session.isRunning ? "Running" : "Stopped")
                #if !targetEnvironment(simulator)
                if case .ble = session.selectedTransportMode {
                    infoRow("BLE name", session.bleTransport.connectedPeripheralName ?? "—")
                    infoRow("Negotiated MTU", "\(session.bleTransport.negotiatedMTU) bytes")
                    infoRow("SPP", "0xAE86 / 0xAE88")
                }
                #endif
            }
        }
        .liquidGlassCard()
    }

    private var batteryCard: some View {
        let batt = statusReport.section(titled: "Battery")
        let soc = statusReport.batterySoC ?? session.batteryLevel
        return VStack(alignment: .leading, spacing: 10) {
            Text("BATTERY / BWM").hackerText().font(.caption).opacity(0.8)
            if let soc {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(soc)%")
                        .font(.system(size: 36, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.hackerGreen)
                    Text("state of charge")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else if !isLoading {
                Text("Gauge not reported yet")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let batt {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(batt.rows.enumerated()), id: \.offset) { _, row in
                        if !row.key.localizedCaseInsensitiveContains("SoC") {
                            infoRow(row.key, row.value)
                        }
                    }
                }
            }
        }
        .liquidGlassCard()
    }

    private var firmwareCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FIRMWARE").hackerText().font(.caption).opacity(0.8)
            VStack(alignment: .leading, spacing: 8) {
                if versionReport.sections.isEmpty, !isLoading {
                    infoRow("Build", "Iceman / PM5")
                } else {
                    ForEach(versionReport.sections) { section in
                        if versionReport.sections.count > 1 {
                            Text(section.title)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                            infoRow(row.key, row.value)
                        }
                        ForEach(Array(section.extra.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .liquidGlassCard()
    }

    private func statSectionCard(_ section: DeviceStatSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title.uppercased()).hackerText().font(.caption).opacity(0.8)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                    infoRow(row.key, row.value)
                }
                if !section.extra.isEmpty {
                    Text(section.extra.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .liquidGlassCard()
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: 150, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        }
    }

    private func isBatterySection(_ section: DeviceStatSection) -> Bool {
        section.title.localizedCaseInsensitiveContains("Battery")
    }

    private func refreshInfo() async {
        isLoading = true
        error = nil

        let ver = await session.engine.captureOutputSilent("hw version")
        let stat = await session.engine.captureOutputSilent("hw status")

        versionReport = DeviceStatParser.parse(ver)
        statusReport = DeviceStatParser.parse(stat)

        if ver.isEmpty && stat.isEmpty {
            error = session.isRunning
                ? "No response from hw version / hw status."
                : "pm3 client is not running."
        }
        if let soc = statusReport.batterySoC {
            session.noteGaugeSoC(soc)
        }
        isLoading = false
    }
}
