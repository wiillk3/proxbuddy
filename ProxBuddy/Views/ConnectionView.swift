import SwiftUI

struct DevicesView: View {
    @EnvironmentObject var deviceManager: DeviceManager
    @EnvironmentObject var scanHistory:   ScanHistoryStore
    @EnvironmentObject var appNav:        AppNavigation

    @State private var editingLabel: UUID?
    @State private var labelDraft   = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(deviceManager.sessions) { session in
                    sessionSection(session)
                }

                Section {
                    Button {
                        let s = deviceManager.addSession()
                        // Boot the new session immediately
                        Task { await s.boot(scanHistory: scanHistory) }
                    } label: {
                        Label("Add Device", systemImage: "plus.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Per-session section

    @ViewBuilder
    private func sessionSection(_ session: PM3Session) -> some View {
        let isActive = deviceManager.activeSession?.id == session.id

        Section {
            // Label row — tap to rename
            HStack {
                if editingLabel == session.id {
                    TextField("Device name", text: $labelDraft)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit {
                            let trimmed = labelDraft.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty { session.label = trimmed }
                            editingLabel = nil
                        }
                    Button("Done") {
                        let trimmed = labelDraft.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { session.label = trimmed }
                        editingLabel = nil
                    }
                    .foregroundStyle(.green)
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(session.isRunning ? .green : .secondary)
                        .frame(width: 22)
                    Text(session.label)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(isActive ? .semibold : .regular)
                    Spacer()
                    if isActive {
                        Text("ACTIVE")
                            .font(.system(.caption2, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if editingLabel != session.id {
                    deviceManager.setActive(session)
                }
            }
            .onLongPressGesture {
                labelDraft = session.label
                editingLabel = session.id
            }

            // Status
            LabeledContent("Transport", value: session.statusMessage)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            LabeledContent("pm3 client", value: session.isRunning ? "Running" : "Stopped")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(session.isRunning ? .green : .secondary)

            // Actions
            if session.isTransportReady {
                if session.isRunning {
                    Button("Restart pm3 Client", role: .destructive) {
                        Task { await session.restart(scanHistory: scanHistory) }
                    }
                } else {
                    Button("Start pm3 Client") {
                        Task { await session.restart(scanHistory: scanHistory) }
                    }
                    .foregroundStyle(.green)
                }
            }

            // Session log
            if let logURL = session.engine.sessionLogURL {
                ShareLink(item: logURL) {
                    Label("Export Session Log", systemImage: "square.and.arrow.up")
                }
            }

        } header: {
            Text(session.label)
        }
        .swipeActions(edge: .trailing) {
            if deviceManager.sessions.count > 1 {
                Button(role: .destructive) {
                    deviceManager.removeSession(session)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        }
    }
}
