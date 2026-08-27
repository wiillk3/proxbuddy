import SwiftUI
import Observation
import UIKit
import os

private let builderSignposter = OSSignposter(subsystem: "rfid.spot.proxbuddy", category: "CommandBuilder")

/// Per-option state as its own observable, so flipping one toggle doesn't
/// invalidate every other row (a `[UUID: Bool]` on the VM would).
@Observable
@MainActor
final class OptionValue {
    var isOn = false
    var text = ""
}

@Observable
@MainActor
final class CommandBuilderViewModel {
    var baseCommand: String
    var commandHelp: CommandHelp?
    var isLoading = false
    var error: String?
    var commandText: String
    var isSendable = false
    var isStarred = false

    let engine: TerminalEngine
    @ObservationIgnored weak var favorites: FavoritesStore?

    @ObservationIgnored private var values: [UUID: OptionValue] = [:]
    @ObservationIgnored private var suppressParse = false

    init(engine: TerminalEngine, initialCommand: String = "") {
        self.engine = engine
        self.baseCommand = initialCommand
        self.commandText = initialCommand
        self.isSendable = !initialCommand.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func value(for id: UUID) -> OptionValue {
        if let existing = values[id] { return existing }
        let created = OptionValue()
        values[id] = created
        return created
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
            values.removeAll()
            commandHelp = help
            commandText = priorText.hasPrefix(cmd) ? priorText : cmd
            updateDerived()
            syncFromText()
        }
        isLoading = false
    }

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

    func handleExternalCommandEdit() {
        if suppressParse {
            suppressParse = false
            return
        }
        syncFromText()
    }

    func updateDerived() {
        let trimmed = commandText.trimmingCharacters(in: .whitespaces)
        let sendable = !trimmed.isEmpty
        if isSendable != sendable { isSendable = sendable }
        let starred = favorites?.isFavorited(command: trimmed) ?? false
        if isStarred != starred { isStarred = starred }
    }

    func syncToText() {
        let state = builderSignposter.beginInterval("syncToText")
        defer { builderSignposter.endInterval("syncToText", state) }
        var parts = [baseCommand.trimmingCharacters(in: .whitespaces)]
        guard let help = commandHelp else {
            applyCommandText(parts[0])
            return
        }
        for opt in help.options where !isHelpFlag(opt) {
            let val = value(for: opt.id)
            if opt.argType == .none {
                if val.isOn { parts.append(opt.primaryFlag) }
            } else if !val.text.isEmpty {
                if opt.isShortOnly && opt.primaryFlag.hasPrefix("<") {
                    parts.append(val.text)
                } else {
                    parts.append(contentsOf: [opt.primaryFlag, val.text])
                }
            }
        }
        applyCommandText(parts.joined(separator: " "))
    }

    private func applyCommandText(_ new: String) {
        guard new != commandText else { return }
        suppressParse = true
        commandText = new
        updateDerived()
    }

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

        var onFlags: Set<UUID> = []
        var texts: [UUID: String] = [:]
        var i = 0
        while i < flagTokens.count {
            let token = flagTokens[i]
            if let opt = help.options.first(where: { $0.flags.contains(token) }) {
                if opt.argType == .none {
                    onFlags.insert(opt.id); i += 1
                } else if i + 1 < flagTokens.count {
                    texts[opt.id] = flagTokens[i + 1]; i += 2
                } else { i += 1 }
            } else { i += 1 }
        }

        for opt in help.options {
            let val = value(for: opt.id)
            let nextOn = onFlags.contains(opt.id)
            if val.isOn != nextOn { val.isOn = nextOn }
            let nextText = texts[opt.id] ?? ""
            if val.text != nextText { val.text = nextText }
        }
    }

    func sendBuilt() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        syncToText()
        engine.sendCommand(commandText)
    }

    func isHelpFlag(_ opt: OptionDef) -> Bool {
        opt.flags.allSatisfy { $0 == "-h" || $0 == "--help" }
    }

    func reloadBase(from commandText: String) {
        let tokens = commandText
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        let base = tokens.prefix(while: { !$0.hasPrefix("-") }).joined(separator: " ")
        baseCommand = base.isEmpty ? commandText : base
        Task { await loadHelp() }
    }
}

// MARK: - Root (must not read commandText / option values)

