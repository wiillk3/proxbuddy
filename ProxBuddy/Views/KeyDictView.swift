import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Model

struct KeyFile: Identifiable {
    let id      = UUID()
    let url:     URL
    let modDate: Date
    let size:    Int64

    var name:     String { url.lastPathComponent }
    var baseName: String { url.deletingPathExtension().lastPathComponent }
    var ext:      String { url.pathExtension.lowercased() }
    var isDict:   Bool { ext == "dic" || ext == "txt" }
    var isBinary: Bool { ext == "key" }

    var keyCount: Int {
        guard isDict, let txt = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return txt.components(separatedBy: .newlines)
            .compactMap { KeyFile.extractKey(from: $0) }
            .count
    }

    // Binary .key file: 6 bytes key A + 6 bytes key B per sector
    var sectorCount: Int {
        guard isBinary else { return 0 }
        guard let data = try? Data(contentsOf: url) else { return 0 }
        return data.count / 12
    }

    /// Extract a valid hex key from a single .dic line.
    /// Handles:
    ///   - Comment lines (#, //)
    ///   - Inline trailing comments  (FFFFFFFFFFFF # transport key)
    ///   - Colon-separated bytes     (FF:FF:FF:FF:FF:FF)
    ///   - 0x prefix                 (0xFFFFFFFFFFFF)
    ///   - Variable key sizes: 4–48 hex chars (even length) covering
    ///     T55xx 4-byte, MFC 6-byte, DES 8-byte, AES 16-byte, 3DES 24-byte keys
    static func extractKey(from rawLine: String) -> String? {
        let line = rawLine.trimmingCharacters(in: .whitespaces).uppercased()
        guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("//") else { return nil }
        // Take first token (before whitespace or inline #)
        var token = line.components(separatedBy: CharacterSet(charactersIn: " \t#")).first ?? ""
        // Strip 0x prefix
        if token.hasPrefix("0X") { token = String(token.dropFirst(2)) }
        // Strip colons (FF:FF:FF... format)
        token = token.replacingOccurrences(of: ":", with: "")
        // Even-length hex string, 4–48 chars (2–24 bytes)
        guard token.count >= 4, token.count <= 48,
              token.count.isMultiple(of: 2),
              token.allSatisfy(\.isHexDigit) else { return nil }
        return token
    }
}

// MARK: - ViewModel

@MainActor
final class KeyDictViewModel: ObservableObject {
    @Published var files: [KeyFile] = []

    private var pm3Dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pm3")
    }

    func refresh() {
        let fm  = FileManager.default
        let exts: Set<String> = ["dic", "key", "txt"]
        var urls: [URL] = []

        for dir in [pm3Dir, pm3Dir.appendingPathComponent("dictionaries")] {
            guard let items = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else { continue }
            urls += items.filter { exts.contains($0.pathExtension.lowercased()) }
        }

        files = urls.compactMap { url -> KeyFile? in
            let r = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return KeyFile(url: url, modDate: r?.contentModificationDate ?? .now,
                           size: Int64(r?.fileSize ?? 0))
        }
        .sorted { $0.modDate > $1.modDate }
    }

    func delete(_ file: KeyFile) {
        try? FileManager.default.removeItem(at: file.url)
        refresh()
    }

    func importFile(from src: URL) throws {
        let accessing = src.startAccessingSecurityScopedResource()
        defer { if accessing { src.stopAccessingSecurityScopedResource() } }
        let dest = pm3Dir.appendingPathComponent(src.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: src, to: dest)
        refresh()
    }

    func createDict(name: String, rawText: String) {
        let cleaned = rawText.components(separatedBy: .newlines)
            .compactMap { KeyFile.extractKey(from: $0) }
            .removingDuplicates()
        guard !cleaned.isEmpty else { return }
        let safeName = name.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "_")
        let fname = safeName.hasSuffix(".dic") ? safeName : safeName + ".dic"
        let url = pm3Dir.appendingPathComponent(fname)
        try? cleaned.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        refresh()
    }

    func saveKeys(_ keys: [String], to file: KeyFile) {
        try? keys.joined(separator: "\n").write(to: file.url, atomically: true, encoding: .utf8)
        refresh()
    }
}

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - Root list

