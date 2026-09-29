import Foundation
import Yams

/// Parsed `action.yml`.
public struct ActionManifest {
    public enum Runtime {
        case node(version: String, main: String, pre: String?, preIf: String?, post: String?, postIf: String?)
        case composite(steps: [TemplateToken])
        case docker
    }
    public struct Input {
        public var description: String?
        public var required: Bool
        public var defaultValue: TemplateToken?
        public var deprecationMessage: String?
    }

    public var name: String?
    public var description: String?
    public var inputs: [(String, Input)]
    public var outputs: [(String, TemplateToken?)]   // composite: outputs.<id>.value
    public var runs: Runtime
    public var directory: String

    public static func load(directory: String) throws -> ActionManifest {
        let candidates = ["action.yml", "action.yaml"]
        for c in candidates {
            let p = directory + "/" + c
            if FileManager.default.fileExists(atPath: p) {
                return try parse(String(contentsOfFile: p, encoding: .utf8), directory: directory)
            }
        }
        if FileManager.default.fileExists(atPath: directory + "/Dockerfile") || FileManager.default.fileExists(atPath: directory + "/dockerfile") {
            return ActionManifest(name: nil, description: nil, inputs: [], outputs: [], runs: .docker, directory: directory)
        }
        throw WorkerError("Can't find 'action.yml', 'action.yaml' or 'Dockerfile' under '\(directory)'. Did you forget to run actions/checkout before running your local action?")
    }

    public static func parse(_ yaml: String, directory: String) throws -> ActionManifest {
        guard let root = try Yams.load(yaml: yaml) as? [String: Any] else { throw WorkerError("action.yml is not a mapping") }
        var inputs: [(String, Input)] = []
        if let ins = root["inputs"] as? [String: Any] {
            for k in ins.keys.sorted() {
                let spec = ins[k] as? [String: Any] ?? [:]
                let def = try spec["default"].map { try TemplateEvaluator.token(fromYAML: $0) }
                inputs.append((k, Input(description: spec["description"] as? String, required: (spec["required"] as? Bool) ?? false,
                                        defaultValue: def, deprecationMessage: spec["deprecationMessage"] as? String)))
            }
        }
        var outputs: [(String, TemplateToken?)] = []
        if let outs = root["outputs"] as? [String: Any] {
            for k in outs.keys.sorted() {
                let spec = outs[k] as? [String: Any] ?? [:]
                outputs.append((k, try spec["value"].map { try TemplateEvaluator.token(fromYAML: $0) }))
            }
        }
        guard let runs = root["runs"] as? [String: Any], let using = (runs["using"] as? String)?.lowercased() else {
            throw WorkerError("action.yml is missing 'runs.using'")
        }
        let runtime: Runtime
        switch using {
        case "node12", "node16", "node20", "node24":
            guard let main = runs["main"] as? String else { throw WorkerError("action.yml 'runs.main' is required for \(using)") }
            let version = (using == "node12" || using == "node16") ? "node20" : using
            runtime = .node(version: version, main: main, pre: runs["pre"] as? String, preIf: runs["pre-if"] as? String,
                            post: runs["post"] as? String, postIf: runs["post-if"] as? String)
        case "composite":
            guard let steps = runs["steps"] as? [Any] else { throw WorkerError("action.yml 'runs.steps' is required for composite") }
            runtime = .composite(steps: try steps.map { try TemplateEvaluator.token(fromYAML: $0) })
        case "docker":
            runtime = .docker
        default:
            throw WorkerError("'using: \(using)' is not supported, use 'docker', 'node12', 'node16', 'node20' or 'node24' instead.")
        }
        return ActionManifest(name: root["name"] as? String, description: root["description"] as? String,
                              inputs: inputs, outputs: outputs, runs: runtime, directory: directory)
    }
}

public struct WorkerError: Error, CustomStringConvertible {
    public let message: String
    public init(_ m: String) { message = m }
    public var description: String { message }
}

/// Resolves and downloads repository actions into the shared action cache.
public final class ActionManager: @unchecked Sendable {
    public struct Resolved: Sendable {
        public var nameWithOwner: String
        public var ref: String
        public var sha: String?
        public var tarballUrl: String
        public var token: String?
    }

    let message: AgentJobRequestMessage
    let paths: Paths
    let http: HTTPClient
    let log: Logger
    let masker: SecretMasker
    let githubToken: String?
    let githubUrl: String

    public init(message: AgentJobRequestMessage, paths: Paths, http: HTTPClient, log: Logger, masker: SecretMasker, githubUrl: String) {
        self.message = message; self.paths = paths; self.http = http; self.log = log; self.masker = masker; self.githubUrl = githubUrl
        githubToken = message.variable("system.github.token")
    }

