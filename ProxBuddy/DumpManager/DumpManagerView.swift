import SwiftUI
import MapKit

// MARK: - ViewModel

@MainActor
final class DumpManagerViewModel: ObservableObject {
    @Published var groups: [DumpGroup] = []

    private var allFiles: [DumpFile] = []
    private var lastKnownURLs: Set<URL> = []
    private var timer: Timer?

    var pm3Dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pm3")
    }

    func startWatching() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopWatching() { timer?.invalidate(); timer = nil }

    func refresh() {
        try? FileManager.default.createDirectory(at: pm3Dir, withIntermediateDirectories: true)
        CardLocation.purgeRunawaySidecars(in: pm3Dir)

        let dumpExts: Set<String> = ["bin", "eml", "json"]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: pm3Dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return }

        let loaded = entries
            .filter { dumpExts.contains($0.pathExtension.lowercased()) && !CardLocation.isSidecar($0) }
            .compactMap { url -> DumpFile? in
                let r = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return DumpFile(url: url, modDate: r?.contentModificationDate ?? .now,
                                size: Int64(r?.fileSize ?? 0))
            }
            .sorted { $0.modDate > $1.modDate }

        // Tag newly detected dumps with GPS coordinates if feature is enabled
        let enableGPS = UserDefaults.standard.bool(forKey: "enableGPSLocationTagging")
        if enableGPS {
            for file in loaded where !lastKnownURLs.contains(file.url) {
                if CardLocation.load(for: file.url) == nil,
                   let snapshot = LocationManager.shared.snapshotCurrentLocation() {
                    snapshot.save(for: file.url)
                }
            }
        }

        allFiles = loaded
        groups = DumpGroup.group(loaded)
        lastKnownURLs = Set(loaded.map(\.url))
    }

    func delete(_ file: DumpFile) {
        CardLocation.remove(for: file.url)
        try? FileManager.default.removeItem(at: file.url)
        refresh()
    }

    func delete(_ group: DumpGroup) {
        group.files.forEach {
            CardLocation.remove(for: $0.url)
            try? FileManager.default.removeItem(at: $0.url)
        }
        refresh()
    }

    // Recency buckets
    var groupedByDate: [(label: String, groups: [DumpGroup])] {
        let cal = Calendar.current
        var today: [DumpGroup] = []
        var week: [DumpGroup] = []
        var older: [DumpGroup] = []
        for g in groups {
            if cal.isDateInToday(g.latestDate)                           { today.append(g) }
            else if g.latestDate > Date().addingTimeInterval(-604800)    { week.append(g) }
            else                                                          { older.append(g) }
        }
        return [(today, "Today"), (week, "This Week"), (older, "Older")]
            .compactMap { $0.0.isEmpty ? nil : ($0.1, $0.0) }
    }
}

// MARK: - Root view

struct DumpManagerView: View {
    @EnvironmentObject var engine: TerminalEngine
    @EnvironmentObject var appNav: AppNavigation
    @StateObject private var vm = DumpManagerViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if vm.groups.isEmpty { emptyState }
                else { groupList }
            }
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { vm.refresh() } label: { Image(systemName: "arrow.clockwise") }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink {
                        KeyDictManagerView()
                    } label: {
                        Label("Keys & Dicts", systemImage: "key.fill")
                    }
                }
            }
        }
        .onAppear  { vm.startWatching() }
        .onDisappear { vm.stopWatching() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Dumps Yet", systemImage: "doc.fill")
        } description: {
            Text("Run a dump command in the terminal\n(e.g. hf mf autopwn) and files appear here.")
        } actions: {
            Button("Go to Terminal") { appNav.selectedTab = AppNavigation.terminalTab }
                .buttonStyle(.bordered)
        }
    }

    private var groupList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(vm.groupedByDate, id: \.label) { bucket in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(bucket.label.uppercased()).hackerText().font(.subheadline).opacity(0.8)
                        VStack(spacing: 0) {
                            ForEach(Array(bucket.groups.enumerated()), id: \.element.id) { idx, group in
                                NavigationLink {
                                    DumpDetailView(group: group, vm: vm)
                                } label: {
                                    DumpGroupRow(group: group)
                                }
                                .buttonStyle(.plain)
                                .contentShape(Rectangle())
                                .contextMenu {
                                    Button(role: .destructive) { vm.delete(group) } label: { Label("Delete All", systemImage: "trash") }
                                    if let f = group.primaryFile, let cmd = group.family.eloadCommand(file: f.baseName) {
                                        Button {
                                            engine.sendCommand(cmd)
                                            appNav.selectedTab = AppNavigation.terminalTab
                                        } label: { Label("Load", systemImage: "memorychip") }
                                    }
                                }
                                if idx < bucket.groups.count - 1 {
                                    Divider().background(Color.glassBorder).padding(.leading, 56)
                                }
                            }
                        }
                        .liquidGlassCard()
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .hackerBackground()
    }
}

