import Foundation

/// Line-based IO for the persistent chat process (SPEC §7.8): unlike
/// `OneShotProcess` (which waits for the end and reads everything at once),
/// here stdout must be read **while the process runs**, line by line, because
/// the CLI writes one JSON event per line as long as stdin stays open.
///
/// `@unchecked Sendable`: a single `ChatSession` (actor) owns the instance;
/// `onLine`/`onExit` arrive from `FileHandle`'s internal queue
/// (`readabilityHandler`), never in parallel with each other thanks to the
/// lock on `lineBuffer`.
final class ChatProcessIO: @unchecked Sendable {
    private let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let inPipe = Pipe()
    private let lock = NSLock()
    private var lineBuffer = Data()
    private var errData = Data()

    var isRunning: Bool { process.isRunning }
    var processIdentifier: Int32 { process.processIdentifier }

    /// `onLine`/`onExit` are called from a Foundation background queue, not
    /// from the calling actor: whoever uses them must hop back into their own
    /// isolation (typically with `Task { await ... }`).
    func start(
        executable: String, arguments: [String], environment: [String: String], currentDirectory: URL,
        onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.appendAndSplit(chunk, onLine: onLine)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let self else { return }
            self.lock.lock(); self.errData.append(chunk); self.lock.unlock()
        }
        process.terminationHandler = { [weak self] finished in
            self?.outPipe.fileHandleForReading.readabilityHandler = nil
            self?.errPipe.fileHandleForReading.readabilityHandler = nil
            onExit(finished.terminationStatus)
        }
        try process.run()
    }

    private func appendAndSplit(_ chunk: Data, onLine: (String) -> Void) {
        lock.lock()
        lineBuffer.append(chunk)
        var lines: [String] = []
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<newline)
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            if let text = String(data: lineData, encoding: .utf8) { lines.append(text) }
        }
        lock.unlock()
        for line in lines { onLine(line) }
    }

    /// Input line per SPEC §4/§7.8: `{"type":"user","message":{...}}`
    /// followed by a newline.
    func writeLine(_ text: String) {
        guard inPipe.fileHandleForWriting.fileDescriptor >= 0 else { return }
        var data = Data(text.utf8)
        data.append(0x0A)
        inPipe.fileHandleForWriting.write(data)
    }

    func closeStdin() {
        try? inPipe.fileHandleForWriting.close()
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func forceKill() {
        if process.isRunning { Foundation.kill(process.processIdentifier, SIGKILL) }
    }

    func errorTail(maxLength: Int = 4000) -> String {
        lock.lock(); defer { lock.unlock() }
        let text = String(data: errData, encoding: .utf8) ?? ""
        return String(text.suffix(maxLength))
    }
}
