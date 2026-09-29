import Foundation

/// Daemon logger: stderr + rotating file under `~/.runski/logs/runski.log`.
public final class Logger: @unchecked Sendable {
    public enum Level: Int, Comparable, Sendable {
        case debug = 0, info, warn, error
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        var tag: String {
            switch self {
            case .debug: return "DBG"
            case .info: return "INF"
            case .warn: return "WRN"
            case .error: return "ERR"
            }
        }
    }

    public var level: Level
    public let prefix: String
    private let file: FileHandle?
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(level: Level = .info, prefix: String = "", fileURL: URL? = nil) {
        self.level = level
        self.prefix = prefix
        if let fileURL {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            file = try? FileHandle(forWritingTo: fileURL)
            file?.seekToEndOfFile()
        } else {
            file = nil
        }
    }

    public func child(_ prefix: String) -> Logger {
        let l = Logger(level: level, prefix: self.prefix.isEmpty ? prefix : "\(self.prefix) \(prefix)", fileURL: nil)
        l.parent = self
        return l
    }
    private var parent: Logger?

    public func log(_ lvl: Level, _ msg: String) {
        guard lvl >= level else { return }
        if let parent { parent.write(lvl, prefix: prefix, msg); return }
        write(lvl, prefix: prefix, msg)
    }

    private func write(_ lvl: Level, prefix: String, _ msg: String) {
        let line = "\(formatter.string(from: Date())) \(lvl.tag) \(prefix.isEmpty ? "" : "[\(prefix)] ")\(msg)\n"
        lock.lock(); defer { lock.unlock() }
        FileHandle.standardError.write(Data(line.utf8))
        file?.write(Data(line.utf8))
    }

    public func debug(_ m: String) { log(.debug, m) }
    public func info(_ m: String) { log(.info, m) }
    public func warn(_ m: String) { log(.warn, m) }
    public func error(_ m: String) { log(.error, m) }
}
