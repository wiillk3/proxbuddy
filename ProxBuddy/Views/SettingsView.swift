import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var engine:       TerminalEngine
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var scanHistory:  ScanHistoryStore

    @AppStorage("showTimestamps") var showTimestamps = false
    @AppStorage("logRetentionDays") var logRetentionDays = 30
    @AppStorage("terminalFontSize") var fontSize: Double = 13
    @AppStorage("builderAutoSwitch") var builderAutoSwitch = true
    @AppStorage("stubCommandFlow") var stubCommandFlow = true
    @AppStorage("stubEmulatorFlow") var stubEmulatorFlow = false

    @State private var pm3Version: String = "—"

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {

                    VStack(alignment: .leading, spacing: 12) {
                        Text("DISPLAY").hackerText().font(.subheadline).opacity(0.8)
                        VStack(alignment: .leading, spacing: 16) {
                            Toggle("Show Timestamps", isOn: $showTimestamps).tint(.hackerGreen)
                            Divider().background(Color.glassBorder)

                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Font Size")
                                    Spacer()
                                    Text("\(Int(fontSize)) pt")
                                        .foregroundStyle(.secondary)
                                        .font(.system(.caption, design: .monospaced))
                                }
                                Slider(value: $fontSize, in: 9...22, step: 1).tint(.hackerGreen)
                            }
                            Divider().background(Color.glassBorder)

                            Text("hf mf info → [+] UID: C5 EC A5 9A")
                                .font(.system(size: CGFloat(fontSize), design: .monospaced))
                                .foregroundStyle(Color.hackerGreen)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                        }
                        .liquidGlassCard()
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("COMMAND BUILDER").hackerText().font(.subheadline).opacity(0.8)
                        VStack(alignment: .leading, spacing: 16) {
                            Toggle("Switch to Terminal after Send", isOn: $builderAutoSwitch).tint(.hackerGreen)
                            Text("Automatically jumps to the Terminal tab when you tap Send in the command builder.")
                                .font(.caption).foregroundStyle(.secondary)
                            Divider().background(Color.glassBorder)

                            Toggle("Stub command flow in terminal", isOn: $stubCommandFlow).tint(.hackerGreen)
                            Text("Hides the --help queries the builder sends to pm3 while loading options. Turn off to see them in the terminal.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .liquidGlassCard()
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("FILES").hackerText().font(.subheadline).opacity(0.8)
                        VStack(alignment: .leading, spacing: 16) {
                            Toggle("Stub emulator commands in terminal", isOn: $stubEmulatorFlow).tint(.hackerGreen)
                            Text("Hides Load to Emulator output from the terminal. Simulate and View Emulator Memory are always handled in the Files tab.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .liquidGlassCard()
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("LOGGING").hackerText().font(.subheadline).opacity(0.8)
                        VStack(alignment: .leading, spacing: 16) {
                            Stepper(
                                logRetentionDays == 0 ? "Retain logs: Forever (∞)" : "Retain logs for \(logRetentionDays) days",
                                value: $logRetentionDays,
                                in: 0...365
                            )
                            Divider().background(Color.glassBorder)
                            Button("Purge old logs") { purgeOldLogs() }
                                .foregroundStyle(.red)
                        }
                        .liquidGlassCard()
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("ABOUT").hackerText().font(.subheadline).opacity(0.8)
                        VStack(alignment: .leading, spacing: 16) {
                            HStack { Text("pm3client"); Spacer(); Text(pm3Version).foregroundStyle(.secondary) }
                            Divider().background(Color.glassBorder)
                            HStack { Text("Bundle ID"); Spacer(); Text(Bundle.main.bundleIdentifier ?? "—").foregroundStyle(.secondary) }
                            Divider().background(Color.glassBorder)
                            HStack { Text("App version"); Spacer(); Text(appVersion).foregroundStyle(.secondary) }
                            Divider().background(Color.glassBorder)
                            NavigationLink {
                                AcknowledgementsView()
                            } label: {
                                HStack {
                                    Label("Open Source Licenses & Credits", systemImage: "doc.text.fill")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .foregroundStyle(.hackerGreen)
                            }
                            Divider().background(Color.glassBorder)
                            Link("RRG/Iceman Firmware Repo", destination: URL(string: "https://github.com/RfidResearchGroup/proxmark3")!)
                                .foregroundStyle(.hackerGreen)
                        }
                        .liquidGlassCard()
                    }
                }
                .padding()
            }
            .hackerBackground()
            .navigationTitle("Settings")
            .task { pm3Version = await fetchPm3Version() }
        }
        .preferredColorScheme(.dark)
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private func fetchPm3Version() async -> String {
        let lines = await engine.captureOutputSilent("hw version")
        let versionLine = lines.first(where: { $0.contains("Iceman") || $0.contains("master") })
        return versionLine?.trimmingCharacters(in: .whitespaces) ?? "—"
    }


    private func purgeOldLogs() {
        guard logRetentionDays > 0 else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let cutoff = Date().addingTimeInterval(TimeInterval(-logRetentionDays * 86400))
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: docs, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }
        for file in files where file.pathExtension == "log" {
            let attrs = try? file.resourceValues(forKeys: [.creationDateKey])
            if let created = attrs?.creationDate, created < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }
}

