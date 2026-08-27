import SwiftUI

@MainActor
final class CommandBuilderViewModel: ObservableObject {
    @Published var baseCommand: String
    @Published var commandHelp: CommandHelp?
    @Published var isLoading = false
    @Published var error: String?
    @Published var bools: [UUID: Bool] = [:]
    @Published var strings: [UUID: String] = [:]
    @Published var commandText: String   // single live-editable command string

    let engine: TerminalEngine

    init(engine: TerminalEngine, initialCommand: String = "") {
        self.engine = engine
        self.baseCommand = initialCommand
        self.commandText = initialCommand
    }

    func loadHelp() async {
        let cmd = baseCommand.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }
        let priorText = commandText.trimmingCharacters(in: .whitespaces)
        isLoading = true
        error = nil

        let help = await probeHelp(for: cmd)

        if !help.hasContent {
            error = "No help text found — type arguments manually or check the command."
        } else {
            commandHelp = help
            bools = [:]
            strings = [:]
            commandText = priorText.hasPrefix(cmd) ? priorText : cmd
            syncFromText()
        }
        isLoading = false
    }

    /// Native client prefers `--help`; Lua/user scripts usually only implement `-h`.
    private func probeHelp(for cmd: String) async -> CommandHelp {
        let isScript = cmd.lowercased().hasPrefix("script ")
        let stub = UserDefaults.standard.object(forKey: "stubCommandFlow") as? Bool ?? true

        let probes: [String]
        if isScript {
            probes = ["\(cmd) -h", "\(cmd) --help"]
        } else if stub {
            probes = ["\(cmd) --help", "\(cmd) -h"]
        } else {
            return HelpParser.parse(await engine.captureCommandHelp(cmd))
        }

        var best = CommandHelp(summary: "", usage: "", options: [], examples: [])
        for probe in probes {
            let parsed = HelpParser.parse(await engine.captureOutputSilent(probe))
            if parsed.rank > best.rank { best = parsed }
            if parsed.options.count >= 2 { break }
        }
        return best
    }

    // Rebuild commandText from current option state — called after every option row change
    func syncToText() {
        var parts = [baseCommand.trimmingCharacters(in: .whitespaces)]
        guard let help = commandHelp else { commandText = parts[0]; return }
        for opt in help.options where opt.primaryFlag != "--help" {
            if opt.argType == .none {
                if bools[opt.id] == true { parts.append(opt.primaryFlag) }
            } else {
                let v = strings[opt.id] ?? ""
                if !v.isEmpty {
                    if opt.isShortOnly && opt.primaryFlag.hasPrefix("<") {
                        parts.append(v)
                    } else {
                        parts.append(contentsOf: [opt.primaryFlag, v])
                    }
                }
            }
        }
        commandText = parts.joined(separator: " ")
    }

    // Parse commandText → option state; equality-guarded so re-renders only fire on real changes
    func syncFromText() {
        guard let help = commandHelp else { return }
        let allTokens = commandText
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        let baseParts = baseCommand
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true).count
        let flagTokens = Array(allTokens.dropFirst(baseParts))

        var newBools: [UUID: Bool] = [:]
        var newStrings: [UUID: String] = [:]
        var i = 0
        while i < flagTokens.count {
            let token = flagTokens[i]
            if let opt = help.options.first(where: { $0.flags.contains(token) }) {
                if opt.argType == .none {
                    newBools[opt.id] = true; i += 1
                } else if i + 1 < flagTokens.count {
                    newStrings[opt.id] = flagTokens[i + 1]; i += 2
                } else { i += 1 }
            } else { i += 1 }
        }
        if newBools != bools { bools = newBools }
        if newStrings != strings { strings = newStrings }
    }

    func sendBuilt() {
        engine.sendCommand(commandText)
    }
}

/// The command builder form. Does NOT own a NavigationStack — the caller provides it
/// (either a sheet wrapping or a pushed NavigationStack destination).
struct CommandBuilderView: View {
    @StateObject private var vm: CommandBuilderViewModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appNav: AppNavigation
    @EnvironmentObject private var favorites: FavoritesStore
    @AppStorage("builderAutoSwitch") private var autoSwitch = true

    init(engine: TerminalEngine, initialCommand: String = "") {
        _vm = StateObject(wrappedValue: CommandBuilderViewModel(engine: engine, initialCommand: initialCommand))
    }

