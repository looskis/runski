import Foundation
import Darwin

/// Spawns a child process, streams stdout/stderr line by line, supports cancellation
/// (SIGINT → SIGTERM → SIGKILL) and reports the exit code.
public final class ProcessRunner: @unchecked Sendable {
    public struct Result: Sendable {
        public let exitCode: Int32
        public let timedOut: Bool
    }

    private let process = Process()
    private let lock = NSLock()
    private var killed = false

    /// Seconds to wait after SIGINT before SIGTERM, and after SIGTERM before SIGKILL.
    public var graceSeconds: (interrupt: Double, terminate: Double) = (7.5, 2.5)

    public init(executable: String, arguments: [String], environment: [String: String], workingDirectory: String) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
    }

    /// All descendant pids of `pid` (children first), via libproc.
    public static func descendants(of pid: pid_t) -> [pid_t] {
        var out: [pid_t] = []
        var queue = [pid]
        while let p = queue.first {
            queue.removeFirst()
            let count = proc_listchildpids(p, nil, 0)
            guard count > 0 else { continue }
            var buf = [pid_t](repeating: 0, count: Int(count) + 8)
            let n = proc_listchildpids(p, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
            let kids = Array(buf.prefix(Int(n))).filter { $0 > 0 }
            out.append(contentsOf: kids)
            queue.append(contentsOf: kids)
        }
        return out
    }

    private static func signalTree(_ pid: pid_t, _ sig: Int32) {
        for child in descendants(of: pid).reversed() { kill(child, sig) }
        kill(pid, sig)
    }

    public var processIdentifier: Int32 { process.processIdentifier }

    /// Runs to completion. `onLine` receives (isStderr, line) as output arrives.
    public func run(timeout: TimeInterval?, onLine: @escaping @Sendable (Bool, String) -> Void) async throws -> Result {
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let outReader = LineReader { onLine(false, $0) }
        let errReader = LineReader { onLine(true, $0) }
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; outReader.finish() } else { outReader.feed(d) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; errReader.finish() } else { errReader.feed(d) }
        }

        try process.run()
        let timedOut = TimedOutFlag()
        let timeoutTask: Task<Void, Never>? = timeout.map { t in
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(t))
                guard !Task.isCancelled else { return }
                timedOut.value = true
                self?.terminate()
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                process.terminationHandler = { _ in c.resume() }
                if !process.isRunning { process.terminationHandler = nil; c.resume() }
            }
        } onCancel: {
            terminate()
        }
        timeoutTask?.cancel()
        // Drain readers.
        outReader.wait(); errReader.wait()
        return Result(exitCode: process.terminationStatus, timedOut: timedOut.value)
    }

    final class TimedOutFlag: @unchecked Sendable { var value = false }

    /// Graceful shutdown: SIGINT, then SIGTERM after 7.5s, then SIGKILL after 2.5s more.
    public func terminate() {
        lock.lock()
        if killed { lock.unlock(); return }
        killed = true
        lock.unlock()
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        let grace = graceSeconds
        ProcessRunner.signalTree(pid, SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace.interrupt) { [weak self] in
            guard let self, self.process.isRunning else { return }
            ProcessRunner.signalTree(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + grace.terminate) { [weak self] in
                guard let self, self.process.isRunning else { return }
                ProcessRunner.signalTree(pid, SIGKILL)
            }
        }
    }
}

/// Splits a byte stream into lines, tolerating partial UTF-8 across chunks.
final class LineReader: @unchecked Sendable {
    private var buffer = Data()
    private let onLine: (String) -> Void
    private let done = DispatchSemaphore(value: 0)
    private let queue = DispatchQueue(label: "runski.linereader")

    init(onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func feed(_ data: Data) {
        queue.async {
            self.buffer.append(data)
            while let nl = self.buffer.firstIndex(of: 0x0A) {
                var line = self.buffer.subdata(in: self.buffer.startIndex..<nl)
                if line.last == 0x0D { line.removeLast() }
                self.buffer.removeSubrange(self.buffer.startIndex...nl)
                self.onLine(String(decoding: line, as: UTF8.self))
            }
        }
    }

    func finish() {
        queue.async {
            if !self.buffer.isEmpty {
                self.onLine(String(decoding: self.buffer, as: UTF8.self))
                self.buffer.removeAll()
            }
            self.done.signal()
        }
    }

    func wait() { _ = done.wait(timeout: .now() + 5) }
}

/// `which`-style lookup honoring an explicit PATH.
public func findExecutable(_ name: String, path: String) -> String? {
    if name.contains("/") {
        return FileManager.default.isExecutableFile(atPath: name) ? name : nil
    }
    for dir in path.split(separator: ":") {
        let candidate = String(dir) + "/" + name
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}
