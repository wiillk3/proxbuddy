import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct DeviceInfoSheet: View {
    @ObservedObject var session: PM3Session
    var onFlashWillStart: () -> Void = {}
    /// Parent owns the async work so sheet dismissal cannot cancel the download.
    var onHostedFlash: (FirmwareReleaseCatalog.Entry, Bool) -> Void = { _, _ in }
    @Environment(\.dismiss) var dismiss

    @State private var isLoading = true
    @State private var error: String?
    @State private var versionReport = DeviceStatReport(sections: [])
    @State private var statusReport = DeviceStatReport(sections: [])
    @State private var showImporter = false
    @State private var flashAlert: String?
    @State private var isFlashing = false
    @State private var releaseEntry: FirmwareReleaseCatalog.Entry?
    @State private var releaseNotice: String?
    @State private var unlockBootloader = false

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

                    flashCard

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
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [UTType(filenameExtension: "elf") ?? .data, .data],
                allowsMultipleSelection: true
            ) { result in
                Task { @MainActor in
                    await handlePickedFirmware(result)
                }
            }
            .alert("Cannot flash", isPresented: Binding(
                get: { flashAlert != nil },
                set: { if !$0 { flashAlert = nil } }
            )) {
                Button("OK", role: .cancel) { flashAlert = nil }
            } message: {
                Text(flashAlert ?? "")
            }
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
                if case .wifi = session.selectedTransportMode {
                    let host = session.wifiHost.trimmingCharacters(in: .whitespacesAndNewlines)
                    infoRow("TCP", host.isEmpty ? "—" : "tcp:\(host):\(session.wifiPort)")
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

    private var flashCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DEVICE FIRMWARE").hackerText().font(.caption).opacity(0.8)
            if let entry = releaseEntry {
                Text("Hosted release \(entry.releaseTag) matches this app’s pm3 client. Flash over Wi-Fi from GitHub, or pick local .elf files.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                Text("Pick fullimage.elf and it flashes over Wi-Fi. Select bootrom.elf too to update both at once.")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let notice = releaseNotice {
                Text(notice)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let reason = session.flashBlockedReason {
                Text(reason)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.yellow)
            }

            Toggle(isOn: $unlockBootloader) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow bootrom writes")
                        .font(.system(.caption, design: .monospaced))
                    Text("Same as --unlock-bootloader. A failed bootrom write needs a computer (USB + Artery ISP) to recover.")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.hackerGreen)
            .disabled(isFlashing)
            if releaseEntry != nil {
                Button {
                    guard let entry = releaseEntry else { return }
                    onHostedFlash(entry, unlockBootloader)
                } label: {
                    Label(flashReleaseLabel, systemImage: "arrow.down.circle")
                        .font(.system(.subheadline, design: .monospaced))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.hackerGreen)
                .disabled(flashControlsDisabled)
            }
            Button {
                showImporter = true
            } label: {
                Label(isFlashing ? "Flashing…" : "Flash from files…", systemImage: "sdcard")
                    .font(.system(.subheadline, design: .monospaced))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.hackerGreen)
            .disabled(flashControlsDisabled)
        }
        .liquidGlassCard()
        .task { await refreshReleaseOffer() }
    }

    private var flashReleaseLabel: String {
        unlockBootloader ? "Flash matching release (OS + bootrom)" : "Flash matching release"
    }

    private var flashControlsDisabled: Bool {
        isFlashing || !session.isRunning || session.flashBlockedReason != nil
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

    private func refreshReleaseOffer() async {
        releaseEntry = nil
        releaseNotice = nil
        guard let client = PM3ClientVersion.bundledInfo?.gitVersion else {
            releaseNotice = "Could not read bundled pm3 client version."
            return
        }
        do {
            let manifest = try await FirmwareReleaseCatalog.loadManifest()
            releaseEntry = FirmwareReleaseCatalog.matchingEntry(in: manifest, clientGitVersion: client)
            if releaseEntry == nil {
                releaseNotice = "No GitHub release for \(client) yet. Build ELFs at the same commit or wait for a ProxBuddy firmware release."
            }
        } catch {
            releaseNotice = error.localizedDescription
        }
    }

    private func handlePickedFirmware(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            let staged: [URL]
            do {
                staged = try FirmwareImages.stage(urls)
            } catch {
                session.engine.append(raw: "[!] flash: \(error.localizedDescription)", isInput: false)
                try? await Task.sleep(for: .milliseconds(400))
                flashAlert = error.localizedDescription
                return
            }
            let names = staged.map(\.lastPathComponent).joined(separator: ", ")
            session.engine.append(raw: "[=] queued \(names)", isInput: false)
            try? await Task.sleep(for: .milliseconds(400))
            // Caught here only to give a clearer message than the client's segment
            // check; the client decides for real from the ELF's PHDR addresses.
            if unlockBootloader == false, staged.contains(where: FirmwareImages.looksLikeBootrom) {
                flashAlert = "That looks like a bootrom image. Turn on \"Allow bootrom writes\" first, then flash again."
                return
            }
            await runFlash(urls: staged)
        case .failure(let err):
            session.engine.append(raw: "[!] flash picker: \(err.localizedDescription)", isInput: false)
            try? await Task.sleep(for: .milliseconds(400))
            flashAlert = err.localizedDescription
        }
    }

    private func runFlash(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        onFlashWillStart()
        isFlashing = true
        defer { isFlashing = false }
        await DeviceFlashCoordinator.flashLocal(
            session: session,
            urls: urls,
            unlockBootloader: unlockBootloader
        )
        await refreshInfo()
    }
}

/// Flash orchestration owned outside DeviceInfoSheet so hosted downloads survive sheet dismiss.
enum DeviceFlashCoordinator {
    @MainActor
    static func flashHostedRelease(
        session: PM3Session,
        entry: FirmwareReleaseCatalog.Entry,
        unlockBootloader: Bool
    ) async {
        do {
            session.engine.append(raw: "[=] fetching firmware \(entry.releaseTag)", isInput: false)
            let urls = try await FirmwareReleaseCatalog.prepareArtifacts(
                for: entry,
                includeBootrom: unlockBootloader
            )
            let names = urls.map(\.lastPathComponent).joined(separator: ", ")
            session.engine.append(raw: "[=] verified \(names)", isInput: false)
            try? await Task.sleep(for: .milliseconds(400))
            await flashLocal(session: session, urls: urls, unlockBootloader: unlockBootloader)
        } catch {
            session.engine.append(raw: "[!] firmware release: \(error.localizedDescription)", isInput: false)
        }
    }

    @MainActor
    static func flashLocal(
        session: PM3Session,
        urls: [URL],
        unlockBootloader: Bool
    ) async {
        guard !urls.isEmpty else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        await session.flashFirmware(imageURLs: urls, unlockBootloader: unlockBootloader)
    }
}
