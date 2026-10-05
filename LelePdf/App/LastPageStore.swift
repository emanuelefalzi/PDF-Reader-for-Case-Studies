import Foundation
import CryptoKit

/// Remains of M1's provisional last-read-page storage (UserDefaults). Since
/// M3 the source of truth is `progress.lastReadPage` in the Store
/// (SPEC §8): this type remains only for the one-time migration of a
/// document first seen by this app before M3 (SPEC M3 point 4 "migrate:
/// if UserDefaults has a value and the record does not, use it once").
/// Nothing is written here anymore.
enum LastPageStore {
    private static let defaultsKeyPrefix = "LelePdf.lastPage."

    static func provisionalKey(for data: Data) -> String {
        let prefixLength = min(data.count, 1_000_000)
        let digest = SHA256.hash(data: data.prefix(prefixLength))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex)-\(data.count)"
    }

    /// `nil` if nothing was saved by the old provisional version.
    static func lastPage(for data: Data) -> Int? {
        let key = defaultsKeyPrefix + provisionalKey(for: data)
        let value = AppRuntime.defaults.integer(forKey: key)
        return value > 0 ? value : nil
    }
}
