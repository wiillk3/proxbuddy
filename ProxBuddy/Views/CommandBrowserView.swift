import SwiftUI

// MARK: - Navigation destination type

enum BrowserDestination: Hashable {
    case page(String)       // drill into subcommand group
    case builder(String)    // open command builder for a leaf command
    case scripts            // lua script browser
}

// MARK: - ViewModel

@MainActor
final class BrowserViewModel: ObservableObject {
    @Published var pageCache: [String: CommandPage] = [:]
    @Published var loading: Set<String> = []

    var engine: TerminalEngine?

    func loadPage(for path: String) async {
        guard let engine, pageCache[path] == nil, !loading.contains(path) else { return }
        loading.insert(path)
        let command = path.isEmpty ? "help" : path
        let lines = await engine.captureOutputSilent(command)
        let page = CommandListParser.parse(lines)
        pageCache[path] = page
        loading.remove(path)
    }

    func invalidate(_ path: String) {
        pageCache.removeValue(forKey: path)
    }
}

// MARK: - Root view

struct CommandBrowserView: View {
    @EnvironmentObject var engine: TerminalEngine
    @EnvironmentObject var appNav: AppNavigation
    @EnvironmentObject var favorites: FavoritesStore
    @StateObject private var vm = BrowserViewModel()

    var body: some View {
        NavigationStack(path: $appNav.browserPath) {
            CommandPageView(commandPath: "", vm: vm, favorites: favorites)
                .navigationTitle("Commands")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        NavigationLink(value: BrowserDestination.scripts) {
                            Label("Scripts", systemImage: "scroll")
                        }
                    }
                    refreshButton(for: "")
                }
                .navigationDestination(for: BrowserDestination.self) { dest in
                    switch dest {
                    case .page(let path):
                        CommandPageView(commandPath: path, vm: vm, favorites: favorites)
                            .navigationTitle(path.components(separatedBy: " ").last ?? path)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { refreshButton(for: path) }

                    case .builder(let cmd):
                        CommandBuilderView(engine: engine, initialCommand: cmd)

                    case .scripts:
                        ScriptBrowserView()
                            .navigationTitle("Scripts")
                            .navigationBarTitleDisplayMode(.large)
                    }
                }
        }
        .onAppear {
            if vm.engine == nil { vm.engine = engine }
            Task { await vm.loadPage(for: "") }
        }
    }

    private func refreshButton(for path: String) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                vm.invalidate(path)
                Task { await vm.loadPage(for: path) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
    }
}

// MARK: - One level of the hierarchy

struct CommandPageView: View {
    let commandPath: String
    @ObservedObject var vm: BrowserViewModel
    @ObservedObject var favorites: FavoritesStore