    private var isFavorited: Bool {
        favorites.isFavorited(command: vm.commandText)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                commandSection

                if vm.isLoading {
                    HStack { Spacer(); ProgressView("Loading options…"); Spacer() }
                        .liquidGlassCard()
                }

                if let err = vm.error {
                    Label(err, systemImage: "xmark.circle").foregroundStyle(.red)
                        .liquidGlassCard()
                }

                if let help = vm.commandHelp {
                    if !help.summary.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("ABOUT").hackerText().font(.subheadline).opacity(0.8)
                            Text(help.summary)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .liquidGlassCard()
                        }
                    }

                    if !help.usage.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("USAGE").hackerText().font(.subheadline).opacity(0.8)
                            Text(help.usage)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .liquidGlassCard()
                        }
                    }

                    let opts = help.options.filter { opt in
                        !opt.flags.allSatisfy { $0 == "-h" || $0 == "--help" }
                    }
                    if !opts.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("OPTIONS").hackerText().font(.subheadline).opacity(0.8)
                            VStack(spacing: 0) {
                                ForEach(Array(opts.enumerated()), id: \.element.id) { idx, opt in
                                    optionRow(opt)
                                    if idx < opts.count - 1 {
                                        Divider().background(Color.glassBorder).padding(.vertical, 8)
                                    }
                                }
                            }
                            .liquidGlassCard()
                        }
                    } else {
                        Label("No configurable options — ready to send.", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                            .liquidGlassCard()
                    }

                    if !help.examples.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("EXAMPLES").hackerText().font(.subheadline).opacity(0.8)
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(help.examples, id: \.self) { ex in
                                    Text(ex)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .liquidGlassCard()
                        }
                    }
                }
            }
            .padding()
        }
        .hackerBackground()
        .onChange(of: vm.commandText) { _, _ in vm.syncFromText() }
        .navigationTitle(vm.baseCommand.isEmpty ? "Command Builder" : vm.baseCommand)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                let cmd = vm.commandText.trimmingCharacters(in: .whitespaces)
                Button {
                    if isFavorited {
                        if let fav = favorites.favorites.first(where: { $0.command == cmd }) {
                            favorites.remove(fav)
                        }
                    } else {
                        let label = vm.baseCommand.isEmpty ? cmd : vm.baseCommand
                        favorites.add(command: cmd, label: label)
                    }
                } label: {
                    Image(systemName: isFavorited ? "star.fill" : "star")
                        .foregroundStyle(isFavorited ? .yellow : .secondary)
                }
                .disabled(cmd.isEmpty)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Send") {
                    vm.sendBuilt()
                    dismiss()
                    if autoSwitch { appNav.selectedTab = AppNavigation.terminalTab }
                }
                .disabled(vm.isLoading || vm.commandText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            if !vm.commandText.trimmingCharacters(in: .whitespaces).isEmpty,
               vm.commandHelp == nil, !vm.isLoading {
                loadFromText()
            }
        }
    }

    // MARK: - Sections

    private var commandSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("COMMAND").hackerText().font(.subheadline).opacity(0.8)
            TextField("e.g. hf mf autopwn --1k", text: $vm.commandText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.hackerGreen)
                .liquidGlassCard()
                .onSubmit { loadFromText() }
        }
    }

    private func loadFromText() {
        let tokens = vm.commandText
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        // Base command = tokens before the first flag
        let base = tokens.prefix(while: { !$0.hasPrefix("-") }).joined(separator: " ")
        vm.baseCommand = base.isEmpty ? vm.commandText : base
        Task { await vm.loadHelp() }
    }

    // MARK: - Option rows

    @ViewBuilder
    private func optionRow(_ opt: OptionDef) -> some View {
        switch opt.argType {
        case .none:
            Toggle(isOn: Binding(
                get: { vm.bools[opt.id] ?? false },
                set: { vm.bools[opt.id] = $0; vm.syncToText() }
            )) {
                flagLabel(opt)
            }
            .tint(.hackerGreen)

        case .hex:
            OptionInputRow(opt: opt, placeholder: "hex bytes e.g. AABBCCDD", keyboard: .default, vm: vm)
        case .decimal:
            OptionInputRow(opt: opt, placeholder: "number", keyboard: .numberPad, vm: vm)
        case .file:
            OptionFileRow(opt: opt, vm: vm)
        case .binary:
            OptionInputRow(opt: opt, placeholder: "binary string e.g. 0001101", keyboard: .default, vm: vm)
        case .string:
            OptionInputRow(opt: opt, placeholder: opt.argLabel ?? "value", keyboard: .default, vm: vm)
        }
    }

    @ViewBuilder
    private func flagLabel(_ opt: OptionDef) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(opt.displayFlag).hackerText().font(.system(.subheadline, design: .monospaced))
            Text(opt.description).font(.caption).foregroundStyle(.secondary)
        }
    }

}

