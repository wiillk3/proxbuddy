import Foundation
import Testing
@testable import ProxBuddy

struct FirmwareImagesTests {
    @Test func bootromNameDetection() {
        #expect(FirmwareImages.looksLikeBootrom(URL(fileURLWithPath: "/tmp/bootrom.elf")))
        #expect(FirmwareImages.looksLikeBootrom(URL(fileURLWithPath: "/tmp/BootRom.ELF")))
        #expect(!FirmwareImages.looksLikeBootrom(URL(fileURLWithPath: "/tmp/fullimage.elf")))
    }

    @Test func elfMagic() {
        #expect(FirmwareImages.isELF(Data([0x7F, 0x45, 0x4C, 0x46, 0x01])))
        #expect(!FirmwareImages.isELF(Data([0x00, 0x01, 0x02, 0x03])))
        #expect(!FirmwareImages.isELF(Data()))
    }

    @Test func stageRejectsNonELF() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let bin = dir.appendingPathComponent("fullimage.bin")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: bin)

        #expect(throws: FirmwareImages.StageError.notELF("fullimage.bin")) {
            try FirmwareImages.stage([bin])
        }
    }

    @Test func stageCopiesELFAndAddsExtension() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let src = dir.appendingPathComponent("fullimage.bin")
        var payload = Data([0x7F, 0x45, 0x4C, 0x46])
        payload.append(contentsOf: [0x01, 0x01, 0x01, 0x00])
        try payload.write(to: src)

        let staged = try FirmwareImages.stage([src])
        #expect(staged.count == 1)
        #expect(staged[0].lastPathComponent == "fullimage.bin.elf")
        #expect(FileManager.default.fileExists(atPath: staged[0].path(percentEncoded: false)))
        try? FileManager.default.removeItem(at: staged[0])
    }
}
