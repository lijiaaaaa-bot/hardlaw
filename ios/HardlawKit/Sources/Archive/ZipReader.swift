import Foundation
import zlib

/// Minimal in-house Zip reader — supports stored and deflate entries only.
/// Rejects path-traversal attacks (entries with `..` or absolute paths).
public enum ZipReader {

    public struct Entry {
        public let filename: String
        public let compressedSize: Int
        public let uncompressedSize: Int
        public let method: UInt16
        public let crc32: UInt32
        fileprivate let localHeaderOffset: UInt64
    }

    // MARK: - Public API

    /// Extract all entries from a zip file into `destDir`.
    /// Returns the URLs of successfully extracted files.
    public static func extractAll(from archiveURL: URL, to destDir: URL) throws -> [URL] {
        let data = try Data(contentsOf: archiveURL, options: .alwaysMapped)
        let entries = try parseCentralDirectory(from: data)

        var extracted: [URL] = []
        let fm = FileManager.default
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        for entry in entries {
            guard let url = try extractEntry(entry, from: data, to: destDir) else { continue }
            extracted.append(url)
        }
        return extracted
    }

    // MARK: - Parsing

    private static func parseCentralDirectory(from data: Data) throws -> [Entry] {
        guard data.count > 22 else { throw ZipError.tooSmall }

        // Find EOCD signature (0x06054b50) scanning backwards from end
        let eocdOffset = try findEOCD(in: data)
        let reader = DataReader(data: data, offset: eocdOffset)

        // EOCD:
        //   uint32 signature
        //   uint16 diskNumber
        //   uint16 centralDirDisk
        //   uint16 entriesOnDisk
        //   uint16 totalEntries
        //   uint32 centralDirSize
        //   uint32 centralDirOffset
        //   uint16 commentLength
        guard (try reader.readUInt32()) == 0x06054b50 else { throw ZipError.badEOCD }
        reader.skip(4) // diskNumber + centralDirDisk
        let totalEntries = Int(try reader.readUInt16())
        guard (try reader.readUInt16()) == totalEntries else { throw ZipError.multiDisk }
        let centralDirSize = try reader.readUInt32()
        let centralDirOffset = UInt64(try reader.readUInt32())

        guard centralDirOffset + UInt64(centralDirSize) <= data.count else {
            throw ZipError.badCentralDir
        }

        // Sanity check: reject obviously malicious entry counts
        guard totalEntries > 0, totalEntries < 100_000 else { throw ZipError.tooManyEntries(totalEntries) }

        // Parse central directory entries
        var entries: [Entry] = []
        var offset = Int(centralDirOffset)
        for _ in 0..<totalEntries {
            let cr = DataReader(data: data, offset: offset)

            // Central directory file header:
            //   uint32 signature (0x02014b50)
            //   uint16 versionMadeBy
            //   uint16 versionNeeded
            //   uint16 flags
            //   uint16 method
            //   uint16 modTime, modDate
            //   uint32 crc32
            //   uint32 compressedSize
            //   uint32 uncompressedSize
            //   uint16 filenameLength
            //   uint16 extraLength
            //   uint16 commentLength
            //   uint16 diskStart
            //   uint16 internalAttrs
            //   uint32 externalAttrs
            //   uint32 localHeaderOffset
            guard (try cr.readUInt32()) == 0x02014b50 else { throw ZipError.badCentralEntry(offset) }
            cr.skip(4) // version + versionNeeded
            let flags = try cr.readUInt16()
            let method = try cr.readUInt16()
            cr.skip(4) // modTime + modDate
            let crc32 = try cr.readUInt32()
            let compressedSize = try cr.readUInt32()
            let uncompressedSize = try cr.readUInt32()
            let filenameLength = Int(try cr.readUInt16())
            let extraFieldLength = Int(try cr.readUInt16())
            let commentLength = Int(try cr.readUInt16())
            cr.skip(8) // diskStart + internalAttrs + externalAttrs
            let localHeaderOffset = UInt64(try cr.readUInt32())

            // Boundary check: filename must be within data
            let nameEnd = cr.offset + filenameLength
            guard nameEnd <= data.count, filenameLength >= 0 else {
                throw ZipError.badCentralEntry(offset)
            }

            let filenameBytes = data[cr.offset..<nameEnd]
            let filename = decodeFilename(filenameBytes, flags: flags)

            // Path traversal guard: only block leading ".." or "/"
            let pathComponents = filename.components(separatedBy: "/")
            guard !pathComponents.contains(".."), !filename.hasPrefix("/") else {
                throw ZipError.pathTraversal(filename)
            }

            // Skip directories
            guard !filename.hasSuffix("/") else {
                offset = cr.offset + filenameLength + extraFieldLength + commentLength
                continue
            }

            entries.append(Entry(
                filename: filename,
                compressedSize: Int(compressedSize),
                uncompressedSize: Int(uncompressedSize),
                method: method,
                crc32: crc32,
                localHeaderOffset: localHeaderOffset
            ))

            offset = cr.offset + filenameLength + extraFieldLength + commentLength
        }

        return entries
    }