// MARK: - Group row

struct DumpGroupRow: View {
    let group: DumpGroup

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(group.family.tint.opacity(0.15)).frame(width: 44, height: 44)
                Image(systemName: group.family.icon)
                    .foregroundStyle(group.family.tint).font(.system(size: 20))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(group.uid ?? group.id)
                    .hackerText().fontWeight(.semibold)
                Text(group.family.displayName)
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    ForEach(group.formatPills, id: \.self) { pill in
                        Text(pill)
                            .font(.system(.caption2, design: .monospaced))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.18))
                            .clipShape(Capsule())
                    }
                    if let loc = group.location {
                        Text("📍 \(loc.address ?? "Tagged")")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.hackerGreen)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            Text(DumpGroupRow.dateFmt.string(from: group.latestDate))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Detail view

struct DumpDetailView: View {
    let group: DumpGroup
    @ObservedObject var vm: DumpManagerViewModel
    @EnvironmentObject var engine: TerminalEngine
    @EnvironmentObject var appNav: AppNavigation

    @State private var parsed: ParsedMFDump?
    @State private var isLoading = true
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            headerCard.padding(.bottom, 8)

            if let loc = group.location {
                DumpLocationCard(location: loc)
                    .padding(.bottom, 8)
            }

            if isLoading {
                Spacer()
                ProgressView("Reading dump…")
                Spacer()
            } else if let dump = parsed {
                Picker("", selection: $selectedTab) {
                    Text("Blocks").tag(0)
                    Text("Keys").tag(1)
                    Text("Files").tag(2)
                    Text("Actions").tag(3)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                switch selectedTab {
                case 0: BlocksTabView(dump: dump)
                case 1: KeysTabView(dump: dump)
                case 2: FilesTabView(group: group, vm: vm)
                default: ActionsTabView(group: group, parsed: dump, engine: engine, appNav: appNav, vm: vm)
                }
            } else {
                Picker("", selection: $selectedTab) {
                    Text("Files").tag(0)
                    Text("Actions").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                if selectedTab == 0 {
                    FilesTabView(group: group, vm: vm)
                } else {
                    ActionsTabView(group: group, parsed: nil, engine: engine, appNav: appNav, vm: vm)
                }
            }
        }
        .hackerBackground()
        .navigationTitle(group.uid ?? group.id)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadContent() }
    }

    private var headerCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(group.family.tint.opacity(0.15))
                    .frame(width: 50, height: 50)
                Image(systemName: group.family.icon)
                    .foregroundStyle(group.family.tint).font(.system(size: 22))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(group.family.displayName).font(.headline).foregroundStyle(.primary)
                if let dump = parsed {
                    Text(dump.cardLabel).font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        infoChip("UID", dump.uid)
                        if dump.atqa != "?" { infoChip("ATQA", dump.atqa) }
                        if dump.sak  != "?" { infoChip("SAK",  dump.sak)  }
                    }
                } else if let uid = group.uid {
                    Text(uid).font(.subheadline.monospaced()).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .liquidGlassCard()
        .padding(.horizontal, 16)
    }

    private func infoChip(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(.caption2)).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced)).fontWeight(.medium)
        }
    }

    private func loadContent() async {
        isLoading = true
        if let file = group.primaryFile {
            parsed = await Task.detached(priority: .userInitiated) {
                ParsedMFDump.from(url: file.url)
            }.value
        }
        isLoading = false
    }
}

