import Compression
import Foundation

/// Minimal ZIP reader: reads the INTERNAL PARTS (`word/styles.xml`,
/// `word/numbering.xml`, theme, `fontTable.xml`, images) of a `.docx` the user
/// chose in Settings ("Word template for export" -> "Choose…", done once, see
/// `WordTemplateStore`), not on every export.
///
/// `MinimalZipWriter` writes only with the "store" method (0, no
/// compression): a real `.docx` produced by Word is almost always "deflate"
/// compressed (method 8), so this reader must be able to decompress it.
/// `Compression` (`import Compression`, `libcompression`) is an Apple
/// framework, not a third-party dependency (the rule is no external
/// dependencies, not no system frameworks beyond Foundation/PDFKit/AppKit):
/// `COMPRESSION_ZLIB` with `compression_decode_buffer` decodes exactly the
/// "raw deflate" stream (RFC 1951) used inside a ZIP archive, with no zlib
/// header; it is the usual way to read ZIP files with this framework.
enum MinimalZipReader {
    enum ReadError: Error, Equatable {
        case notAZip
        case unsupportedMethod(UInt16)
        case corrupt(String)
    }

    /// All entries of the archive, path -> decompressed bytes.
    static func readEntries(from archive: Data) throws -> [String: Data] {
        let bytes = [UInt8](archive)
        guard let eocdOffset = findEndOfCentralDirectory(bytes) else { throw ReadError.notAZip }
        guard eocdOffset + 22 <= bytes.count else { throw ReadError.corrupt("truncated EOCD") }

        let entryCount = Int(readUInt16(bytes, eocdOffset + 10))
        let centralDirOffset = Int(readUInt32(bytes, eocdOffset + 16))
        guard centralDirOffset < bytes.count else { throw ReadError.corrupt("central directory out of range") }

        var result: [String: Data] = [:]
        var cursor = centralDirOffset
        for _ in 0 ..< entryCount {
            guard cursor + 46 <= bytes.count, readUInt32(bytes, cursor) == 0x0201_4b50 else {
                throw ReadError.corrupt("missing central directory signature")
            }
            let method = readUInt16(bytes, cursor + 10)
            let compressedSize = Int(readUInt32(bytes, cursor + 20))
            let uncompressedSize = Int(readUInt32(bytes, cursor + 24))
            let nameLength = Int(readUInt16(bytes, cursor + 28))
            let extraLength = Int(readUInt16(bytes, cursor + 30))
            let commentLength = Int(readUInt16(bytes, cursor + 32))
            let localHeaderOffset = Int(readUInt32(bytes, cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= bytes.count else { throw ReadError.corrupt("entry name out of range") }
            let path = String(decoding: bytes[nameStart ..< nameStart + nameLength], as: UTF8.self)
            cursor = nameStart + nameLength + extraLength + commentLength

            guard !path.hasSuffix("/") else { continue } // directory entry, no data

            let data = try extractEntry(
                bytes, localHeaderOffset: localHeaderOffset, method: method,
                compressedSize: compressedSize, uncompressedSize: uncompressedSize
            )
            result[path] = data
        }
        return result
    }

    private static func extractEntry(
        _ bytes: [UInt8], localHeaderOffset: Int, method: UInt16, compressedSize: Int, uncompressedSize: Int
    ) throws -> Data {
        guard localHeaderOffset + 30 <= bytes.count, readUInt32(bytes, localHeaderOffset) == 0x0403_4b50 else {
            throw ReadError.corrupt("missing local header signature")
        }
        let nameLength = Int(readUInt16(bytes, localHeaderOffset + 26))
        let extraLength = Int(readUInt16(bytes, localHeaderOffset + 28))
        let dataStart = localHeaderOffset + 30 + nameLength + extraLength
        guard dataStart + compressedSize <= bytes.count else { throw ReadError.corrupt("entry data out of range") }
        let compressed = Array(bytes[dataStart ..< dataStart + compressedSize])

        switch method {
        case 0:
            return Data(compressed)
        case 8:
            return try inflate(compressed, expectedSize: uncompressedSize)
        default:
            throw ReadError.unsupportedMethod(method)
        }
    }

    /// "Deflate" (RFC 1951), the almost universal method of a real `.docx`
    /// produced by Word/LibreOffice/Pages.
    private static func inflate(_ compressed: [UInt8], expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var destination = [UInt8](repeating: 0, count: expectedSize)
        let written = destination.withUnsafeMutableBufferPointer { destBuffer -> Int in
            compressed.withUnsafeBufferPointer { srcBuffer -> Int in
                compression_decode_buffer(
                    destBuffer.baseAddress!, expectedSize,
                    srcBuffer.baseAddress!, compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else {
            throw ReadError.corrupt("incomplete deflate decompression (\(written)/\(expectedSize) bytes)")
        }
        return Data(destination)
    }

    /// Looks for the "End Of Central Directory" signature (`PK\x05\x06`)
    /// starting from the end of the archive (it may have a variable comment
    /// after it, up to 64 KB): a real `.docx` almost never has a comment, but
    /// the backward search is correct anyway.
    private static func findEndOfCentralDirectory(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let searchFloor = max(0, bytes.count - 22 - 65536)
        var index = bytes.count - 22
        while index >= searchFloor {
            if readUInt32(bytes, index) == 0x0605_4b50 { return index }
            index -= 1
        }
        return nil
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }
}
