import Foundation

/// Data folder resolution (SPEC §5.11, §8) and index rebuilding. Isolated
/// from `DocumentStore.swift` only to stay under ~12 KB per file: this is
/// the safety logic that keeps a test process from resolving
/// `~/Documents/LelePdf` or `~/Desktop`, so it is worth keeping in a
/// dedicated file that is easy to reread and to test in full.
extension DocumentStore {
    static func resolveDataFolder(override: URL?) -> URL {
        if let override { return safeDataFolderForCurrentProcess(override) }
        if let env = ProcessInfo.processInfo.environment["LELEPDF_DATA_DIR"], !env.isEmpty {
            return safeDataFolderForCurrentProcess(URL(fileURLWithPath: env, isDirectory: true))
        }
        // The target is app-hosted and shares its bundle id/UserDefaults with
        // the app. This branch must come before any read of the real
        // preferences and before the fallback to ~/Documents: it makes even an
        // `xcodebuild test` launched without scripts/test.sh safe.
        if AppRuntime.isRunningUnderXCTest {
            return AppRuntime.xctestDataFolderURL
        }
        if let path = AppRuntime.defaults.string(forKey: dataFolderDefaultsKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("LelePdf", isDirectory: true)
    }

    /// Under XCTest, even an explicit override is rejected if it points to
    /// Desktop or Documents. In production it changes nothing: those are
    /// valid locations chosen by the user (SPEC §5.11).
    private static func safeDataFolderForCurrentProcess(_ candidate: URL) -> URL {
        guard AppRuntime.isRunningUnderXCTest else { return candidate }
        let protectedRoots = [
            FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0],
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
        ]
        let path = candidate.standardizedFileURL.path
        let isProtected = protectedRoots.contains { root in
            let rootPath = root.standardizedFileURL.path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
        return isProtected ? AppRuntime.xctestDataFolderURL : candidate
    }

    /// If `.indice.json` is missing or corrupt, it is rebuilt by reading
    /// `fingerprint` from the `documento.json` files already present (SPEC §8
    /// "never crash"): only the byte-hash → fingerprint map is lost, and it
    /// repopulates itself the next time each document is opened.
    static func rebuildIndex(scanning dataFolderURL: URL) -> FingerprintIndex {
        var index = FingerprintIndex()
        let subfolders = (try? FileManager.default.contentsOfDirectory(at: dataFolderURL, includingPropertiesForKeys: nil)) ?? []
        for folder in subfolders where folder.hasDirectoryPath {
            let documentoURL = folder.appendingPathComponent("documento.json")
            guard let record = AtomicJSONFile.decode(DocumentRecord.self, from: documentoURL) else { continue }
            index.fingerprintToFolder[record.fingerprint] = folder.lastPathComponent
        }
        return index
    }
}