// MARK: - Blocks tab

struct BlocksTabView: View {
    let dump: ParsedMFDump

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header bar
                HStack(spacing: 0) {
                    Text("BLK").font(.system(size: 10, design: .monospaced)).fontWeight(.bold).foregroundStyle(.secondary).frame(width: 32, alignment: .center)
                    Text("DATA (16 BYTES)").font(.system(size: 10, design: .monospaced)).fontWeight(.bold).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                    Text("ASCII").font(.system(size: 10, design: .monospaced)).fontWeight(.bold).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.4))

                Divider().background(Color.glassBorder)

                let allBlocks = dump.sectors.flatMap(\.blocks)
                ForEach(Array(allBlocks.enumerated()), id: \.element.id) { idx, block in
                    // Subtle line divider at sector boundaries
                    if idx > 0 && isSectorStart(blockId: block.id) {
                        Rectangle()
                            .fill(Color.hackerGreen.opacity(0.4))
                            .frame(height: 1)
                    }

                    unifiedBlockRow(block, isTrailer: isSectorTrailer(blockId: block.id), isBlock0: block.id == 0)
                    
                    if idx < allBlocks.count - 1 && !isSectorStart(blockId: allBlocks[idx + 1].id) {
                        Divider().background(Color.glassBorder.opacity(0.2))
                    }
                }
            }
            .liquidGlassCard()
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .hackerBackground()
    }

    private func isSectorStart(blockId: Int) -> Bool {
        dump.sectors.contains { $0.blocks.first?.id == blockId }
    }

    private func isSectorTrailer(blockId: Int) -> Bool {
        dump.sectors.contains { $0.trailerBlock.id == blockId }
    }

    private func unifiedBlockRow(_ block: MFBlock, isTrailer: Bool, isBlock0: Bool) -> some View {
        HStack(spacing: 0) {
            Text(String(format: "%02d", block.id))
                .font(.system(size: 11, design: .monospaced))
                .fontWeight(isTrailer || isBlock0 ? .bold : .regular)
                .foregroundStyle(isBlock0 ? Color.cyan : (isTrailer ? Color.orange : Color.secondary))
                .frame(width: 32, alignment: .center)

            Text(block.hex)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(
                    isBlock0 ? Color.cyan :
                    (isTrailer ? Color.orange :
                    (block.isBlank ? Color.secondary.opacity(0.4) : Color.primary))
                )
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)

            Text(block.ascii)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.secondary.opacity(0.7))
                .frame(width: 82, alignment: .leading)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            isBlock0 ? Color.cyan.opacity(0.06) :
            (isTrailer ? Color.orange.opacity(0.06) : Color.clear)
        )
    }
}

// MARK: - Keys tab

struct KeysTabView: View {
    let dump: ParsedMFDump

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header row
                keysHeaderRow