    private static func extractEntry(_ entry: Entry, from data: Data, to destDir: URL) throws -> URL? {
        let reader = DataReader(data: data, offset: entry.localHeaderOffset)

        // Local file header:
        //   uint32 signature (0x04034b50)
        //   uint16 versionNeeded
        //   uint16 flags
        //   uint16 method
        //   uint16 modTime, modDate
        //   uint32 crc32
        //   uint32 compressedSize
        //   uint32 uncompressedSize
        //   uint16 filenameLength
        //   uint16 extraFieldLength
        guard (try reader.readUInt32()) == 0x04034b50 else { throw ZipError.badLocalHeader(entry.localHeaderOffset) }
        reader.skip(4) // version + flags
        let method = try reader.readUInt16()
        reader.skip(8) // modTime + modDate + crc32
        let compressedSize = try reader.readUInt32()
        let uncompressedSize = try reader.readUInt32()
        let filenameLength = Int(try reader.readUInt16())
        let extraFieldLength = Int(try reader.readUInt16())
        let dataStart = reader.offset + filenameLength + extraFieldLength
        guard dataStart <= data.count else { throw ZipError.badLocalHeader(entry.localHeaderOffset) }

        let uncompressedData: Data
        switch method {
        case 0: // Stored
            let size = Int(compressedSize > 0 ? compressedSize : uncompressedSize)
            guard size >= 0, dataStart + size <= data.count else { throw ZipError.badLocalHeader(entry.localHeaderOffset) }
            uncompressedData = data.subdata(in: dataStart..<(dataStart + size))
        case 8: // Deflated
            let compressedEnd: Int
            if compressedSize > 0 {
                compressedEnd = dataStart + Int(compressedSize)
            } else {
                // Find data descriptor or end of file
                compressedEnd = data.count
            }
            let compressed = data.subdata(in: dataStart..<min(compressedEnd, data.count))
            uncompressedData = try inflateData(compressed, expectedSize: Int(uncompressedSize))
        default:
            throw ZipError.unsupportedMethod(method, entry.filename)
        }

        // Write to destination
        let destURL = destDir.appendingPathComponent(entry.filename)
        let parentDir = destURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try uncompressedData.write(to: destURL, options: .atomic)
        return destURL
    }

    // MARK: - Helpers

    private static func findEOCD(in data: Data) throws -> Int {
        let maxCommentLength = 65535
        let searchStart = max(0, data.count - maxCommentLength - 22)

        // Search for signature 0x06054b50
        for i in stride(from: data.count - 22, through: searchStart, by: -1) {
            let b0 = data[i]
            let b1 = data[i + 1]
            let b2 = data[i + 2]
            let b3 = data[i + 3]
            if b0 == 0x50 && b1 == 0x4b && b2 == 0x05 && b3 == 0x06 {
                return i
            }
        }
        throw ZipError.badEOCD
    }

    private static func decodeFilename(_ bytes: Data, flags: UInt16) -> String {
        let isUTF8 = (flags & (1 << 11)) != 0 // bit 11: UTF-8
        if isUTF8 {
            return String(data: bytes, encoding: .utf8)
                ?? String(data: bytes, encoding: .windowsCP1252)
                ?? String(data: bytes, encoding: .ascii)
                ?? "(unknown)"
        }
        // Try UTF-8 first (common), then CP437, then fallback
        return String(data: bytes, encoding: .utf8)
            ?? decodeCP437(bytes)
            ?? String(data: bytes, encoding: .ascii)
            ?? "(unknown)"
    }

