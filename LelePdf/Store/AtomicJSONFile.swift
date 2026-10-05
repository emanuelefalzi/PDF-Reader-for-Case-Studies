import Foundation

/// Atomic JSON reading/writing (SPEC §8 "Writes: atomic (temporary file
/// and replace)"). No state: pure functions over `URL`, used by the
/// `DocumentStore` actor (never on the MainActor, SPEC §6.3).
enum AtomicJSONFile {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Writes `value` to `url` via a temporary file + atomic replace
    /// (`FileManager.replaceItemAt`). If `keepBackup` is true and `url`
    /// already exists, it first copies it to `<url>.bak` (SPEC §8: only
    /// `analisi.json` needs one). It never throws on unrecoverable I/O errors
    /// other than encoding ones: the caller decides whether to log, but it
    /// must never block the app (SPEC §8 "never crash").
    static func write(_ data: Data, to url: URL, keepBackup: Bool) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if keepBackup, FileManager.default.fileExists(atPath: url.path) {
            let backupURL = url.appendingPathExtension("bak")
            // Never delete the good copy first: prepare a new copy next to it
            // and replace it only when it is complete. If the copy fails, the
            // old `.bak` stays intact.
            let backupTempURL = dir.appendingPathComponent(".\(backupURL.lastPathComponent).tmp-\(UUID().uuidString)")
            if (try? FileManager.default.copyItem(at: url, to: backupTempURL)) != nil {
                if FileManager.default.fileExists(atPath: backupURL.path) {
                    _ = try? FileManager.default.replaceItemAt(backupURL, withItemAt: backupTempURL)
                } else {
                    try? FileManager.default.moveItem(at: backupTempURL, to: backupURL)
                }
                try? FileManager.default.removeItem(at: backupTempURL)
            }
        }

        let tmpURL = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tmpURL, options: .atomic)

        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpURL)
        } else {
            try FileManager.default.moveItem(at: tmpURL, to: url)
        }
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    /// Reads from `url`; if the content cannot be decoded (truncated or
    /// corrupt JSON) it falls back to `<url>.bak` if it exists, and in that
    /// case also puts the valid content back into the main file, so it does
    /// not stay corrupt on disk (SPEC §8, M3 criterion "simulated interruption
    /// → no corrupt file").
    static func decodeWithBackupFallback<T: Decodable>(_ type: T.Type, from url: URL) -> (value: T?, usedBackup: Bool) {
        if let value = decode(type, from: url) {
            return (value, false)
        }
        let backupURL = url.appendingPathExtension("bak")
        guard let backupValue: T = decode(type, from: backupURL) else {
            return (nil, false)
        }
        if let backupData = try? Data(contentsOf: backupURL) {
            try? backupData.write(to: url, options: .atomic)
        }
        return (backupValue, true)
    }
}