                ForEach(Array(dump.sectors.enumerated()), id: \.element.id) { idx, sector in
                    keysRow(sector)
                    if idx < dump.sectors.count - 1 {
                        Divider().background(Color.glassBorder).padding(.leading, 44)
                    }
                }
            }
            .liquidGlassCard()
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 20)

            // Legend
            HStack(spacing: 16) {
                legendChip(.orange, "Default / weak")
                legendChip(.green,  "Custom")
                legendChip(.red,    "Blank / unknown")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .hackerBackground()
    }

    private var keysHeaderRow: some View {
        HStack(spacing: 0) {
            Text("SEC").frame(width: 44, alignment: .center)
            Text("KEY A").frame(maxWidth: .infinity, alignment: .leading)
            Text("KEY B").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption2, design: .monospaced)).fontWeight(.bold)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.black.opacity(0.3))
    }

    private func keysRow(_ sector: MFSector) -> some View {
        HStack(spacing: 0) {
            Text(String(format: "%02d", sector.id))
                .font(.system(.caption, design: .monospaced)).fontWeight(.medium)
                .frame(width: 44, alignment: .center)

            keyCell(sector.keyA, status: sector.keyAStatus)
            keyCell(sector.keyB, status: sector.keyBStatus)
        }
        .padding(.vertical, 7).padding(.horizontal, 12)
    }

    private func keyCell(_ key: String, status: MFSector.KeyStatus) -> some View {
        let color: Color = switch status {
        case .defaultKey: .orange
        case .blank:      .red
        case .custom:     .green
        }
        return Text(key)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legendChip(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Files tab

struct FilesTabView: View {
    let group: DumpGroup
    @ObservedObject var vm: DumpManagerViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(group.files.count) file\(group.files.count == 1 ? "" : "s")".uppercased())
                    .hackerText().font(.subheadline).opacity(0.8)
                VStack(spacing: 0) {
                    ForEach(Array(group.files.enumerated()), id: \.element.id) { idx, file in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.fileName)
                                    .hackerText().font(.subheadline)
                                    .lineLimit(1)
                                Text("\(file.ext.uppercased()) · \(file.sizeString) · \(file.modDate.formatted(.relative(presentation: .named)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            ShareLink(item: file.url) {
                                Image(systemName: "square.and.arrow.up")
                                    .foregroundStyle(.hackerGreen)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 8)
                        .contextMenu {
                            Button(role: .destructive) { vm.delete(file) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        if idx < group.files.count - 1 { Divider().background(Color.glassBorder) }
                    }
                }
                .liquidGlassCard()
            }
            .padding()
        }
        .hackerBackground()
    }
}

// MARK: - Actions tab

struct ActionsTabView: View {
    let group: DumpGroup
    let parsed: ParsedMFDump?
    let engine: TerminalEngine
    let appNav: AppNavigation
    @ObservedObject var vm: DumpManagerViewModel

    @State private var isSimulating = false
    @State private var showEview = false
    @State private var eviewLines: [String] = []
    @State private var isCapturingEview = false
    @AppStorage("stubEmulatorFlow") private var stubEmulator = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if let f = group.primaryFile {
                    let emulatorRows = emulatorActionRows(file: f)
                    if !emulatorRows.isEmpty {
                        actionSection("EMULATOR", rows: emulatorRows)
                    }

                    if group.family == .mifareClassic {
                        actionSection("WRITE TO PHYSICAL CARD", rows: [
                            ActionRowSpec(
                                title: "Restore (gen1)",
                                icon: "arrow.triangle.2.circlepath",
                                color: .blue
                            ) {
                                engine.sendCommand("hf mf restore -f \(f.baseName)")
                                appNav.selectedTab = AppNavigation.terminalTab
                            },
                            ActionRowSpec(
                                title: "Write (gen4 GTU)",
                                icon: "square.and.pencil",
                                color: .indigo
                            ) {
                                engine.sendCommand("hf mf gload -f \(f.baseName)")
                                appNav.selectedTab = AppNavigation.terminalTab
                            },
                        ])
                    }
                }

