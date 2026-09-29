import Foundation

/// Where runski keeps everything: `~/.runski` by default (override with `RUNSKI_HOME`).
public struct Paths: Sendable {
    public let home: URL

    public init(home: URL? = nil) {
        if let home { self.home = home }
        else if let env = ProcessInfo.processInfo.environment["RUNSKI_HOME"] { self.home = URL(fileURLWithPath: env) }
        else { self.home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".runski") }
    }

    public var configFile: URL { home.appendingPathComponent("config.json") }
    public var runnersDir: URL { home.appendingPathComponent("runners") }
    public var logsDir: URL { home.appendingPathComponent("logs") }
    public var jobLogsDir: URL { logsDir.appendingPathComponent("jobs") }
    public var workDir: URL { home.appendingPathComponent("_work") }
    public var toolCacheDir: URL { home.appendingPathComponent("_tool") }
    public var externalsDir: URL { home.appendingPathComponent("externals") }
    public var actionsCacheDir: URL { home.appendingPathComponent("_actions") }
    public var stateDir: URL { home.appendingPathComponent("state") }

    public func runnerDir(_ name: String) -> URL { runnersDir.appendingPathComponent(name) }

    public func ensure() throws {
        for d in [home, runnersDir, logsDir, jobLogsDir, workDir, toolCacheDir, externalsDir, actionsCacheDir, stateDir] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
    }
}

/// Non-secret configuration of one registered runner (one GitHub runner = one job at a time).
public struct RunnerRecord: Codable, Sendable {
    public var name: String
    public var githubUrl: String              // https://github.com/owner/repo | /org | /enterprises/x
    public var agentId: Int64
    public var poolId: Int64
    public var poolName: String?
    public var serverUrl: String              // Actions tenant URL
    public var serverUrlV2: String?           // broker URL, when the service asked for the v2 flow
    public var useV2Flow: Bool
    public var useRunnerAdminFlow: Bool
    public var labels: [String]
    public var ephemeral: Bool
    public var registeredAt: Date
    public var runnerVersion: String

    public var apiBase: URL { GitHubAPI.apiBase(for: githubUrl) }
}

/// Sealed by the vault: everything needed to mint access tokens.
public struct RunnerCredentials: Codable, Sendable {
    public var clientId: String
    public var authorizationUrl: String
    public var requireFipsCryptography: Bool
    public var rsaPrivateKeyPKCS1: Data
}

/// Global daemon configuration (`~/.runski/config.json`).
public struct RunskiConfig: Codable, Sendable {
    public struct LogSink: Codable, Sendable {
        public var url: String
        public var headers: [String: String]?
        public var batchLines: Int?
        public var flushIntervalSeconds: Double?
        public init(url: String, headers: [String: String]? = nil, batchLines: Int? = nil, flushIntervalSeconds: Double? = nil) {
            self.url = url; self.headers = headers; self.batchLines = batchLines; self.flushIntervalSeconds = flushIntervalSeconds
        }
    }
    public struct Idle: Codable, Sendable {
        /// Only accept jobs when nobody has touched the keyboard/mouse for this long. 0 disables.
        public var requiredIdleSeconds: Double = 0
        /// Keep running a job once it has started even if the user comes back.
        public var finishRunningJobs: Bool = true
    }

    public var slots: Int = 1
    public var idle: Idle = Idle()
    public var logSink: LogSink? = nil
    public var preventSleepDuringJobs: Bool = true
    public var exposeLocalSecrets: Bool = true
    public var nodePath: String? = nil
    public var extraPath: [String] = []
    public var trace: Bool = false
    public var keepJobLogs: Int = 200
    /// Grace period between SIGINT and SIGTERM when cancelling a step's process tree.
    public var cancelGraceSeconds: Double = 7.5

    public init() {}

    public static func load(_ paths: Paths) -> RunskiConfig {
        guard let data = try? Data(contentsOf: paths.configFile),
              let cfg = try? JSONDecoder().decode(RunskiConfig.self, from: data) else { return RunskiConfig() }
        return cfg
    }

    public func save(_ paths: Paths) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: paths.configFile, options: .atomic)
    }
}

/// Loads and stores runner records + sealed credentials.
public final class RunnerStore: @unchecked Sendable {
    public let paths: Paths
    public let vault: Vault

    public init(paths: Paths, vault: Vault) {
        self.paths = paths
        self.vault = vault
    }

    public func list() -> [RunnerRecord] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: paths.runnersDir.path) else { return [] }
        return names.sorted().compactMap { load($0) }
    }

    public func load(_ name: String) -> RunnerRecord? {
        let url = paths.runnerDir(name).appendingPathComponent("runner.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(RunnerRecord.self, from: data)
    }

    public func save(_ record: RunnerRecord, credentials: RunnerCredentials) throws {
        let dir = paths.runnerDir(record.name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(record).write(to: dir.appendingPathComponent("runner.json"), options: .atomic)
        let sealed = try vault.seal(json: credentials)
        let credURL = dir.appendingPathComponent("credentials.sealed")
        try sealed.write(to: credURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credURL.path)
    }

    public func credentials(for name: String) throws -> RunnerCredentials {
        let blob = try Data(contentsOf: paths.runnerDir(name).appendingPathComponent("credentials.sealed"))
        return try vault.open(json: blob)
    }

    public func remove(_ name: String) throws {
        let dir = paths.runnerDir(name)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }
}
