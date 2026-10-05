import Foundation

/// Regenerable cache of page layouts (SPEC §7.1):
/// `~/Library/Caches/LelePdf/<fingerprint>/layout.json`. If it is missing or
/// the segmentation version does not match, the pipeline regenerates it from
/// scratch: no data here is essential to open the PDF (M3 adds the real
/// persisted data in `documento.json`/`analisi.json`, distinct from this
/// cache).
enum LayoutCache {
    private struct CacheFile: Codable {
        let segmentationVersion: Int
        let layouts: [PageLayout]
    }

    private static func directory(for fingerprint: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LelePdf", isDirectory: true).appendingPathComponent(fingerprint, isDirectory: true)
    }

    private static func fileURL(for fingerprint: String) -> URL {
        directory(for: fingerprint).appendingPathComponent("layout.json")
    }

    static func load(fingerprint: String) -> [PageLayout]? {
        guard let data = try? Data(contentsOf: fileURL(for: fingerprint)),
              let cache = try? JSONDecoder().decode(CacheFile.self, from: data),
              cache.segmentationVersion == SegmentationVersion.current
        else { return nil }
        return cache.layouts
    }

    static func save(fingerprint: String, layouts: [PageLayout]) {
        let dir = directory(for: fingerprint)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cache = CacheFile(segmentationVersion: SegmentationVersion.current, layouts: layouts)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: fileURL(for: fingerprint), options: .atomic)
    }
}
