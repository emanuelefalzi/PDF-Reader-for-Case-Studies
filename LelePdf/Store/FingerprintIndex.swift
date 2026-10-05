import Foundation

/// `<data folder>/.indice.json` (SPEC §8): fingerprint → folder, and
/// SHA-256 of the file's bytes → fingerprint (a fast path that avoids
/// recomputing the real fingerprint when the file has not changed).
struct FingerprintIndex: Codable, Sendable, Equatable {
    var version: Int = 1
    var fingerprintToFolder: [String: String] = [:]
    var byteHashToFingerprint: [String: String] = [:]
}
