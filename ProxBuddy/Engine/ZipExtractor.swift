import Foundation
import zlib

/// Reliable ZIP extractor that reads the Central Directory for accurate metadata,
/// avoiding the data-descriptor (bit 3) issue in local file headers.
enum ZipExtractor {

    enum ExtractError: Error {
        case readFailed(String)
        case eocdNotFound
        case unsupportedZip(String)
    }

    // MARK: - Public API

    static func extract(zipURL: URL, destinationURL: URL) throws {
        let fileData = try Data(contentsOf: zipURL, options: .mappedIfSafe)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let entries = try parseCentralDirectory(fileData)
        for entry in entries {
            try extractEntry(entry, from: fileData, to: destinationURL)
        }
        NSLog("[ZipExtractor] Extracted \(entries.count) entries to \(destinationURL.path)")
    }

    // MARK: - Central Directory Parsing

    private struct CDEntry {
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        let fileName: String
    }

    private static func parseCentralDirectory(_ data: Data) throws -> [CDEntry] {
        let count = data.count
        guard count >= 22 else { throw ExtractError.eocdNotFound }

        // Find End of Central Directory record (EOCD) by scanning backwards for signature 0x06054b50
        var eocdOffset = count - 22
        let eocdSig: UInt32 = 0x06054b50
        while eocdOffset >= 0 {
            let sig = data.loadU32(at: eocdOffset)
            if sig == eocdSig { break }
            eocdOffset -= 1
        }
        guard eocdOffset >= 0 else { throw ExtractError.eocdNotFound }

        let cdOffset = Int(data.loadU32(at: eocdOffset + 16))
        let cdSize   = Int(data.loadU32(at: eocdOffset + 12))
        let cdCount  = Int(data.loadU16(at: eocdOffset + 10))

        guard cdOffset + cdSize <= count else {
            throw ExtractError.readFailed("Central directory extends past EOF")
        }

        var entries: [CDEntry] = []
        var pos = cdOffset
        for _ in 0..<cdCount {
            guard pos + 46 <= count else { break }
            guard data.loadU32(at: pos) == 0x02014b50 else { break } // CD entry sig

            let method   = data.loadU16(at: pos + 10)
            let compSz   = Int(data.loadU32(at: pos + 20))
            let uncompSz = Int(data.loadU32(at: pos + 24))
            let fnLen    = Int(data.loadU16(at: pos + 28))
            let extraLen = Int(data.loadU16(at: pos + 30))
            let cmtLen   = Int(data.loadU16(at: pos + 32))
            let lhOffset = Int(data.loadU32(at: pos + 42))

            let fnData = data.subdata(in: (pos + 46)..<(pos + 46 + fnLen))
            let fileName = String(data: fnData, encoding: .utf8) ?? ""

            entries.append(CDEntry(
                compressionMethod: method,
                compressedSize: compSz,
                uncompressedSize: uncompSz,
                localHeaderOffset: lhOffset,
                fileName: fileName
            ))

            pos += 46 + fnLen + extraLen + cmtLen
        }
        return entries
    }

    // MARK: - Entry Extraction

    private static func extractEntry(_ entry: CDEntry, from data: Data, to dest: URL) throws {
        let targetURL = dest.appendingPathComponent(entry.fileName)

        if entry.fileName.hasSuffix("/") {
            try? FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
            return
        }

        try? FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Jump to local file header to find actual data offset
        let lhBase = entry.localHeaderOffset
        guard lhBase + 30 <= data.count,
              data.loadU32(at: lhBase) == 0x04034b50 else { return }

        let localFnLen    = Int(data.loadU16(at: lhBase + 26))
        let localExtraLen = Int(data.loadU16(at: lhBase + 28))
        let dataStart     = lhBase + 30 + localFnLen + localExtraLen
        let dataEnd       = dataStart + entry.compressedSize

        guard dataEnd <= data.count else { return }

        switch entry.compressionMethod {
        case 0: // Stored
            let raw = data.subdata(in: dataStart..<dataEnd)
            try? raw.write(to: targetURL)

        case 8: // Deflated
            let compressed = data.subdata(in: dataStart..<dataEnd)
            if let decompressed = inflateRaw(compressed, expectedSize: entry.uncompressedSize) {
                try? decompressed.write(to: targetURL)
            }

        default:
            NSLog("[ZipExtractor] Skipping \(entry.fileName): unsupported method \(entry.compressionMethod)")
        }
    }

    // MARK: - zlib inflate (raw deflate, no header)

    private static func inflateRaw(_ data: Data, expectedSize: Int) -> Data? {
        guard !data.isEmpty else { return Data() }

        var src = [UInt8](data)
        var stream = z_stream()

        return src.withUnsafeMutableBufferPointer { srcBuf -> Data? in
            guard let srcAddress = srcBuf.baseAddress else { return nil }
            stream.avail_in = uInt(srcBuf.count)
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: srcAddress)

            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                return nil
            }
            defer { inflateEnd(&stream) }

            var output = Data(capacity: max(expectedSize, 4096))
            let bufferSize = 65536
            var buffer = [UInt8](repeating: 0, count: bufferSize)

            repeat {
                let status: Int32 = buffer.withUnsafeMutableBytes { bufPtr in
                    stream.next_out  = bufPtr.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(bufferSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = bufferSize - Int(stream.avail_out)
                if produced > 0 { output.append(buffer, count: produced) }

                if status == Z_STREAM_END { break }
                if status != Z_OK && status != Z_BUF_ERROR { return nil }
            } while stream.avail_in > 0

            return output
        }
    }
}

// MARK: - Data helpers (unaligned little-endian reads)

private extension Data {
    func loadU16(at offset: Int) -> UInt16 {
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
    }
    func loadU32(at offset: Int) -> UInt32 {
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }
}
