import SwiftUI

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
        let dumpExts: Set<String> = ["bin", "eml", "json"]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: pm3Dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return }

        let loaded = entries
            .filter { dumpExts.contains($0.pathExtension.lowercased()) }
            .compactMap { url -> DumpFile? in
                let r = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return DumpFile(url: url, modDate: r?.contentModificationDate ?? .now,
                                size: Int64(r?.fileSize ?? 0))
            }
            .sorted { $0.modDate > $1.modDate }

        allFiles = loaded
        groups = DumpGroup.group(loaded)
        lastKnownURLs = Set(loaded.map(\.url))
    }

    func delete(_ file: DumpFile) {
        try? FileManager.default.removeItem(at: file.url)
        refresh()
    }

    func delete(_ group: DumpGroup) {
        group.files.forEach { try? FileManager.default.removeItem(at: $0.url) }
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
        List {
            ForEach(vm.groupedByDate, id: \.label) { bucket in
                Section(bucket.label) {
                    ForEach(bucket.groups) { group in
                        NavigationLink {
                            DumpDetailView(group: group, vm: vm)
                        } label: {
                            DumpGroupRow(group: group)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { vm.delete(group) } label: {
                                Label("Delete All", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if let f = group.primaryFile,
                               let cmd = group.family.eloadCommand(file: f.baseName) {
                                Button {
                                    engine.sendCommand(cmd)
                                    appNav.selectedTab = AppNavigation.terminalTab
                                } label: { Label("Load", systemImage: "memorychip") }
                                .tint(.green)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
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
                    .font(.system(.body, design: .monospaced)).fontWeight(.semibold)
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
                }
            }
            Spacer()
            Text(DumpGroupRow.dateFmt.string(from: group.latestDate))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
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
            headerCard

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
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(uiColor: .systemGroupedBackground))

                switch selectedTab {
                case 0: BlocksTabView(dump: dump)
                case 1: KeysTabView(dump: dump)
                case 2: FilesTabView(group: group, vm: vm)
                default: ActionsTabView(group: group, parsed: dump, engine: engine, appNav: appNav, vm: vm)
                }
            } else {
                // No parseable dump file — show file list only
                Picker("", selection: $selectedTab) {
                    Text("Files").tag(0)
                    Text("Actions").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color(uiColor: .systemGroupedBackground))

                if selectedTab == 0 {
                    FilesTabView(group: group, vm: vm)
                } else {
                    ActionsTabView(group: group, parsed: nil, engine: engine, appNav: appNav, vm: vm)
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
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
                Text(group.family.displayName).font(.headline)
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
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
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
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(dump.sectors) { sector in
                    Section {
                        ForEach(sector.blocks) { block in
                            blockRow(block, isTrailer: block.id == sector.trailerBlock.id)
                        }
                    } header: {
                        sectorHeader(sector)
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func sectorHeader(_ sector: MFSector) -> some View {
        HStack(spacing: 8) {
            Text("Sector \(sector.id)")
                .font(.system(.caption, design: .monospaced)).fontWeight(.bold)
            Spacer()
            keyPill("A", key: sector.keyA, status: sector.keyAStatus)
            keyPill("B", key: sector.keyB, status: sector.keyBStatus)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private func blockRow(_ block: MFBlock, isTrailer: Bool) -> some View {
        HStack(spacing: 0) {
            Text(String(format: "%3d", block.id))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
                .padding(.leading, 12)

            Text("  " + block.hex)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(isTrailer ? Color.orange : (block.isBlank ? Color.secondary.opacity(0.5) : Color.primary))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(block.ascii)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .frame(width: 82, alignment: .leading)
                .padding(.trailing, 8)
        }
        .padding(.vertical, 3)
        .background(isTrailer ? Color.orange.opacity(0.05) : Color.clear)
    }

    private func keyPill(_ letter: String, key: String, status: MFSector.KeyStatus) -> some View {
        let color: Color = switch status {
        case .defaultKey: .orange
        case .blank:      .red
        case .custom:     .green
        }
        return HStack(spacing: 2) {
            Text("K\(letter)").font(.system(.caption2, design: .monospaced)).fontWeight(.bold)
            Text(key.prefix(6)).font(.system(.caption2, design: .monospaced))
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(color.opacity(0.15)).foregroundStyle(color)
        .clipShape(Capsule())
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

                ForEach(dump.sectors) { sector in
                    keysRow(sector)
                    Divider().padding(.leading, 44)
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
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
        .background(Color(uiColor: .systemGroupedBackground))
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
        .background(Color(uiColor: .tertiarySystemGroupedBackground))
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
        List {
            Section {
                ForEach(group.files) { file in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.fileName)
                                .font(.system(.subheadline, design: .monospaced))
                                .lineLimit(1)
                            Text("\(file.ext.uppercased()) · \(file.sizeString) · \(file.modDate.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        ShareLink(item: file.url) {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { vm.delete(file) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("\(group.files.count) file\(group.files.count == 1 ? "" : "s")")
            }
        }
        .listStyle(.insetGrouped)
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
        List {
            if let f = group.primaryFile {
                Section("Emulator") {
                    if let cmd = group.family.eloadCommand(file: f.baseName) {
                        actionRow("Load to Emulator", icon: "memorychip", color: .green) {
                            if stubEmulator {
                                Task { _ = await engine.captureOutputSilent(cmd) }
                            } else {
                                engine.sendCommand(cmd)
                            }
                        }
                    }

                    if let simCmd = group.family.simCommand(uid: group.uid, is4K: is4K) {
                        actionRow(
                            isSimulating ? "Stop Simulation" : "Simulate",
                            icon: isSimulating ? "stop.circle.fill" : "wave.3.right",
                            color: isSimulating ? .red : .orange
                        ) {
                            if isSimulating {
                                engine.sendCommand("q")
                                isSimulating = false
                            } else {
                                Task {
                                    // Automatically load to emulator memory first
                                    if let eload = group.family.eloadCommand(file: f.baseName) {
                                        _ = await engine.captureOutputSilent(eload)
                                    }
                                    engine.sendCommand(simCmd)
                                    isSimulating = true
                                    appNav.selectedTab = AppNavigation.terminalTab
                                }
                            }
                        }
                    }

                    if group.family.eviewCommand != nil {
                        actionRow(
                            isCapturingEview ? "Reading…" : "View Emulator Memory",
                            icon: isCapturingEview ? "hourglass" : "doc.text.magnifyingglass",
                            color: .teal
                        ) {
                            guard !isCapturingEview, let cmd = group.family.eviewCommand else { return }
                            Task {
                                isCapturingEview = true
                                eviewLines = await engine.captureOutputSilent(cmd)
                                isCapturingEview = false
                                showEview = true
                            }
                        }
                        .disabled(isCapturingEview)
                    }
                }

                if group.family == .mifareClassic {
                    Section("Write to Physical Card") {
                        actionRow("Restore (gen1)", icon: "arrow.triangle.2.circlepath", color: .blue) {
                            engine.sendCommand("hf mf restore -f \(f.baseName)")
                            appNav.selectedTab = AppNavigation.terminalTab
                        }
                        actionRow("Write (gen4 GTU)", icon: "square.and.pencil", color: .indigo) {
                            engine.sendCommand("hf mf gload -f \(f.baseName)")
                            appNav.selectedTab = AppNavigation.terminalTab
                        }
                    }
                }
            }

            Section {
                actionRow("Delete All Files", icon: "trash", color: .red, role: .destructive) {
                    vm.delete(group)
                }
            }
        }
        .listStyle(.insetGrouped)
        .sheet(isPresented: $showEview) {
            EmulatorMemorySheet(lines: eviewLines)
        }
    }

    private var is4K: Bool {
        if let p = parsed { return p.blockCount > 64 }
        if let bin = group.files.first(where: { $0.ext == "bin" && !$0.isKeyFile }) {
            return bin.size > 2048
        }
        return false
    }

    private func actionRow(_ title: String, icon: String, color: Color,
                            role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: icon)
                .foregroundStyle(role == .destructive ? .red : color)
        }
    }
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
