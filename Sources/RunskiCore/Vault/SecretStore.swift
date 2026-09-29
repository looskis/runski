import Foundation

/// Local, device-bound secrets exposed to jobs as environment variables.
///
/// Unlike GitHub repository secrets, these never leave the Mac: they are sealed
/// by ``Vault`` and injected into each step's environment at run time, so a
/// workflow can use `$SIGNING_PASSWORD` without the value ever being uploaded.
public final class SecretStore: @unchecked Sendable {
    private struct File: Codable {
        var secrets: [String: Data] = [:]
    }

    private let vault: Vault
    private let fileURL: URL
    private let lock = NSLock()

    public init(vault: Vault, directory: URL) {
        self.vault = vault
        self.fileURL = directory.appendingPathComponent("secrets.json")
    }

    private func load() -> File {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return File() }
        return file
    }

    private func save(_ file: File) throws {
        let data = try JSONEncoder().encode(file)
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public static func validate(name: String) -> Bool {
        let pattern = "^[A-Za-z_][A-Za-z0-9_]*$"
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    public func set(_ name: String, value: String) throws {
        lock.lock(); defer { lock.unlock() }
        var file = load()
        file.secrets[name] = try vault.sealString(value)
        try save(file)
    }

    public func remove(_ name: String) throws {
        lock.lock(); defer { lock.unlock() }
        var file = load()
        file.secrets.removeValue(forKey: name)
        try save(file)
    }

    public func names() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return load().secrets.keys.sorted()
    }

    /// Decrypt every secret. Values are returned in memory only.
    public func all() throws -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: String] = [:]
        for (k, blob) in load().secrets {
            out[k] = try vault.openString(blob)
        }
        return out
    }
}