// Separate View struct so @State can track the TextField's string independently.
// A plain Binding(get:set:) in a @ViewBuilder function doesn't reliably push
// external binding changes into SwiftUI's TextField display buffer when the field
// has never been focused — @State + onChange fixes that.
struct OptionInputRow: View {
    let opt: OptionDef
    let placeholder: String
    let keyboard: UIKeyboardType
    @ObservedObject var vm: CommandBuilderViewModel

    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(opt.displayFlag).hackerText().font(.system(.subheadline, design: .monospaced))
                if let label = opt.argLabel {
                    Text("<\(label)>")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Text(opt.description).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .padding(8)
                .background(Color.black.opacity(0.3).cornerRadius(8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.glassBorder, lineWidth: 1))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(keyboard)
                .font(.system(.body, design: .monospaced))
                // User typed in this field → push to VM
                .onChange(of: text) { _, new in
                    vm.strings[opt.id] = new.isEmpty ? nil : new
                    vm.syncToText()
                }
                // Command text changed externally (syncFromText) → pull into field
                .onChange(of: vm.strings[opt.id]) { _, new in
                    let incoming = new ?? ""
                    if incoming != text { text = incoming }
                }
        }
        .padding(.vertical, 2)
        .onAppear { text = vm.strings[opt.id] ?? "" }
    }
}

// MARK: - File picker option row

struct OptionFileRow: View {
    let opt: OptionDef
    @ObservedObject var vm: CommandBuilderViewModel

    @State private var text: String = ""
    @State private var showPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(opt.displayFlag).hackerText().font(.system(.subheadline, design: .monospaced))
                if let label = opt.argLabel {
                    Text("<\(label)>")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Text(opt.description).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("filename", text: $text)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .background(Color.black.opacity(0.3).cornerRadius(8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.glassBorder, lineWidth: 1))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: text) { _, new in
                        vm.strings[opt.id] = new.isEmpty ? nil : new
                        vm.syncToText()
                    }
                    .onChange(of: vm.strings[opt.id]) { _, new in
                        let incoming = new ?? ""
                        if incoming != text { text = incoming }
                    }
                Button { showPicker = true } label: {
                    Image(systemName: "folder")
                        .foregroundStyle(.hackerGreen)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 2)
        .onAppear { text = vm.strings[opt.id] ?? "" }
        .sheet(isPresented: $showPicker) {
            PM3FilePicker { selected in
                text = selected
                vm.strings[opt.id] = selected
                vm.syncToText()
            }
        }
    }
}

struct PM3FilePicker: View {
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var files: [FileEntry] = []
    @State private var search = ""

    struct FileEntry: Identifiable {
        let id = UUID()
        let baseName: String   // what pm3 expects (no extension)
        let fullName: String   // display
        let ext: String
    }

    private var filtered: [FileEntry] {
        search.isEmpty ? files : files.filter {
            $0.baseName.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { entry in
                Button {
                    onSelect(entry.baseName)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: icon(for: entry.ext))
                            .foregroundStyle(.hackerGreen)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.baseName)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.primary)
                            Text(".\(entry.ext)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .hackerBackground()
            .searchable(text: $search, prompt: "Filter files")
            .navigationTitle("Select File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if files.isEmpty {
                    ContentUnavailableView("No Files", systemImage: "folder",
                        description: Text("Run a dump command first to create files."))
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .task { loadFiles() }
        }
        .preferredColorScheme(.dark)
    }

    private func loadFiles() {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: PM3HomeSetup.documentsPath)
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }

        files = items
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { url in
                let ext = url.pathExtension.lowercased()
                let base = url.deletingPathExtension().lastPathComponent
                return FileEntry(baseName: base, fullName: url.lastPathComponent, ext: ext)
            }
            .sorted { $0.baseName < $1.baseName }
    }

    private func icon(for ext: String) -> String {
        switch ext {
        case "bin":  return "doc.fill"
        case "json": return "curlybraces"
        case "eml":  return "doc.plaintext"
        case "dic", "key": return "key.fill"
        case "txt":  return "doc.text"
        default:     return "doc"
        }
    }
}
