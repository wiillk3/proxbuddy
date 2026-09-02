import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var scanHistory:  ScanHistoryStore

    @AppStorage("showTimestamps") var showTimestamps = false
    @AppStorage("logRetentionDays") var logRetentionDays = 30
    @AppStorage("terminalFontSize") var fontSize: Double = 13
    @AppStorage("builderAutoSwitch") var builderAutoSwitch = true
    @AppStorage("stubCommandFlow") var stubCommandFlow = true
    @AppStorage("stubEmulatorFlow") var stubEmulatorFlow = false
    @AppStorage("enableGPSLocationTagging") var enableGPS = false

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
                        Text("FILES & LOCATION").hackerText().font(.subheadline).opacity(0.8)
                        VStack(alignment: .leading, spacing: 16) {
                            Toggle("Stub emulator commands in terminal", isOn: $stubEmulatorFlow).tint(.hackerGreen)
                            Text("Hides Load to Emulator output from the terminal. Simulate and View Emulator Memory are always handled in the Files tab.")
                                .font(.caption).foregroundStyle(.secondary)
                            
                            Divider().background(Color.glassBorder)

                            Toggle("Tag Dumps with Location (GPS)", isOn: Binding(
                                get: { enableGPS },
                                set: { newValue in
                                    enableGPS = newValue
                                    if newValue {
                                        LocationManager.shared.startUpdating()
                                    } else {
                                        LocationManager.shared.stopUpdating()
                                    }
                                }
                            )).tint(.hackerGreen)
                            
                            Text("Off by default. When enabled, saves coordinates and a place name next to dumps in this app’s Documents folder. Nothing is uploaded.")
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
                            HStack(alignment: .firstTextBaseline) {
                                Text("pm3client")
                                Spacer(minLength: 12)
                                Text(PM3ClientVersion.bundledSummary)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                                    .textSelection(.enabled)
                            }
                            Divider().background(Color.glassBorder)
                            HStack { Text("App version"); Spacer(); Text(appVersion).foregroundStyle(.secondary) }
                            Divider().background(Color.glassBorder)
                            Text(AppLegal.warrantyLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Divider().background(Color.glassBorder)
                            settingsNavLink("Privacy Policy", systemImage: "hand.raised.fill") {
                                PrivacyPolicyView()
                            }
                            Divider().background(Color.glassBorder)
                            settingsNavLink("Open Source Licenses & Credits", systemImage: "doc.text.fill") {
                                AcknowledgementsView()
                            }
                            Divider().background(Color.glassBorder)
                            settingsURL("Source code", systemImage: "chevron.left.forwardslash.chevron.right", url: AppLegal.sourceURL)
                            Divider().background(Color.glassBorder)
                            settingsURL("Support", systemImage: "questionmark.circle.fill", url: AppLegal.supportURL)
                            Divider().background(Color.glassBorder)
                            settingsURL("RRG/Iceman Firmware Repo", systemImage: "link", url: AppLegal.icemanURL)
                        }
                        .liquidGlassCard()
                    }
                }
                .padding()
            }
            .hackerBackground()
            .navigationTitle("Settings")
        }
        .preferredColorScheme(.dark)
    }

    private func settingsNavLink<V: View>(_ title: String, systemImage: String, @ViewBuilder destination: () -> V) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.hackerGreen)
        }
    }

    private func settingsURL(_ title: String, systemImage: String, url: URL) -> some View {
        Link(destination: url) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
            }
            .foregroundStyle(.hackerGreen)
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
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
