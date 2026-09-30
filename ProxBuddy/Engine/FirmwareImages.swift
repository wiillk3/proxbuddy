import Foundation

enum FirmwareImages {
    private static let elfMagic: [UInt8] = [0x7F, 0x45, 0x4C, 0x46]

    enum StageError: Error, Equatable, LocalizedError {
        case empty
        case unreadable(String)
        case notELF(String)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "No firmware files selected"
            case .unreadable(let name):
                return "Could not read \(name)"
            case .notELF(let name):
                return "\(name) is not an ELF. Flash needs fullimage.elf / bootrom.elf from the pm3 build — a .bin dump will not work."
            }
        }
    }

    /// Copy user-picked ELFs into Documents/pm3/firmware/ so `pm3_flash` can read them.
    static func stage(_ urls: [URL]) throws -> [URL] {
        guard !urls.isEmpty else { throw StageError.empty }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("pm3/firmware", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var staged: [URL] = []
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw StageError.unreadable(url.lastPathComponent)
            }
            guard Self.isELF(data) else {
                throw StageError.notELF(url.lastPathComponent)
            }

            var name = url.lastPathComponent
            if (name as NSString).pathExtension.lowercased() != "elf" {
                name += ".elf"
            }
            let dest = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dest.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: dest)
            }
            try data.write(to: dest, options: .atomic)
            staged.append(dest)
        }
        return staged
    }

    static func looksLikeBootrom(_ url: URL) -> Bool {
        url.lastPathComponent.localizedCaseInsensitiveContains("bootrom")
    }

    static func isELF(_ data: Data) -> Bool {
        data.count >= elfMagic.count && data.starts(with: elfMagic)
    }
}