    /// Cache directory for `owner/repo@ref`.
    public func actionDirectory(nameWithOwner: String, ref: String) -> String {
        paths.actionsCacheDir.appendingPathComponent(nameWithOwner).appendingPathComponent(ref.replacingOccurrences(of: "/", with: "_")).path
    }

    /// Resolve download info for a set of actions, preferring the launch service, then the
    /// legacy VSS endpoint, then a direct api.github.com tarball URL with the job token.
    public func resolve(_ refs: [(nameWithOwner: String, ref: String)], progress: (String) -> Void) async -> [String: Resolved] {
        var out: [String: Resolved] = [:]
        let unique = Dictionary(grouping: refs, by: { "\($0.nameWithOwner)@\($0.ref)" }).compactMapValues(\.first)
        guard !unique.isEmpty else { return out }
        let token = message.systemConnection?.authorization?.parameters?["AccessToken"]

        if let launch = message.variable("system.github.launch_endpoint"), let base = URL(string: launch), let token {
            do {
                let u = base.appendingPathComponent("actions/build/\(message.plan.planId)/jobs/\(message.jobId)/runnerresolve/actions")
                let body: [String: Any] = ["actions": unique.values.map { ["action": $0.nameWithOwner, "version": $0.ref, "path": ""] }]
                let data = try JSONSerialization.data(withJSONObject: body)
                let resp = try await http.send("POST", u, headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json; charset=utf-8", "Accept": "application/json"], body: data, timeout: 60)
                if let obj = try JSONSerialization.jsonObject(with: resp.data) as? [String: Any], let actions = obj["actions"] as? [String: Any] {
                    for (key, val) in actions {
                        guard let v = val as? [String: Any], let tar = v["tar_url"] as? String else { continue }
                        let auth = v["authentication"] as? [String: Any]
                        let t = auth?["token"] as? String
                        if let t { masker.add(t) }
                        let parts = key.split(separator: "@", maxSplits: 1).map(String.init)
                        out[key] = Resolved(nameWithOwner: (v["name"] as? String) ?? parts[0], ref: (v["version"] as? String) ?? (parts.count > 1 ? parts[1] : ""),
                                            sha: v["resolved_sha"] as? String, tarballUrl: tar, token: t)
                    }
                }
                progress("Resolved \(out.count) action(s) via launch service")
            } catch {
                log.warn("launch service resolution failed: \(error)")
            }
        }

        let missing = unique.filter { out[$0.key] == nil }
        if !missing.isEmpty, let sc = message.systemConnection, let u = URL(string: sc.url), let token, message.messageType != MessageType.runnerJobRequest {
            let legacy = LegacyJobServer(endpoint: u, token: token, plan: message.plan, http: http)
            do {
                let list = missing.values.map { ActionReference(nameWithOwner: $0.nameWithOwner, ref: $0.ref, path: nil) }
                if let coll = try await legacy.resolveActionDownloadInfo(jobId: message.jobId, actions: list) {
                    for (key, info) in coll.actions {
                        guard let tar = info.tarballUrl else { continue }
                        if let t = info.authentication?.token { masker.add(t) }
                        out[key] = Resolved(nameWithOwner: info.nameWithOwner, ref: info.ref ?? "", sha: info.resolvedSha, tarballUrl: tar, token: info.authentication?.token)
                    }
                }
            } catch {
                log.warn("legacy action resolution failed: \(error)")
            }
        }

        for (key, r) in unique where out[key] == nil {
            let api = GitHubAPI.apiBase(for: githubUrl)
            let u = GitHubAPI.url(api, "repos/\(r.nameWithOwner)/tarball/\(r.ref)")
            out[key] = Resolved(nameWithOwner: r.nameWithOwner, ref: r.ref, sha: nil, tarballUrl: u.absoluteString, token: githubToken)
        }
        return out
    }

    /// Download (if not cached) and return the action root directory.
    public func download(_ r: Resolved, progress: (String) -> Void) async throws -> String {
        let dest = actionDirectory(nameWithOwner: r.nameWithOwner, ref: r.ref)
        let marker = dest + ".completed"
        if let existing = try? String(contentsOfFile: marker, encoding: .utf8), FileManager.default.fileExists(atPath: dest) {
            // Cache hit if the sha matches (or we have no sha to compare and the ref looks immutable).
            if let sha = r.sha, existing.trimmingCharacters(in: .whitespacesAndNewlines) == sha {
                progress("Using cached action '\(r.nameWithOwner)@\(r.ref)' (SHA:\(sha))")
                return dest
            }
            if r.sha == nil, r.ref.count == 40 {
                return dest
            }
        }
        progress("Download action repository '\(r.nameWithOwner)@\(r.ref)'\(r.sha.map { " (SHA:\($0))" } ?? "")")
        guard let url = URL(string: r.tarballUrl) else { throw WorkerError("bad tarball url \(r.tarballUrl)") }
        var headers: [String: String] = ["Accept": "application/vnd.github+json"]
        if let t = r.token ?? githubToken {
            let host = url.host ?? ""
            if host.hasPrefix("codeload.") || url.path.hasPrefix("/_codeload/") || host.hasSuffix("githubusercontent.com") {
                headers["Authorization"] = "Bearer \(t)"
            } else {
                headers["Authorization"] = "Basic \(Data("x-access-token:\(t)".utf8).base64EncodedString())"
            }
        }
        var lastError: Error?
        var data: Data?
        for attempt in 0..<3 {
            do {
                data = try await http.send("GET", url, headers: headers, timeout: 1200).data
                break
            } catch let e as HTTPError where e.status == 404 {
                throw WorkerError("Action '\(r.nameWithOwner)@\(r.ref)' not found (404). Check the name and ref, or whether the token can access it.")
            } catch {
                lastError = error
                try await Task.sleep(for: .seconds(Double(attempt + 1) * 5))
            }
        }
        guard let data else { throw lastError ?? WorkerError("download failed") }

        let temp = paths.actionsCacheDir.appendingPathComponent("_temp_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let staging = temp.appendingPathComponent("_staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let archive = temp.appendingPathComponent("action.tar.gz")
        try data.write(to: archive)
        let tar = ProcessRunner(executable: "/usr/bin/tar", arguments: ["-xzf", archive.path], environment: ProcessInfo.processInfo.environment, workingDirectory: staging.path)
        let res = try await tar.run(timeout: 600) { _, _ in }
        guard res.exitCode == 0 else { throw WorkerError("tar failed with exit code \(res.exitCode) extracting \(r.nameWithOwner)@\(r.ref)") }
        let entries = try FileManager.default.contentsOfDirectory(atPath: staging.path).filter { $0 != "pax_global_header" }
        guard entries.count == 1 else { throw WorkerError("unexpected archive layout for \(r.nameWithOwner)@\(r.ref): \(entries)") }
        if FileManager.default.fileExists(atPath: dest) { try FileManager.default.removeItem(atPath: dest) }
        try FileManager.default.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: staging.appendingPathComponent(entries[0]).path, toPath: dest)
        try (r.sha ?? "").write(toFile: marker, atomically: true, encoding: .utf8)
        return dest
    }
}

/// Locates (or downloads) a Node.js runtime for JavaScript actions.
public struct NodeProvider {
    public static let defaultVersions = ["node20": "20.20.2", "node24": "24.21.0"]