struct CommandBuilderView: View {
    @State private var vm: CommandBuilderViewModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appNav: AppNavigation
    @EnvironmentObject private var favorites: FavoritesStore
    @AppStorage("builderAutoSwitch") private var autoSwitch = true

    init(engine: TerminalEngine, initialCommand: String = "") {
        _vm = State(wrappedValue: CommandBuilderViewModel(engine: engine, initialCommand: initialCommand))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                BuilderCommandField(vm: vm)
                BuilderStatus(vm: vm)
                BuilderHelpAndOptions(vm: vm)
            }
            .padding()
        }
        .background(Color.black)
        .navigationTitle(vm.baseCommand.isEmpty ? "Command Builder" : vm.baseCommand)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            BuilderToolbar(vm: vm, autoSwitch: autoSwitch)
        }
        .onAppear {
            vm.favorites = favorites
            vm.updateDerived()
            if vm.commandHelp == nil, !vm.isLoading {
                vm.reloadBase(from: vm.commandText)
            }
        }
    }
}

private struct BuilderToolbar: ToolbarContent {
    @Bindable var vm: CommandBuilderViewModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appNav: AppNavigation
    @EnvironmentObject private var favorites: FavoritesStore
    let autoSwitch: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                let cmd = vm.commandText.trimmingCharacters(in: .whitespaces)
                if vm.isStarred {
                    if let fav = favorites.favorites.first(where: { $0.command == cmd }) {
                        favorites.remove(fav)
                    }
                } else {
                    let label = vm.baseCommand.isEmpty ? cmd : vm.baseCommand
                    favorites.add(command: cmd, label: label)
                }
                vm.updateDerived()
            } label: {
                Image(systemName: vm.isStarred ? "star.fill" : "star")
                    .foregroundStyle(vm.isStarred ? .yellow : .secondary)
            }
            .disabled(!vm.isSendable)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Send") {
                vm.sendBuilt()
                dismiss()
                if autoSwitch { appNav.selectedTab = AppNavigation.terminalTab }
            }
            .disabled(vm.isLoading || !vm.isSendable)
        }
    }
}

private struct BuilderCommandField: View {
    @Bindable var vm: CommandBuilderViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("COMMAND").hackerText().font(.subheadline).opacity(0.8)
            FastTextField(
                text: $vm.commandText,
                placeholder: "e.g. hf mf autopwn --1k",
                keyboard: .asciiCapable,
                onSubmit: { vm.reloadBase(from: vm.commandText) }
            )
            .frame(height: 36)
            .padding(8)
            .builderPanel()
        }
        .onChange(of: vm.commandText) { _, _ in
            vm.handleExternalCommandEdit()
        }
    }
}

private struct BuilderStatus: View {
    var vm: CommandBuilderViewModel

    var body: some View {
        if vm.isLoading {
            HStack { Spacer(); ProgressView("Loading options…"); Spacer() }
                .builderPanel()
        }
        if let err = vm.error {
            Label(err, systemImage: "xmark.circle").foregroundStyle(.red)
                .builderPanel()
        }
    }
}

private struct BuilderHelpAndOptions: View {
    var vm: CommandBuilderViewModel

    var body: some View {
        if let help = vm.commandHelp {
            if !help.summary.isEmpty {
                labeledBlock("ABOUT", help.summary)
            }
            if !help.usage.isEmpty {
                labeledBlock("USAGE", help.usage)
            }

            let opts = help.options.filter { !vm.isHelpFlag($0) }
            if opts.isEmpty {
                Label("No configurable options — ready to send.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .builderPanel()
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("OPTIONS").hackerText().font(.subheadline).opacity(0.8)
                    VStack(spacing: 0) {
                        ForEach(opts) { opt in
                            BuilderOptionRow(opt: opt, vm: vm)
                        }
                    }
                    .builderPanel()
                }
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
                    .builderPanel()
                }
            }
        }
    }

    private func labeledBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).hackerText().font(.subheadline).opacity(0.8)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .builderPanel()
        }
    }
}

private struct BuilderOptionRow: View {
    let opt: OptionDef
    var vm: CommandBuilderViewModel