    private static func decodeCP437(_ data: Data) -> String? {
        // CP437 to Unicode mapping for the high byte range (0x80-0xFF)
        let cp437High: [UInt8: UInt16] = [
            0x80: 0x00C7, 0x81: 0x00FC, 0x82: 0x00E9, 0x83: 0x00E2,
            0x84: 0x00E4, 0x85: 0x00E0, 0x86: 0x00E5, 0x87: 0x00E7,
            0x88: 0x00EA, 0x89: 0x00EB, 0x8A: 0x00E8, 0x8B: 0x00EF,
            0x8C: 0x00EE, 0x8D: 0x00EC, 0x8E: 0x00C4, 0x8F: 0x00C5,
            0x90: 0x00C9, 0x91: 0x00E6, 0x92: 0x00C6, 0x93: 0x00F4,
            0x94: 0x00F6, 0x95: 0x00F2, 0x96: 0x00FB, 0x97: 0x00F9,
            0x98: 0x00FF, 0x99: 0x00D6, 0x9A: 0x00DC, 0x9B: 0x00A2,
            0x9C: 0x00A3, 0x9D: 0x00A5, 0x9E: 0x20A7, 0x9F: 0x0192,
            0xA0: 0x00E1, 0xA1: 0x00ED, 0xA2: 0x00F3, 0xA3: 0x00FA,
            0xA4: 0x00F1, 0xA5: 0x00D1, 0xA6: 0x00AA, 0xA7: 0x00BA,
            0xA8: 0x00BF, 0xA9: 0x2310, 0xAA: 0x00AC, 0xAB: 0x00BD,
            0xAC: 0x00BC, 0xAD: 0x00A1, 0xAE: 0x00AB, 0xAF: 0x00BB,
            0xB0: 0x2591, 0xB1: 0x2592, 0xB2: 0x2593, 0xB3: 0x2502,
            0xB4: 0x2524, 0xB5: 0x2561, 0xB6: 0x2562, 0xB7: 0x2556,
            0xB8: 0x2555, 0xB9: 0x2563, 0xBA: 0x2551, 0xBB: 0x2557,
            0xBC: 0x255D, 0xBD: 0x255C, 0xBE: 0x255B, 0xBF: 0x2510,
            0xC0: 0x2514, 0xC1: 0x2534, 0xC2: 0x252C, 0xC3: 0x251C,
            0xC4: 0x2500, 0xC5: 0x253C, 0xC6: 0x255E, 0xC7: 0x255F,
            0xC8: 0x255A, 0xC9: 0x2554, 0xCA: 0x2569, 0xCB: 0x2566,
            0xCC: 0x2560, 0xCD: 0x2550, 0xCE: 0x256C, 0xCF: 0x2567,
            0xD0: 0x2568, 0xD1: 0x2564, 0xD2: 0x2565, 0xD3: 0x2559,
            0xD4: 0x2558, 0xD5: 0x2552, 0xD6: 0x2553, 0xD7: 0x256B,
            0xD8: 0x256A, 0xD9: 0x2518, 0xDA: 0x250C, 0xDB: 0x2588,
            0xDC: 0x2584, 0xDD: 0x258C, 0xDE: 0x2590, 0xDF: 0x2580,
            0xE0: 0x03B1, 0xE1: 0x00DF, 0xE2: 0x0393, 0xE3: 0x03C0,
            0xE4: 0x03A3, 0xE5: 0x03C3, 0xE6: 0x00B5, 0xE7: 0x03C4,
            0xE8: 0x03A6, 0xE9: 0x0398, 0xEA: 0x03A9, 0xEB: 0x03B4,
            0xEC: 0x221E, 0xED: 0x03C6, 0xEE: 0x03B5, 0xEF: 0x2229,
            0xF0: 0x2261, 0xF1: 0x00B1, 0xF2: 0x2265, 0xF3: 0x2264,
            0xF4: 0x2320, 0xF5: 0x2321, 0xF6: 0x00F7, 0xF7: 0x2248,
            0xF8: 0x00B0, 0xF9: 0x2219, 0xFA: 0x00B7, 0xFB: 0x221A,
            0xFC: 0x207F, 0xFD: 0x00B2, 0xFE: 0x25A0, 0xFF: 0x00A0,
        ]
        var result = ""
        for byte in data {
            if byte < 0x80 {
                result.append(Character(UnicodeScalar(byte)))
            } else if let mapped = cp437High[byte] {
                result.append(Character(UnicodeScalar(mapped)!))
            } else {
                result.append("?")
            }
        }
        return result
    }

