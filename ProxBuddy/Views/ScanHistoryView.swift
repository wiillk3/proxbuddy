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
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(grouped, id: \.label) { section in
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(section.label.uppercased()).hackerText().font(.subheadline).opacity(0.8)
                                    VStack(spacing: 0) {
                                        ForEach(Array(section.records.enumerated()), id: \.element.id) { idx, record in
                                            ScanRowView(record: record)
                                                .contextMenu {
                                                    Button(role: .destructive) { store.delete(record) } label: { Label("Delete", systemImage: "trash") }
                                                }
                                            if idx < section.records.count - 1 { Divider().background(Color.glassBorder) }
                                        }
                                    }
                                    .liquidGlassCard()
                                }
                                .padding(.horizontal)
                            }
                        }
                        .padding(.vertical)
                    }
                }
            }
            .hackerBackground()
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
                .foregroundStyle(.hackerGreen)
                .frame(width: 34, height: 34)

            // Content
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(record.cardType)
                        .hackerText().fontWeight(.semibold)
                    Spacer()
                    Text(record.timestamp, style: .time)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let uid = record.uid {
                    Text(uid)
                        .hackerText()
                        .font(.system(.caption, design: .monospaced))
                }
                HStack(spacing: 6) {
                    Text(record.protocol_)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.hackerGreen.opacity(0.12))
                        .foregroundStyle(.hackerGreen)
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
        .padding(.vertical, 8)
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