// MARK: - Open Source Licenses & Acknowledgements View

struct AcknowledgementsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header card
                VStack(alignment: .leading, spacing: 8) {
                    Text("OPEN SOURCE CREDITS")
                        .hackerText().font(.caption).opacity(0.8)
                    Text("ProxBuddy is built on the shoulders of giants. We credit and thank the original authors, maintainers, and hardware designers of the open-source RFID analysis ecosystem.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("ProxBuddy is licensed under the GNU General Public License v3.0 (GPL-3.0).")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.hackerGreen)
                }
                .liquidGlassCard()

                // 1. Proxmark3 / RRG Iceman
                creditCard(
                    title: "Proxmark3 / RRG Iceman Firmware",
                    authors: "Jonathan Westhues, Iceman (@iceman1001), DXL (@xianglin1998) & RFID Research Group",
                    license: "GPL-2.0-or-later",
                    description: "Native C client engine, RFID protocol decoders, and card emulation framework.",
                    url: "https://github.com/RfidResearchGroup/proxmark3"
                )

                // 2. Proxmark5 BWM
                creditCard(
                    title: "Proxmark5 BWM ESP32 Firmware",
                    authors: "DXL (@xianglin1998) & RFID Research Group",
                    license: "GPL-3.0 / Apache-2.0 (ESP-IDF)",
                    description: "Wireless Bluetooth LE SPP (0xAE86/0xAE88), Battery Service (0x180F), and Wi-Fi Direct module specs.",
                    url: "https://github.com/RfidResearchGroup/Proxmark5_BWM_esp32"
                )

                // 3. OpenSSL
                creditCard(
                    title: "OpenSSL Cryptographic Toolkit (v3.4.1)",
                    authors: "The OpenSSL Project Authors",
                    license: "Apache-2.0",
                    description: "High-performance cryptographic functions for MIFARE Classic nested attacks and DES brute-forcing.",
                    url: "https://www.openssl.org"
                )

                // 4. BeeWare / Python
                creditCard(
                    title: "Python for iOS (BeeWare Project)",
                    authors: "Python Software Foundation & The BeeWare Project",
                    license: "PSF License & BSD 3-Clause",
                    description: "Embedded Python 3.13 runtime supporting Proxmark3 Python scripts and extensions.",
                    url: "https://beeware.org"
                )
            }
            .padding()
        }
        .hackerBackground()
        .navigationTitle("Licenses & Credits")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func creditCard(title: String, authors: String, license: String, description: String, url: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .hackerText().font(.subheadline)
                Spacer()
                Text(license)
                    .font(.system(.caption2, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.hackerGreen.opacity(0.15))
                    .foregroundStyle(.hackerGreen)
                    .clipShape(Capsule())
            }
            
            Text("Authors: \(authors)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)

            Link(destination: URL(string: url)!) {
                HStack(spacing: 4) {
                    Text(url).font(.system(.caption2, design: .monospaced))
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption2)
                }
                .foregroundStyle(.hackerGreen)
            }
        }
        .liquidGlassCard()
    }
}