    var body: some View {
        Group {
            switch opt.argType {
            case .none:
                OptionToggleRow(opt: opt, value: vm.value(for: opt.id), vm: vm)
            case .file:
                OptionFileRow(opt: opt, value: vm.value(for: opt.id), vm: vm)
            default:
                OptionInputRow(opt: opt, value: vm.value(for: opt.id), vm: vm)
            }
        }
        Divider().background(Color.glassBorder)
    }
}

private struct OptionToggleRow: View {
    let opt: OptionDef
    @Bindable var value: OptionValue
    var vm: CommandBuilderViewModel

    var body: some View {
        Toggle(isOn: $value.isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(opt.displayFlag).hackerText().font(.system(.subheadline, design: .monospaced))
                Text(opt.description).font(.caption).foregroundStyle(.secondary)
            }
        }
        .tint(.hackerGreen)
        .padding(.vertical, 4)
        .onChange(of: value.isOn) { _, _ in
            vm.syncToText()
        }
    }
}

private struct OptionInputRow: View {
    let opt: OptionDef
    @Bindable var value: OptionValue
    var vm: CommandBuilderViewModel

    private var placeholder: String {
        switch opt.argType {
        case .hex:     return "hex bytes e.g. AABBCCDD"
        case .decimal: return "number"
        case .binary:  return "binary string e.g. 0001101"
        default:       return opt.argLabel ?? "value"
        }
    }

    private var keyboard: UIKeyboardType {
        opt.argType == .decimal ? .numberPad : .asciiCapable
    }

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
            FastTextField(
                text: $value.text,
                placeholder: placeholder,
                keyboard: keyboard,
                onSubmit: { vm.syncToText() }
            )
            .frame(height: 32)
            .padding(8)
            .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.glassBorder, lineWidth: 1))
        }
        .padding(.vertical, 6)
        .onChange(of: value.text) { _, _ in
            vm.syncToText()
        }
    }
}

private struct OptionFileRow: View {
    let opt: OptionDef
    @Bindable var value: OptionValue
    var vm: CommandBuilderViewModel
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
                FastTextField(
                    text: $value.text,
                    placeholder: "filename",
                    keyboard: .asciiCapable,
                    onSubmit: { vm.syncToText() }
                )
                .frame(height: 32)
                .padding(8)
                .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.glassBorder, lineWidth: 1))
                Button { showPicker = true } label: {
                    Image(systemName: "folder")
                        .foregroundStyle(.hackerGreen)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 6)
        .onChange(of: value.text) { _, _ in
            vm.syncToText()
        }
        .sheet(isPresented: $showPicker) {
            PM3FilePicker { selected in
                value.text = selected
                vm.syncToText()
            }
        }
    }
}

// MARK: - UIKit field (SwiftUI TextField round-trips through the view graph)

private struct FastTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var keyboard: UIKeyboardType
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        field.textColor = UIColor(red: 0, green: 1, blue: 0.25, alpha: 1)
        field.tintColor = field.textColor
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
        field.keyboardType = keyboard
        field.returnKeyType = .done
        field.clearButtonMode = .whileEditing
        field.text = text
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        if field.placeholder != placeholder { field.placeholder = placeholder }
        if field.keyboardType != keyboard { field.keyboardType = keyboard }
        if field.text != text, !field.isFirstResponder {
            field.text = text
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String> = .constant("")
        var onSubmit: () -> Void = {}
        private var latest = ""
        private var debounceWork: DispatchWorkItem?

        @objc func editingChanged(_ sender: UITextField) {
            latest = sender.text ?? ""
            debounceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if self.text.wrappedValue != self.latest {
                    self.text.wrappedValue = self.latest
                }
            }
            debounceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }

        func flush(_ field: UITextField) {
            debounceWork?.cancel()
            debounceWork = nil
            latest = field.text ?? ""
            if text.wrappedValue != latest {
                text.wrappedValue = latest
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            flush(textField)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            flush(textField)
            textField.resignFirstResponder()
            onSubmit()
            return true
        }
    }
}

private extension View {
    func builderPanel() -> some View {
        self
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.45)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.glassBorder, lineWidth: 1))
    }
}

struct PM3FilePicker: View {
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var files: [FileEntry] = []
    @State private var search = ""

    struct FileEntry: Identifiable {
        let id = UUID()
        let baseName: String
        let fullName: String
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
