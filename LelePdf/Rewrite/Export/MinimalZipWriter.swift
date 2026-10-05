import Foundation

/// Minimal zip, "store" (no compression), Foundation only: it packages
/// `.docx` files (`RewriteDocxExporter`), which are in effect a ZIP containing
/// XML. The app uses Apple frameworks only, with no external dependencies, so
/// no third-party `Compression`/`zlib`: "store" is a valid compression method
/// for the ZIP standard (method = 0), readable by any program that opens
/// `.docx`/`.zip`, just without space savings (acceptable: the exported
/// documents are text, a few KB).
enum MinimalZipWriter {
    struct Entry {
        let path: String
        let data: Data
    }

    static func makeArchive(entries: [Entry]) -> Data {
        var out = Data()
        struct CentralRecord {
            let path: String
            let crc32: UInt32
            let size: UInt32
            let offset: UInt32
        }
        var centralRecords: [CentralRecord] = []

        for entry in entries {
            let offset = UInt32(out.count)
            let nameData = Array(entry.path.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)

            var local = Data()
            local.append(uint32: 0x0403_4b50) // local file header signature
            local.append(uint16: 20) // version needed to extract
            local.append(uint16: 0) // flags
            local.append(uint16: 0) // compression method: 0 = store
            local.append(uint16: 0) // mod file time
            local.append(uint16: 0x21) // mod file date (1980-01-01, a fixed value: no real clock in tests)
            local.append(uint32: crc)
            local.append(uint32: size) // compressed size == uncompressed (store)
            local.append(uint32: size)
            local.append(uint16: UInt16(nameData.count))
            local.append(uint16: 0) // extra field length
            local.append(contentsOf: nameData)
            local.append(entry.data)
            out.append(local)

            centralRecords.append(CentralRecord(path: entry.path, crc32: crc, size: size, offset: offset))
        }

        let centralStart = UInt32(out.count)
        var central = Data()
        for record in centralRecords {
            let nameData = Array(record.path.utf8)
            central.append(uint32: 0x0201_4b50) // central directory header signature
            central.append(uint16: 20) // version made by
            central.append(uint16: 20) // version needed to extract
            central.append(uint16: 0) // flags
            central.append(uint16: 0) // method: store
            central.append(uint16: 0) // mod time
            central.append(uint16: 0x21) // mod date
            central.append(uint32: record.crc32)
            central.append(uint32: record.size)
            central.append(uint32: record.size)
            central.append(uint16: UInt16(nameData.count))
            central.append(uint16: 0) // extra length
            central.append(uint16: 0) // comment length
            central.append(uint16: 0) // disk number start
            central.append(uint16: 0) // internal attributes
            central.append(uint32: 0) // external attributes
            central.append(uint32: record.offset)
            central.append(contentsOf: nameData)
        }
        out.append(central)

        var end = Data()
        end.append(uint32: 0x0605_4b50) // end of central directory signature
        end.append(uint16: 0) // disk number
        end.append(uint16: 0) // disk with central directory
        end.append(uint16: UInt16(centralRecords.count)) // entries on this disk
        end.append(uint16: UInt16(centralRecords.count)) // entries total
        end.append(uint32: UInt32(central.count)) // central directory size
        end.append(uint32: centralStart) // central directory offset
        end.append(uint16: 0) // comment length
        out.append(end)

        return out
    }

    // MARK: - CRC-32 (IEEE 802.3), table computed once

    private static let crcTable: [UInt32] = {
        (0 ..< 256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0 ..< 8 {
                value = (value & 1 != 0) ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crcTable[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func append(uint32 value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