    var body: some View {
        Group {
            if vm.loading.contains(commandPath) {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading \(commandPath.isEmpty ? "commands" : commandPath)…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else if let page = vm.pageCache[commandPath], !page.isEmpty {
                pageList(page)

            } else if vm.pageCache[commandPath] != nil {
                ContentUnavailableView {
                    Label("No commands found", systemImage: "questionmark.circle")
                } description: {
                    Text(commandPath.isEmpty
                         ? "pm3 may not be connected yet. Pull down to retry."
                         : "\"\(commandPath)\" has no subcommands.")
                } actions: {
                    Button("Retry") {
                        vm.invalidate(commandPath)
                        Task { await vm.loadPage(for: commandPath) }
                    }
                    .buttonStyle(.bordered)
                }

            } else {
                Color.clear
            }
        }
        .onAppear { Task { await vm.loadPage(for: commandPath) } }
    }

    private func pageList(_ page: CommandPage) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                // Favorites strip
                if commandPath.isEmpty && !favorites.favorites.isEmpty {
                    VStack(alignment: .leading) {
                        Text("Favorites").hackerText().font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(favorites.favorites) { fav in
                                    FavoriteChip(fav: fav, favorites: favorites)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.horizontal)
                }

                ForEach(page.sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        if !section.name.isEmpty {
                            Text(section.name.uppercased())
                                .hackerText()
                                .font(.subheadline)
                                .opacity(0.8)
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(section.entries.enumerated()), id: \.element.id) { idx, entry in
                                entryRow(entry)
                                if idx < section.entries.count - 1 {
                                    Divider().background(Color.glassBorder)
                                        .padding(.leading, 46)
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

    @ViewBuilder
    private func entryRow(_ entry: CommandEntry) -> some View {
        let fullPath = commandPath.isEmpty ? entry.name : "\(commandPath) \(entry.name)"
        let dest: BrowserDestination = entry.isGroup ? .page(fullPath) : .builder(fullPath)

        NavigationLink(value: dest) {
            HStack(spacing: 12) {
                Image(systemName: entry.isGroup ? "folder.fill" : "terminal.fill")
                    .foregroundStyle(.hackerGreen)
                    .frame(width: 22, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .hackerText()
                        .fontWeight(.medium)
                    Text(entry.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Favorite chip

struct FavoriteChip: View {
    let fav: FavoriteCommand
    @ObservedObject var favorites: FavoritesStore
    @EnvironmentObject var engine: TerminalEngine
    @EnvironmentObject var appNav: AppNavigation
    @State private var pressed = false

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: "star.fill")
                .font(.system(size: 11))
            Text(fav.label)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(pressed ? Color.hackerGreen.opacity(0.25) : Color.clear)
        .foregroundStyle(.hackerGreen)
        .liquidGlassCard()
        .scaleEffect(pressed ? 0.95 : 1)
        .animation(.easeInOut(duration: 0.08), value: pressed)
        .onTapGesture {
            pressed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { pressed = false }
            engine.sendCommand(fav.command)
            appNav.selectedTab = AppNavigation.terminalTab
        }
        .contextMenu {
            Button {
                appNav.browserPath = [.builder(fav.command)]
            } label: {
                Label("Open in Builder", systemImage: "wrench.and.screwdriver")
            }
            Divider()
            Button(role: .destructive) {
                favorites.remove(fav)
            } label: {
                Label("Remove Favorite", systemImage: "star.slash")
            }
        }
    }
}

// MARK: - Script browser

struct ScriptBrowserView: View {
    struct ScriptEntry: Identifiable {
        let id   = UUID()
        let name: String        // without extension — used as the run argument
        let ext:  String        // "lua", "py", "cmd"
        let url:  URL

        var displayName: String { name }

        var icon: String {
            switch ext {
            case "py":  return "chevron.left.forwardslash.chevron.right"
            case "cmd": return "terminal.fill"
            default:    return "scroll.fill"
            }
        }
        var color: Color {
            switch ext {
            case "py":  return .blue
            case "cmd": return .orange
            default:    return .purple
            }
        }
        // pm3 "script run" argument — lua uses bare name, others need extension
        var runArg: String {
            ext == "lua" ? name : "\(name).\(ext)"
        }
    }

    @State private var scripts: [ScriptEntry] = []
    @State private var isLoading      = false
    @State private var showImporter   = false
    @State private var importMessage: String?
    @State private var importFailed   = false

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading scripts…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if let msg = importMessage {
                            Label(msg, systemImage: importFailed ? "xmark.circle" : "checkmark.circle")
                                .foregroundStyle(importFailed ? .red : .hackerGreen)
                                .font(.caption)
                                .liquidGlassCard()
                                .padding(.horizontal)
                        }

                        let grouped = Dictionary(grouping: scripts, by: \.ext)
                        let order = ["lua", "py", "cmd"]
                        ForEach(order, id: \.self) { ext in
                            if let group = grouped[ext], !group.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(sectionTitle(ext).uppercased())
                                        .hackerText()
                                        .font(.subheadline)
                                        .opacity(0.8)
                                    VStack(spacing: 0) {
                                        ForEach(Array(group.enumerated()), id: \.element.id) { idx, script in
                                            NavigationLink(value: BrowserDestination.builder("script run \(script.runArg)")) {
                                                scriptRow(script)
                                            }
                                            .buttonStyle(.plain)
                                            .contextMenu {
                                                Button(role: .destructive) { deleteScript(script) } label: {
                                                    Label("Delete", systemImage: "trash")
                                                }
                                            }
                                            if idx < group.count - 1 {
                                                Divider().background(Color.glassBorder)
                                                    .padding(.leading, 46)
                                            }
                                        }
                                    }
                                    .liquidGlassCard()
                                }
                                .padding(.horizontal)
                            }
                        }

                        if scripts.isEmpty {
                            ContentUnavailableView(
                                "No Scripts Found",
                                systemImage: "scroll.fill",
                                description: Text("Scripts should be automatically bundled during compilation. If you don't see any, rebuild the app.")
                            )
                        }
                    }
                    .padding(.vertical)
                }
                .hackerBackground()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showImporter = true } label: {
                    Label("Import Script", systemImage: "square.and.arrow.down")
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.data, .text],
            allowsMultipleSelection: true
        ) { result in
            Task { await handleImport(result: result) }
        }
        .task { await loadScripts() }
        .refreshable { await loadScripts() }
    }

    // MARK: - Row

    private func scriptRow(_ script: ScriptEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: script.icon)
                .foregroundStyle(.hackerGreen)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(script.displayName)
                        .hackerText()
                        .fontWeight(.medium)
                    Text(".\(script.ext)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private func sectionTitle(_ ext: String) -> String {
        switch ext {
        case "lua": return "Lua Scripts"
        case "py":  return "Python Scripts"
        case "cmd": return "Cmd Scripts"
        default:    return ext.uppercased()
        }
    }

    // MARK: - Import

    private func handleImport(result: Result<[URL], Error>) async {
        importMessage = nil
        do {
            let urls = try result.get()
            var installed = 0
            for url in urls {
                let ext = url.pathExtension.lowercased()
                guard ["lua", "cmd"].contains(ext) else {
                    importFailed = true
                    importMessage = "Unsupported type .\(ext) — use .lua or .cmd"
                    return
                }
                performInstall(url: url)
                installed += 1
            }
            if installed > 0 {
                importFailed = false
                importMessage = "Installed \(installed) script\(installed == 1 ? "" : "s")"
                await loadScripts()
            }
        } catch {
            importFailed = true
            importMessage = error.localizedDescription
        }
    }

    private func performInstall(url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let ext    = url.pathExtension.lowercased()
        let subdir: String
        switch ext {
        case "py":  subdir = "pyscripts"
        case "cmd": subdir = "cmdscripts"
        default:    subdir = "luascripts"
        }
        let destDir = URL(fileURLWithPath: PM3HomeSetup.documentsPath)
            .appendingPathComponent(subdir)
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
    }

    private func deleteScript(_ script: ScriptEntry) {
        try? FileManager.default.removeItem(at: script.url)
        scripts.removeAll { $0.id == script.id }
    }

    // MARK: - Load

    private func loadScripts() async {
        isLoading = true
        scripts = await Task.detached(priority: .userInitiated) {
            let bases = [Bundle.main.resourcePath ?? "", PM3HomeSetup.documentsPath]
            let fm   = FileManager.default
            var entries: [ScriptEntry] = []
            var seen = Set<String>()
            let scriptDirs: [(subdir: String, ext: String)] = [
                ("luascripts", "lua"), ("pyscripts", "py"), ("cmdscripts", "cmd"),
            ]
            for base in bases {
                guard !base.isEmpty else { continue }
                for (subdir, ext) in scriptDirs {
                    let dir  = URL(fileURLWithPath: "\(base)/\(subdir)")
                    guard let files = try? fm.contentsOfDirectory(
                        at: dir, includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                    ) else { continue }
                    for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                        where url.pathExtension.lowercased() == ext {
                        let name = url.deletingPathExtension().lastPathComponent
                        let uniqueKey = "\(ext):\(name)"
                        if !seen.contains(uniqueKey) {
                            seen.insert(uniqueKey)
                            entries.append(ScriptEntry(name: name, ext: ext, url: url))
                        }
                    }
                }
            }
            return entries
        }.value
        isLoading = false
    }
}
