import Foundation

/// Installs runski as a per-user LaunchAgent so it starts at login and is
/// restarted by launchd if it ever crashes (`KeepAlive`).
public struct Launchd {
    public static let label = "dev.runski.agent"

    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    public var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(Launchd.label).plist")
    }

    public func plist(executable: String) -> String {
        let out = paths.logsDir.appendingPathComponent("daemon.out.log").path
        let err = paths.logsDir.appendingPathComponent("daemon.err.log").path
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(Launchd.label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executable)</string>
                <string>run</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key><false/>
                <key>Crashed</key><true/>
            </dict>
            <key>ThrottleInterval</key><integer>10</integer>
            <key>ProcessType</key><string>Standard</string>
            <key>LowPriorityIO</key><false/>
            <key>StandardOutPath</key><string>\(out)</string>
            <key>StandardErrorPath</key><string>\(err)</string>
            <key>EnvironmentVariables</key>
            <dict>
                <key>RUNSKI_HOME</key><string>\(paths.home.path)</string>
                <key>PATH</key><string>/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
            </dict>
        </dict>
        </plist>
        """
    }

    @discardableResult
    private func launchctl(_ args: [String]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (p.terminationStatus, out)
    }

    private var domain: String { "gui/\(getuid())" }

    public func install(executable: String) throws {
        try paths.ensure()
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if isLoaded { _ = try? launchctl(["bootout", domain, plistURL.path]) }
        try plist(executable: executable).write(to: plistURL, atomically: true, encoding: .utf8)
        let (code, out) = try launchctl(["bootstrap", domain, plistURL.path])
        guard code == 0 else { throw WorkerError("launchctl bootstrap failed (\(code)): \(out)") }
        _ = try? launchctl(["kickstart", "-k", "\(domain)/\(Launchd.label)"])
    }

    public func uninstall() throws {
        if isLoaded { _ = try? launchctl(["bootout", domain, plistURL.path]) }
        if FileManager.default.fileExists(atPath: plistURL.path) { try FileManager.default.removeItem(at: plistURL) }
    }

    public func restart() throws {
        let (code, out) = try launchctl(["kickstart", "-k", "\(domain)/\(Launchd.label)"])
        guard code == 0 else { throw WorkerError("launchctl kickstart failed (\(code)): \(out)") }
    }

    public var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    public var isLoaded: Bool {
        guard let (code, _) = try? launchctl(["print", "\(domain)/\(Launchd.label)"]) else { return false }
        return code == 0
    }

    public var status: String {
        guard let (code, out) = try? launchctl(["print", "\(domain)/\(Launchd.label)"]), code == 0 else { return "not loaded" }
        var pid = "-"
        var state = "unknown"
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("pid = ") { pid = String(t.dropFirst(6)) }
            if t.hasPrefix("state = ") { state = String(t.dropFirst(8)) }
        }
        return "\(state) (pid \(pid))"
    }
}
