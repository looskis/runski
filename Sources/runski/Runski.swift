import Foundation
import ArgumentParser
import RunskiCore

@main
struct Runski: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runski",
        abstract: "Turn an idle Mac into a GitHub Actions runner.",
        discussion: """
        runski speaks GitHub's own runner protocol, so your existing workflows work
        unchanged: point `runs-on` at your Mac's labels and jobs start flowing.
        Credentials and local secrets are sealed with the Secure Enclave.
        """,
        version: RunskiVersion.current,
        subcommands: [Register.self, Remove.self, Run.self, Daemon.self, Secrets.self, Status.self, Config.self, Logs.self],
        defaultSubcommand: Status.self)
}

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Data directory (default ~/.runski, or $RUNSKI_HOME).")
    var home: String?

    @Flag(name: .long, help: "Verbose HTTP tracing.")
    var trace = false

    var paths: Paths { Paths(home: home.map { URL(fileURLWithPath: $0) }) }

    func environment() throws -> (Paths, RunskiConfig, Vault, RunnerStore, SecretStore, Logger) {
        let p = paths
        try p.ensure()
        var cfg = RunskiConfig.load(p)
        if trace { cfg.trace = true }
        let logger = Logger(level: cfg.trace ? .debug : .info, fileURL: p.logsDir.appendingPathComponent("runski.log"))
        let vault = try Vault(directory: p.home)
        if vault.backend == .software {
            logger.warn("Secure Enclave unavailable on this machine; using a software key for the vault")
        }
        let store = RunnerStore(paths: p, vault: vault)
        let secrets = SecretStore(vault: vault, directory: p.home)
        return (p, cfg, vault, store, secrets, logger)
    }
}

extension Runski {
    struct Register: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Register this Mac as a runner for a repository, organization or enterprise.")
        @OptionGroup var global: GlobalOptions
        @Option(name: .long, help: "https://github.com/owner/repo, https://github.com/org or https://github.com/enterprises/name")
        var url: String
        @Option(name: .long, help: "Registration token from Settings → Actions → Runners → New self-hosted runner.")
        var token: String?
        @Option(name: .long, help: "Personal access token used to mint a registration token (needs repo admin / org manage_runners).")
        var pat: String?
        @Option(name: .long, help: "Runner name (default: hostname).")
        var name: String?
        @Option(name: .long, help: "Extra labels, comma-separated (self-hosted, macOS, ARM64/X64 and runski are always added).")
        var labels: String = ""
        @Option(name: .long, help: "Runner group (default: the default group).")
        var group: String?
        @Option(name: .long, help: "Number of concurrent job slots. Each slot registers as <name>, <name>-2, …")
        var slots: Int = 1
        @Flag(name: .long, help: "Take over an existing runner with the same name.")
        var replace = false
        @Flag(name: .long, help: "Register as an ephemeral runner (removed after one job).")
        var ephemeral = false

