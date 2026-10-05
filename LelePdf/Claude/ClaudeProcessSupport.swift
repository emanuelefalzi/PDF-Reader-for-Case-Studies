import Foundation

/// Raw outcome of a one-shot process (SPEC §7.5, §7.8): never published on
/// the MainActor, only `Sendable` data.
struct ProcessRunResult: Sendable, Equatable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool

    /// Last lines of stderr (or stdout if stderr is empty), for error messages
    /// (SPEC §5.5 "processFailed").
    func tail(maxLength: Int = 400) -> String {
        let source = stderr.isEmpty ? stdout : stderr
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.suffix(maxLength))
    }
}

/// Reads a pipe until EOF on a background queue (same pattern as
/// `FakeClaudeCLITests.PipeReader`, which was meant to be reused as the model
/// for `BatchRunner`).
final class ClaudePipeReader: @unchecked Sendable {
    private let group = DispatchGroup()
    private var data = Data()

    init(_ handle: FileHandle) {
        group.enter()
        DispatchQueue.global().async {
            self.data = handle.readDataToEndOfFile()
            self.group.leave()
        }
    }

    func text(timeout: TimeInterval) -> String {
        guard group.wait(timeout: .now() + timeout) == .success else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Allows cancelling a one-shot process already started from another `Task`
/// (SPEC §6.3, BatchRunner: "callers ... can cancel while waiting or while it
/// runs"). `@unchecked Sendable`: state protected by a lock.
final class ProcessCancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: Int32?
    private var cancelled = false

    func attach(pid: Int32) {
        lock.lock()
        self.pid = pid
        let shouldSignal = cancelled
        lock.unlock()
        if shouldSignal { Foundation.kill(pid, SIGTERM) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let pid = self.pid
        lock.unlock()
        if let pid { Foundation.kill(pid, SIGTERM) }
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

/// Runs a one-shot process with stdin set to `/dev/null` when there is no
/// input, stdout/stderr drained in parallel, and a timeout that calls
/// `terminate()` and then `SIGKILL` after 2 s (SPEC §7.5), never on the
/// MainActor. The blocking work runs on a dedicated `DispatchQueue.global`
/// queue, not on Swift Concurrency's cooperative pool, so as not to starve it
/// during a wait of up to 120 s.
enum OneShotProcess {
    static func run(
        executable: String,
        arguments: [String],
        input: String? = nil,
        environment: [String: String],
        currentDirectory: URL? = nil,
        timeout: TimeInterval,
        cancelToken: ProcessCancelToken? = nil
    ) async -> ProcessRunResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = runBlocking(
                    executable: executable, arguments: arguments, input: input,
                    environment: environment, currentDirectory: currentDirectory,
                    timeout: timeout, cancelToken: cancelToken
                )
                continuation.resume(returning: result)
            }
        }
    }

    private static func runBlocking(
        executable: String, arguments: [String], input: String?,
        environment: [String: String], currentDirectory: URL?,
        timeout: TimeInterval, cancelToken: ProcessCancelToken?
    ) -> ProcessRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = input.map { _ in Pipe() }
        process.standardInput = inPipe ?? FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: "unable to launch \(executable): \(error.localizedDescription)", timedOut: false)
        }
        cancelToken?.attach(pid: process.processIdentifier)

        let outReader = ClaudePipeReader(outPipe.fileHandleForReading)
        let errReader = ClaudePipeReader(errPipe.fileHandleForReading)

        if let input, let inPipe {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                Foundation.kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }

        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: outReader.text(timeout: 2),
            stderr: errReader.text(timeout: 2),
            timedOut: timedOut
        )
    }
}