struct KeyDictManagerView: View {
    @StateObject private var vm = KeyDictViewModel()
    @State private var showImporter   = false
    @State private var showNewDict    = false
    @State private var importError: String?

    private var dicts:    [KeyFile] { vm.files.filter(\.isDict)   }
    private var binaries: [KeyFile] { vm.files.filter(\.isBinary) }

    var body: some View {
        List {
            Section {
                ForEach(dicts) { f in
                    NavigationLink { DictDetailView(file: f, vm: vm) } label: { dictRow(f) }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { vm.delete(f) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            ShareLink(item: f.url) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .tint(.blue)
                        }
                }
                Button { showNewDict = true } label: {
                    Label("New Dictionary…", systemImage: "plus").foregroundStyle(.green)
                }
            } header: {
                Text("Dictionaries")
            } footer: {
                if dicts.isEmpty {
                    Text("Import .dic files or create a custom key list here. Used with hf mf chk, autopwn, etc.")
                }
            }

            if !binaries.isEmpty {
                Section("Key Files (.key)") {
                    ForEach(binaries) { f in
                        NavigationLink { BinaryKeyDetailView(file: f, vm: vm) } label: { binRow(f) }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { vm.delete(f) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                ShareLink(item: f.url) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                .tint(.blue)
                            }
                    }
                }
            }

            if let err = importError {
                Section {
                    Label(err, systemImage: "xmark.circle").foregroundStyle(.red).font(.caption)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Keys & Dicts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showImporter = true } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .text]) { result in
            importError = nil
            do {
                let url = try result.get()
                try vm.importFile(from: url)
            } catch {
                importError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showNewDict, onDismiss: { vm.refresh() }) {
            NewDictSheet { name, text in vm.createDict(name: name, rawText: text) }
        }
        .onAppear { vm.refresh() }
    }

    private func dictRow(_ f: KeyFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.title3).foregroundStyle(.orange)
                .frame(width: 32, height: 32)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(f.name).font(.system(.subheadline, design: .monospaced)).lineLimit(1)
                Text("\(f.keyCount) keys · \(ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func binRow(_ f: KeyFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill")
                .font(.title3).foregroundStyle(.yellow)
                .frame(width: 32, height: 32)
                .background(Color.yellow.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(f.name).font(.system(.subheadline, design: .monospaced)).lineLimit(1)
                Text("\(f.sectorCount) sectors · \(ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Dict detail (text .dic / .txt)

struct DictDetailView: View {
    let file: KeyFile
    @ObservedObject var vm: KeyDictViewModel

    @State private var keys: [String] = []
    @State private var newKey  = ""
    @State private var isDirty = false
    @State private var showAddField = false
    @FocusState private var addFocused: Bool

    private static let knownDefaults: Set<String> = [
        // MFC 6-byte
        "FFFFFFFFFFFF", "000000000000", "A0A1A2A3A4A5",
        "B0B1B2B3B4B5", "D3F7D3F7D3F7", "4B0B20107CCB",
        "AABBCCDDEEFF", "1A2B3C4D5E6F", "714C5C886E97",
        // DES/AES 8/16-byte
        "0000000000000000", "FFFFFFFFFFFFFFFF",
        "00000000000000000000000000000000",
        "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
        // T55xx 4-byte
        "00000000", "51243648",
    ]

    var body: some View {
        List {
            Section {
                Text("\(keys.count) unique keys")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Keys") {
                ForEach(keys, id: \.self) { key in
                    HStack(spacing: 8) {
                        Text(key)
                            .font(.system(key.count > 12 ? .caption : .body, design: .monospaced))
                            .foregroundStyle(Self.knownDefaults.contains(key) ? .orange : .green)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Spacer()
                        Text("\(key.count/2)B")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button {
                            UIPasteboard.general.string = key
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            keys.removeAll { $0 == key }
                            isDirty = true
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }

                if showAddField {
                    HStack {
                        TextField("AABBCCDDEEFF", text: $newKey)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                            .focused($addFocused)
                            .onChange(of: newKey) { _, v in
                                newKey = String(v.uppercased().filter(\.isHexDigit).prefix(48))
                            }
                        Button("Add") {
                            guard let k = KeyFile.extractKey(from: newKey) else { return }
                            if !keys.contains(k) { keys.append(k); isDirty = true }
                            newKey = ""
                            addFocused = false
                            showAddField = false
                        }
                        .disabled(KeyFile.extractKey(from: newKey) == nil)
                        .foregroundStyle(.green)
                    }
                } else {
                    Button {
                        showAddField = true
                        addFocused = true
                    } label: {
                        Label("Add Key", systemImage: "plus").foregroundStyle(.green)
                    }
                }
            }

            Section {
                legendRow(.orange, "Default / well-known key")
                legendRow(.green,  "Custom / found key")
            } header: { Text("Legend") }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(file.baseName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                ShareLink(item: file.url) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            if isDirty {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        vm.saveKeys(keys, to: file)
                        isDirty = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear { load() }
    }

    private func load() {
        guard let txt = try? String(contentsOf: file.url, encoding: .utf8) else { return }
        keys = txt.components(separatedBy: .newlines)
            .compactMap { KeyFile.extractKey(from: $0) }
            .removingDuplicates()
    }

    private func legendRow(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Binary .key detail

struct BinaryKeyDetailView: View {
    let file: KeyFile
    @ObservedObject var vm: KeyDictViewModel

    @State private var sectors: [(a: String, b: String)] = []

    var body: some View {
        List {
            Section {
                Text("\(sectors.count) sectors")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Sector Keys") {
                // Header
                HStack(spacing: 0) {
                    Text("SEC").frame(width: 40, alignment: .center)
                        .font(.system(.caption2, design: .monospaced)).fontWeight(.bold).foregroundStyle(.secondary)
                    Text("KEY A").frame(maxWidth: .infinity, alignment: .leading)
                        .font(.system(.caption2, design: .monospaced)).fontWeight(.bold).foregroundStyle(.secondary)
                    Text("KEY B").frame(maxWidth: .infinity, alignment: .leading)
                        .font(.system(.caption2, design: .monospaced)).fontWeight(.bold).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .listRowBackground(Color.secondary.opacity(0.12))

                ForEach(Array(sectors.enumerated()), id: \.offset) { i, pair in
                    HStack(spacing: 0) {
                        Text(String(format: "%02d", i))
                            .frame(width: 40, alignment: .center)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(pair.a)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(pair.a == "FFFFFFFFFFFF" ? .orange : .green)
                        Text(pair.b)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(pair.b == "FFFFFFFFFFFF" ? .orange : .green)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(file.baseName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                ShareLink(item: file.url) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .onAppear { load() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: file.url), data.count >= 12 else { return }
        let count = data.count / 12
        sectors = (0..<count).map { i in
            let aOff = i * 6
            let bOff = count * 6 + i * 6
            guard bOff + 6 <= data.count else { return ("??????", "??????") }
            let a = data[aOff..<(aOff+6)].map { String(format: "%02X", $0) }.joined()
            let b = data[bOff..<(bOff+6)].map { String(format: "%02X", $0) }.joined()
            return (a, b)
        }
    }
}

// MARK: - New dict sheet

struct NewDictSheet: View {
    let onCreate: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var rawText = ""

    private var validCount: Int {
        rawText.components(separatedBy: .newlines)
            .compactMap { KeyFile.extractKey(from: $0) }
            .count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("my_custom_keys", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section {
                    TextEditor(text: $rawText)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 180)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                } header: {
                    Text("Keys (one per line, hex)")
                } footer: {
                    Text("\(validCount) valid key\(validCount == 1 ? "" : "s") detected")
                        .foregroundStyle(validCount > 0 ? .green : .secondary)
                }
            }
            .navigationTitle("New Dictionary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(name.isEmpty ? "custom" : name, rawText)
                        dismiss()
                    }
                    .disabled(validCount == 0 || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