        func run() async throws {
            let (paths, cfg, _, store, _, log) = try global.environment()
            _ = try GitHubAPI.scope(for: url)   // validate before touching the network
            let http = HTTPClient()
            if cfg.trace { http.trace = { log.debug($0) } }
            var regToken = token
            if regToken == nil, let pat {
                regToken = try await GitHubAPI.runnerToken(kind: "registration", githubUrl: url, pat: pat, http: http)
            }
            guard let regToken else { throw ValidationError("pass --token (registration token) or --pat") }
            let base = name ?? Platform.hostName.replacingOccurrences(of: " ", with: "-").lowercased()
            let registrar = Registrar(http: http) { log.info($0) }
            let extra = labels.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            for i in 0..<max(1, slots) {
                let runnerName = i == 0 ? base : "\(base)-\(i + 1)"
                var opts = Registrar.Options(githubUrl: url, name: runnerName, labels: extra)
                opts.runnerGroup = group; opts.replace = replace; opts.ephemeral = ephemeral
                let (record, creds) = try await registrar.register(opts, registrationToken: regToken)
                try store.save(record, credentials: creds)
                print("✓ registered '\(record.name)' (id \(record.agentId), \(record.useV2Flow ? "broker" : "pipelines") flow) with labels: \(record.labels.joined(separator: ", "))")
            }
            var c = RunskiConfig.load(paths); c.slots = max(c.slots, slots); try c.save(paths)
            print("""

            Credentials sealed in \(paths.home.path) (vault: \(store.vault.backend.rawValue)).
            Next: `runski daemon install` to run at login, or `runski run` to run in the foreground.
            In your workflows: runs-on: [self-hosted, runski]
            """)
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Unregister runner(s) from GitHub and delete local credentials.")
        @OptionGroup var global: GlobalOptions
        @Option(name: .long, help: "Runner name (default: all).") var name: String?
        @Option(name: .long, help: "Removal token from GitHub, or use --pat.") var token: String?
        @Option(name: .long) var pat: String?
        @Flag(name: .long, help: "Delete local files even if GitHub removal fails.") var force = false

        func run() async throws {
            let (_, cfg, _, store, _, log) = try global.environment()
            let http = HTTPClient()
            if cfg.trace { http.trace = { log.debug($0) } }
            let registrar = Registrar(http: http) { log.info($0) }
            let records = store.list().filter { name == nil || $0.name == name }
            guard !records.isEmpty else { print("no matching runners"); return }
            for r in records {
                var t = token
                if t == nil, let pat { t = try await GitHubAPI.runnerToken(kind: "remove", githubUrl: r.githubUrl, pat: pat, http: http) }
                do {
                    guard let t else { throw ValidationError("pass --token (removal token) or --pat") }
                    try await registrar.remove(r, removeToken: t)
                    print("✓ removed '\(r.name)' from GitHub")
                } catch {
                    print("✗ could not remove '\(r.name)' from GitHub: \(error)")
                    if !force { continue }
                }
                try store.remove(r.name)
                print("  deleted local credentials for '\(r.name)'")
            }
        }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run the runner in the foreground (what the daemon executes).")
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            let (paths, cfg, _, store, secrets, log) = try global.environment()
            let daemon = RunnerDaemon(paths: paths, config: cfg, store: store, secrets: secrets, log: log)
            let task = Task { try await daemon.run() }
            let signals = SignalWatcher([SIGINT, SIGTERM]) {
                log.info("shutting down…")
                Task { await daemon.shutdown(); task.cancel() }
            }
            defer { signals.cancel() }
            do { try await task.value } catch is CancellationError {}
        }
    }

    struct Daemon: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Manage the launchd agent (starts at login, restarts on crash).",
                                                        subcommands: [Install.self, Uninstall.self, Restart.self, DaemonStatus.self])

        struct Install: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Install and start the LaunchAgent.")
            @OptionGroup var global: GlobalOptions
            func run() throws {
                let (paths, _, _, store, _, _) = try global.environment()
                guard !store.list().isEmpty else { throw ValidationError("register a runner first (runski register …)") }
                let resolved = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path
                try Launchd(paths: paths).install(executable: resolved)
                print("✓ installed \(Launchd.label) → \(resolved)\n  logs: \(paths.logsDir.path)")
            }
        }
        struct Uninstall: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Stop and remove the LaunchAgent.")
            @OptionGroup var global: GlobalOptions
            func run() throws { try Launchd(paths: global.paths).uninstall(); print("✓ uninstalled \(Launchd.label)") }
        }
        struct Restart: ParsableCommand {
            @OptionGroup var global: GlobalOptions
            func run() throws { try Launchd(paths: global.paths).restart(); print("✓ restarted") }
        }
        struct DaemonStatus: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "status")
            @OptionGroup var global: GlobalOptions
            func run() throws {
                let l = Launchd(paths: global.paths)
                print("installed: \(l.isInstalled)  launchd: \(l.status)")
            }
        }
    }

    struct Secrets: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Local secrets sealed by the Secure Enclave and exposed to jobs as environment variables.",
                                                        subcommands: [Set.self, List.self, RemoveSecret.self])
        struct Set: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Store a secret (value read from stdin or --value).")
            @OptionGroup var global: GlobalOptions
            @Argument var name: String
            @Option(name: .long, help: "Secret value (prefer piping via stdin).") var value: String?
            func run() throws {
                guard SecretStore.validate(name: name) else { throw ValidationError("secret names must match [A-Za-z_][A-Za-z0-9_]*") }
                let (_, _, vault, _, secrets, _) = try global.environment()
                var v = value
                if v == nil {
                    if isatty(STDIN_FILENO) != 0 { FileHandle.standardError.write(Data("value for \(name): ".utf8)) }
                    v = readLine(strippingNewline: true)
                }
                guard let v, !v.isEmpty else { throw ValidationError("empty value") }
                try secrets.set(name, value: v)
                print("✓ sealed \(name) with \(vault.backend.rawValue) key")
            }
        }
        struct List: ParsableCommand {
            @OptionGroup var global: GlobalOptions
            func run() throws {
                let (_, _, _, _, secrets, _) = try global.environment()
                let names = secrets.names()
                print(names.isEmpty ? "(no local secrets)" : names.joined(separator: "\n"))
            }
        }
        struct RemoveSecret: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "remove")
            @OptionGroup var global: GlobalOptions
            @Argument var name: String
            func run() throws {
                let (_, _, _, _, secrets, _) = try global.environment()
                try secrets.remove(name); print("✓ removed \(name)")
            }
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show registered runners, vault backend and daemon state.")
        @OptionGroup var global: GlobalOptions
        func run() throws {
            let (paths, cfg, vault, store, secrets, _) = try global.environment()
            print("runski \(RunskiVersion.current)  home: \(paths.home.path)")
            print("vault: \(vault.backend.rawValue)\(Vault.secureEnclaveAvailable ? "" : " (no Secure Enclave on this Mac)")  local secrets: \(secrets.names().count)")
            print("daemon: \(Launchd(paths: paths).status)  idle gate: \(cfg.idle.requiredIdleSeconds > 0 ? "\(Int(cfg.idle.requiredIdleSeconds))s" : "off")  idle now: \(Int(HostPower.idleSeconds()))s")
            let runners = store.list()
            if runners.isEmpty { print("runners: none (run `runski register`)"); return }
            print("runners:")
            for r in runners {
                print("  \(r.name)  id=\(r.agentId)  \(r.githubUrl)  [\(r.labels.joined(separator: ", "))]  \(r.useV2Flow ? "broker" : "pipelines")")
            }
        }
    }

    struct Config: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show or change daemon configuration (~/.runski/config.json).")
        @OptionGroup var global: GlobalOptions
        @Option(name: .long, help: "Only accept jobs after this many seconds of no user input (0 = always).") var idleSeconds: Double?
        @Option(name: .long, help: "POST batched log lines to this URL as JSON.") var logSink: String?
        @Option(name: .long, help: "Header for the log sink, e.g. 'Authorization: Bearer x' (repeatable).") var logSinkHeader: [String] = []
        @Flag(name: .long, inversion: .prefixedNo, help: "Prevent idle sleep while a job runs.") var preventSleep: Bool?
        @Flag(name: .long, inversion: .prefixedNo, help: "Expose local secrets to jobs as environment variables.") var localSecrets: Bool?
        @Option(name: .long, help: "Path to a node binary for JavaScript actions.") var node: String?
        @Flag(name: .long) var clearLogSink = false

        func run() throws {
            let (paths, _, _, _, _, _) = try global.environment()
            var cfg = RunskiConfig.load(paths)
            if let idleSeconds { cfg.idle.requiredIdleSeconds = idleSeconds }
            if let preventSleep { cfg.preventSleepDuringJobs = preventSleep }
            if let localSecrets { cfg.exposeLocalSecrets = localSecrets }
            if let node { cfg.nodePath = node }
            if clearLogSink { cfg.logSink = nil }
            if let logSink {
                var headers: [String: String] = [:]
                for h in logSinkHeader {
                    let kv = h.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if kv.count == 2 { headers[kv[0]] = kv[1] }
                }
                cfg.logSink = RunskiConfig.LogSink(url: logSink, headers: headers, batchLines: 200, flushIntervalSeconds: 2)
            }
            try cfg.save(paths)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try enc.encode(cfg), as: UTF8.self))
        }
    }

    struct Logs: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show where logs live and tail the daemon log.")
        @OptionGroup var global: GlobalOptions
        @Option(name: .shortAndLong) var lines: Int = 50
        func run() throws {
            let paths = global.paths
            print("daemon log: \(paths.logsDir.appendingPathComponent("runski.log").path)")
            print("job logs:   \(paths.jobLogsDir.path)")
            if let data = FileManager.default.contents(atPath: paths.logsDir.appendingPathComponent("runski.log").path) {
                let all = String(decoding: data, as: UTF8.self).split(separator: "\n")
                print("---")
                for l in all.suffix(lines) { print(l) }
            }
        }
    }
}

/// Dispatch-source based signal handling that works with Swift concurrency.
final class SignalWatcher {
    private var sources: [DispatchSourceSignal] = []
    init(_ signals: [Int32], handler: @escaping () -> Void) {
        for s in signals {
            signal(s, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
            src.setEventHandler(handler: handler)
            src.resume()
            sources.append(src)
        }
    }
    func cancel() { sources.forEach { $0.cancel() } }
}

