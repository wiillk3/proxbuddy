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
            Form {


                Section("Display") {
                    Toggle("Show Timestamps", isOn: $showTimestamps)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Font Size")
                            Spacer()
                            Text("\(Int(fontSize)) pt")
                                .foregroundStyle(.secondary)
                                .font(.system(.caption, design: .monospaced))
                        }
                        Slider(value: $fontSize, in: 9...22, step: 1)
                            .tint(.green)
                    }

                    Text("hf mf info → [+] UID: C5 EC A5 9A")
                        .font(.system(size: CGFloat(fontSize), design: .monospaced))
                        .foregroundStyle(Color(red: 0.2, green: 0.9, blue: 0.2))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }

                Section("Command Builder") {
                    Toggle("Switch to Terminal after Send", isOn: $builderAutoSwitch)
                    Text("Automatically jumps to the Terminal tab when you tap Send in the command builder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Stub command flow in terminal", isOn: $stubCommandFlow)
                    Text("Hides the --help queries the builder sends to pm3 while loading options. Turn off to see them in the terminal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Files") {
                    Toggle("Stub emulator commands in terminal", isOn: $stubEmulatorFlow)
                    Text("Hides Load to Emulator output from the terminal. Simulate and View Emulator Memory are always handled in the Files tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Logging") {
                    Stepper("Retain logs for \(logRetentionDays) days", value: $logRetentionDays, in: 1...365)
                    Button("Purge old logs") { purgeOldLogs() }
                        .foregroundStyle(.red)
                }


                Section("About") {
                    LabeledContent("pm3client", value: pm3Version)
                    LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "—")
                    LabeledContent("App version", value: appVersion)
                    Link("RRG/Iceman Firmware",
                         destination: URL(string: "https://github.com/RfidResearchGroup/proxmark3")!)
                }
            }
            .navigationTitle("Settings")
            .task { pm3Version = await fetchPm3Version() }
        }
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