    let paths: Paths
    let config: RunskiConfig
    let http: HTTPClient
    let log: Logger

    public init(paths: Paths, config: RunskiConfig, http: HTTPClient, log: Logger) {
        self.paths = paths; self.config = config; self.http = http; self.log = log
    }

    public func node(for version: String, searchPath: String, progress: (String) -> Void) async throws -> String {
        let bundled = paths.externalsDir.appendingPathComponent(version).appendingPathComponent("bin/node").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        if let configured = config.nodePath, FileManager.default.isExecutableFile(atPath: configured) { return configured }
        if let found = findExecutable("node", path: searchPath) {
            // Accept a system node if its major version is compatible.
            let major = version.replacingOccurrences(of: "node", with: "")
            if let v = try? await nodeMajor(found), String(v) == major || v > (Int(major) ?? 0) { return found }
        }
        guard let ver = NodeProvider.defaultVersions[version] else { throw WorkerError("unsupported node runtime \(version)") }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x64"
        #endif
        let name = "node-v\(ver)-darwin-\(arch)"
        let url = URL(string: "https://nodejs.org/dist/v\(ver)/\(name).tar.gz")!
        progress("Downloading Node.js v\(ver) for JavaScript actions (\(url))")
        let data = try await http.send("GET", url, timeout: 1200).data
        let temp = paths.externalsDir.appendingPathComponent("_temp_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try data.write(to: temp.appendingPathComponent("node.tar.gz"))
        let tar = ProcessRunner(executable: "/usr/bin/tar", arguments: ["-xzf", "node.tar.gz"], environment: ProcessInfo.processInfo.environment, workingDirectory: temp.path)
        let res = try await tar.run(timeout: 600) { _, _ in }
        guard res.exitCode == 0 else { throw WorkerError("failed to extract node archive") }
        let dest = paths.externalsDir.appendingPathComponent(version)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.moveItem(at: temp.appendingPathComponent(name), to: dest)
        return bundled
    }

    private func nodeMajor(_ path: String) async throws -> Int {
        let p = ProcessRunner(executable: path, arguments: ["--version"], environment: ProcessInfo.processInfo.environment, workingDirectory: "/")
        final class Box: @unchecked Sendable { var out = "" }
        let box = Box()
        _ = try await p.run(timeout: 10) { isErr, line in if !isErr { box.out += line } }
        let digits = box.out.drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits) ?? 0
    }
}
