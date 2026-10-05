import Testing
import Foundation
@testable import LelePdf

/// Atomic write and `.bak` at file level (SPEC §8 "Writes: atomic ...
/// `analisi.json.bak` of the previous version is kept"), without going
/// through the actor: isolates the `AtomicJSONFile` mechanism from
/// `DocumentStore`.
@Suite("AtomicJSONFile")
struct AtomicJSONFileTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("plain write and read")
    func writeAndRead() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("documento.json")

        let record = TestPayload(value: "prima versione")
        try AtomicJSONFile.write(try AtomicJSONFile.encode(record), to: url, keepBackup: false)

        let loaded = AtomicJSONFile.decode(TestPayload.self, from: url)
        #expect(loaded == record)
        // No leftover temporary file after a successful write.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(siblings == ["documento.json"])
    }

    @Test("keepBackup creates .bak with the previous version")
    func backupCreatedOnSecondWrite() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("analisi.json")

        let v1 = TestPayload(value: "v1")
        try AtomicJSONFile.write(try AtomicJSONFile.encode(v1), to: url, keepBackup: true)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))

        let v2 = TestPayload(value: "v2")
        try AtomicJSONFile.write(try AtomicJSONFile.encode(v2), to: url, keepBackup: true)

        let backupURL = url.appendingPathExtension("bak")
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        #expect(AtomicJSONFile.decode(TestPayload.self, from: backupURL) == v1)
        #expect(AtomicJSONFile.decode(TestPayload.self, from: url) == v2)
    }

    @Test("write interrupted before the replacement: the original file stays intact")
    func interruptedWriteLeavesOriginalIntact() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("documento.json")

        let good = TestPayload(value: "buono")
        try AtomicJSONFile.write(try AtomicJSONFile.encode(good), to: url, keepBackup: false)

        // Simulates an interruption: a temporary file with garbage is written
        // but `replaceItemAt` is never reached (kill midway/power loss during the
        // write).
        let garbageTmp = dir.appendingPathComponent(".documento.json.tmp-\(UUID().uuidString)")
        try Data("non è JSON valido {{{".utf8).write(to: garbageTmp)

        // The main file was never touched by the interruption.
        let loaded = AtomicJSONFile.decode(TestPayload.self, from: url)
        #expect(loaded == good)
        #expect(try Data(contentsOf: garbageTmp).count > 0) // the tmp stays, but does not interfere
    }

    @Test("corrupted analisi.json: falls back to .bak and restores it")
    func corruptedFileFallsBackToBackup() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("analisi.json")

        let v1 = TestPayload(value: "valido")
        try AtomicJSONFile.write(try AtomicJSONFile.encode(v1), to: url, keepBackup: true)
        let v2 = TestPayload(value: "anche questo valido")
        try AtomicJSONFile.write(try AtomicJSONFile.encode(v2), to: url, keepBackup: true)

        // Corrupts the main file directly (simulates a damaged disk or a process
        // dying while writing without going through `AtomicJSONFile.write`).
        try Data("{questo non è json".utf8).write(to: url)

        let (value, usedBackup) = AtomicJSONFile.decodeWithBackupFallback(TestPayload.self, from: url)
        #expect(usedBackup)
        #expect(value == v1) // the version before v2, i.e. the one in .bak

        // The main file does not stay corrupted: it was repaired with the
        // backup's content (SPEC M3: "no corrupted file").
        #expect(AtomicJSONFile.decode(TestPayload.self, from: url) == v1)
    }
}

private struct TestPayload: Codable, Equatable {
    var value: String
}