                actionSection("DANGER ZONE", rows: [
                    ActionRowSpec(
                        title: "Delete All Files",
                        icon: "trash",
                        color: .red,
                        role: .destructive
                    ) {
                        vm.delete(group)
                    },
                ])
            }
            .padding()
        }
        .hackerBackground()
        .sheet(isPresented: $showEview) {
            EmulatorMemorySheet(lines: eviewLines)
        }
    }

    private func emulatorActionRows(file: DumpFile) -> [ActionRowSpec] {
        var rows: [ActionRowSpec] = []
        if let cmd = group.family.eloadCommand(file: file.baseName) {
            rows.append(ActionRowSpec(title: "Load to Emulator", icon: "memorychip", color: .hackerGreen) {
                if stubEmulator {
                    Task { _ = await engine.captureOutputSilent(cmd) }
                } else {
                    engine.sendCommand(cmd)
                }
            })
        }
        if let simCmd = group.family.simCommand(uid: group.uid, is4K: is4K) {
            rows.append(ActionRowSpec(
                title: isSimulating ? "Stop Simulation" : "Simulate",
                icon: isSimulating ? "stop.circle.fill" : "wave.3.right",
                color: isSimulating ? .red : .orange
            ) {
                if isSimulating {
                    engine.sendCommand("q")
                    isSimulating = false
                } else {
                    Task {
                        if let eload = group.family.eloadCommand(file: file.baseName) {
                            _ = await engine.captureOutputSilent(eload)
                        }
                        engine.sendCommand(simCmd)
                        isSimulating = true
                        appNav.selectedTab = AppNavigation.terminalTab
                    }
                }
            })
        }
        if group.family.eviewCommand != nil {
            rows.append(ActionRowSpec(
                title: isCapturingEview ? "Reading…" : "View Emulator Memory",
                icon: isCapturingEview ? "hourglass" : "doc.text.magnifyingglass",
                color: .teal,
                disabled: isCapturingEview
            ) {
                guard !isCapturingEview, let cmd = group.family.eviewCommand else { return }
                Task {
                    isCapturingEview = true
                    eviewLines = await engine.captureOutputSilent(cmd)
                    isCapturingEview = false
                    showEview = true
                }
            })
        }
        return rows
    }

    private var is4K: Bool {
        if let p = parsed { return p.blockCount > 64 }
        if let bin = group.files.first(where: { $0.ext == "bin" && !$0.isKeyFile }) {
            return bin.size > 2048
        }
        return false
    }

    private func actionSection(_ title: String, rows: [ActionRowSpec]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).hackerText().font(.subheadline).opacity(0.8)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                    actionRow(row)
                    if idx < rows.count - 1 {
                        Divider().background(Color.glassBorder)
                    }
                }
            }
            .liquidGlassCard()
        }
    }

    private func actionRow(_ spec: ActionRowSpec) -> some View {
        Button(role: spec.role, action: spec.action) {
            HStack(spacing: 12) {
                Image(systemName: spec.icon)
                    .foregroundStyle(spec.role == .destructive ? .red : spec.color)
                    .frame(width: 22, alignment: .center)
                Text(spec.title)
                    .foregroundStyle(spec.role == .destructive ? .red : .primary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(spec.disabled)
    }
}

private struct ActionRowSpec: Identifiable {
    var id: String { title }
    let title: String
    let icon: String
    let color: Color
    var role: ButtonRole? = nil
    var disabled: Bool = false
    let action: () -> Void
}

struct EmulatorMemorySheet: View {
    let lines: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(ANSIParser.parse(line, fontSize: 12))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(Color(white: 0.07))
            .navigationTitle("Emulator Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - MapKit Dump Location Card

struct DumpLocationCard: View {
    let location: CardLocation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("CAPTURE LOCATION", systemImage: "location.fill")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.hackerGreen)
                Spacer()
                Text(location.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Map(initialPosition: .region(MKCoordinateRegion(
                center: location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
            ))) {
                Marker(location.address ?? "Card Dump Location", coordinate: location.coordinate)
                    .tint(.hackerGreen)
            }
            .frame(height: 120)
            .cornerRadius(8)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if let address = location.address {
                        Text(address)
                            .font(.system(.caption, design: .monospaced))
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                    }
                    Text(location.formattedCoordinates)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Link(destination: URL(string: "https://maps.apple.com/?q=\(location.latitude),\(location.longitude)")!) {
                    Label("Maps", systemImage: "arrow.up.right.circle.fill")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.hackerGreen)
                }
            }
        }
        .liquidGlassCard()
        .padding(.horizontal, 16)
    }
}
