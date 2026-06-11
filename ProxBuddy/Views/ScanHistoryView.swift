import SwiftUI

struct ScanHistoryView: View {
    @EnvironmentObject var store: ScanHistoryStore
    @State private var showClearConfirm = false
    @State private var searchText = ""

    private var filtered: [ScanRecord] {
        guard !searchText.isEmpty else { return store.records }
        let q = searchText.lowercased()
        return store.records.filter {
            $0.uid?.lowercased().contains(q) == true
            || $0.cardType.lowercased().contains(q)
            || $0.protocol_.lowercased().contains(q)
            || $0.command.lowercased().contains(q)
        }
    }

    // Group by calendar day
    private var grouped: [(label: String, records: [ScanRecord])] {
        let cal = Calendar.current
        var today:    [ScanRecord] = []
        var week:     [ScanRecord] = []
        var older:    [ScanRecord] = []

        for r in filtered {
            if cal.isDateInToday(r.timestamp)                         { today.append(r) }
            else if r.timestamp > Date().addingTimeInterval(-604800)  { week.append(r) }
            else                                                       { older.append(r) }
        }
        return [(today, "Today"), (week, "This Week"), (older, "Older")]
            .compactMap { $0.0.isEmpty ? nil : ($0.1, $0.0) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.records.isEmpty {
                    ContentUnavailableView(
                        "No Scans Yet",
                        systemImage: "wave.3.right",
                        description: Text("Read a card and the results will appear here.")
                    )
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List {
                        ForEach(grouped, id: \.label) { section in
                            Section(section.label) {
                                ForEach(section.records) { record in
                                    ScanRowView(record: record)
                                        .swipeActions(edge: .trailing) {
                                            Button(role: .destructive) {
                                                store.delete(record)
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Scan History")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "UID, type, protocol…")
            .toolbar {
                if !store.records.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Clear All", role: .destructive) {
                            showClearConfirm = true
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
            .confirmationDialog("Clear all scan history?", isPresented: $showClearConfirm,
                                titleVisibility: .visible) {
                Button("Clear All", role: .destructive) { store.clearAll() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

// MARK: - Row

private struct ScanRowView: View {
    let record: ScanRecord

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Image(systemName: record.icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Content
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(record.cardType)
                        .font(.subheadline).fontWeight(.semibold)
                    Spacer()
                    Text(record.timestamp, style: .time)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let uid = record.uid {
                    Text(uid)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.green)
                }
                HStack(spacing: 6) {
                    Text(record.protocol_)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(tint.opacity(0.12))
                        .foregroundStyle(tint)
                        .clipShape(Capsule())
                    if !record.details.isEmpty {
                        Text(record.details)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var tint: Color {
        switch record.tintColor {
        case "blue":   return .blue
        case "cyan":   return .cyan
        case "purple": return .purple
        case "indigo": return .indigo
        case "orange": return .orange
        case "green":  return .green
        case "yellow": return .yellow
        default:       return .gray
        }
    }
}