    // MARK: - Decompression

    /// Maximum decompressed size for a single entry (200 MB) to prevent zip bombs.
    private static let maxDecompressSize = 200 * 1024 * 1024

    private static func inflateData(_ data: Data, expectedSize: Int) throws -> Data {
        // Reject entries claiming excessive decompressed size
        if expectedSize > maxDecompressSize || expectedSize < 0 {
            throw ZipError.entryTooLarge(expectedSize)
        }
        var zStream = z_stream()
        zStream.next_in = UnsafeMutablePointer<Bytef>(mutating: (data as NSData).bytes.bindMemory(to: Bytef.self, capacity: data.count))
        zStream.avail_in = uInt(data.count)
        zStream.total_in = 0
        zStream.zalloc = nil
        zStream.zfree = nil
        zStream.opaque = nil

        // -MAX_WBITS for raw deflate (no zlib/gzip header)
        let ret = inflateInit2_(&zStream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard ret == Z_OK else { throw ZipError.deflateInitFailed(Int(ret)) }
        defer { inflateEnd(&zStream) }

        var output = Data(count: expectedSize > 0 ? expectedSize : data.count * 4)
        zStream.next_out = output.withUnsafeMutableBytes { $0.bindMemory(to: Bytef.self).baseAddress }
        zStream.avail_out = uInt(output.count)

        let inflateRet = inflate(&zStream, Z_FINISH)
        guard inflateRet == Z_STREAM_END else {
            if inflateRet == Z_BUF_ERROR && expectedSize <= 0 {
                // Unknown size — grow buffer and retry
                return try inflateToEnd(from: zStream, data: data, output: output)
            }
            throw ZipError.deflateFailed(Int(inflateRet), zStream.msg.map { String(cString: $0) })
        }

        let actualSize = zStream.total_out
        output.count = Int(actualSize)
        return output
    }

    private static func inflateToEnd(from initialStream: z_stream, data: Data, output: Data) throws -> Data {
        // Reset and retry with growing buffer for unknown-size deflate streams
        var zStream = z_stream()
        zStream.next_in = UnsafeMutablePointer<Bytef>(mutating: (data as NSData).bytes.bindMemory(to: Bytef.self, capacity: data.count))
        zStream.avail_in = uInt(data.count)
        zStream.zalloc = nil
        zStream.zfree = nil
        zStream.opaque = nil

        let ret = inflateInit2_(&zStream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard ret == Z_OK else { throw ZipError.deflateInitFailed(Int(ret)) }
        defer { inflateEnd(&zStream) }

        let chunkSize = 65536
        var result = Data()
        var buffer = Data(count: chunkSize)

        while true {
            buffer.withUnsafeMutableBytes {
                zStream.next_out = $0.bindMemory(to: Bytef.self).baseAddress
            }
            zStream.avail_out = uInt(chunkSize)
            let r = inflate(&zStream, Z_NO_FLUSH)
            let written = chunkSize - Int(zStream.avail_out)
            if written > 0 {
                result.append(buffer[0..<written])
            }
            if r == Z_STREAM_END { break }
            guard r == Z_OK else {
                throw ZipError.deflateFailed(Int(r), zStream.msg.map { String(cString: $0) })
            }
        }
        return result
    }
}

// MARK: - Data Reader

private final class DataReader {
    let data: Data
    var offset: Int

    init(data: Data, offset: Int) {
        self.data = data
        self.offset = offset
    }

    init(data: Data, offset: UInt64) {
        self.data = data
        self.offset = Int(offset)
    }

    func readUInt16() throws -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { throw ZipError.truncatedArchive }
        let value = data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
        }
        offset += 2
        return UInt16(littleEndian: value)
    }

    func readUInt32() throws -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { throw ZipError.truncatedArchive }
        let value = data.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
        offset += 4
        return UInt32(littleEndian: value)
    }

    func skip(_ bytes: Int) {
        offset += bytes
    }
}

// MARK: - Errors

public enum ZipError: Error {
    case tooSmall
    case badEOCD
    case badCentralDir
    case badCentralEntry(Int)
    case badLocalHeader(UInt64)
    case multiDisk
    case unsupportedMethod(UInt16, String)
    case pathTraversal(String)
    case deflateInitFailed(Int)
    case deflateFailed(Int, String?)
    case tooManyEntries(Int)
    case entryTooLarge(Int)
    case truncatedArchive
}
