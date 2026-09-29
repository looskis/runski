import Foundation
import CryptoKit

/// Encrypts secrets at rest with a key that never leaves the Secure Enclave.
///
/// Design: the Secure Enclave only holds P-256 keys, so it cannot store an RSA
/// runner credential or an arbitrary secret string directly. Instead the vault
/// owns one Secure Enclave P-256 key-agreement key and uses it as a key-encryption
/// key: every secret is sealed with an ephemeral-static ECDH → HKDF-SHA256 →
/// AES-256-GCM construction (the same shape as Apple's ECIES `eciesEncryptionCofactorX963SHA256AESGCM`).
/// Decrypting a blob therefore requires this exact chip; copying `~/.runski` to
/// another machine yields nothing.
///
/// On hardware without a Secure Enclave (or in CI/VMs) the vault falls back to a
/// software P-256 key stored next to the sealed blobs and logs a warning. The blob
/// format is identical so the two modes are interchangeable for callers.
public final class Vault: @unchecked Sendable {
    public enum Backend: String, Codable, Sendable {
        case secureEnclave
        case software
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case corruptKeyFile
        case corruptBlob
        case wrongVersion(UInt8)
        public var description: String {
            switch self {
            case .corruptKeyFile: return "vault key file is corrupt"
            case .corruptBlob: return "sealed blob is corrupt"
            case .wrongVersion(let v): return "unsupported sealed blob version \(v)"
            }
        }
    }

    private struct KeyFile: Codable {
        var backend: Backend
        var key: Data
        var createdAt: Date
    }

    private enum Key {
        case enclave(SecureEnclave.P256.KeyAgreement.PrivateKey)
        case software(P256.KeyAgreement.PrivateKey)

        var publicKey: P256.KeyAgreement.PublicKey {
            switch self {
            case .enclave(let k): return k.publicKey
            case .software(let k): return k.publicKey
            }
        }

        func sharedSecret(with pub: P256.KeyAgreement.PublicKey) throws -> SharedSecret {
            switch self {
            case .enclave(let k): return try k.sharedSecretFromKeyAgreement(with: pub)
            case .software(let k): return try k.sharedSecretFromKeyAgreement(with: pub)
            }
        }
    }

    private static let blobVersion: UInt8 = 1
    private static let hkdfInfo = Data("runski.vault.v1".utf8)

    public let backend: Backend
    public let keyFileURL: URL
    private let key: Key

    /// Open the vault at `directory/vault.key`, creating a key if needed.
    /// `preferSecureEnclave: false` forces the software backend (tests).
    public init(directory: URL, preferSecureEnclave: Bool = true) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        keyFileURL = directory.appendingPathComponent("vault.key")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: keyFileURL) {
            guard let file = try? decoder.decode(KeyFile.self, from: data) else { throw Error.corruptKeyFile }
            switch file.backend {
            case .secureEnclave:
                guard SecureEnclave.isAvailable else { throw Error.corruptKeyFile }
                key = .enclave(try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: file.key))
            case .software:
                key = .software(try P256.KeyAgreement.PrivateKey(rawRepresentation: file.key))
            }
            backend = file.backend
            return
        }

        let file: KeyFile
        if preferSecureEnclave, SecureEnclave.isAvailable,
           let enclaveKey = try? SecureEnclave.P256.KeyAgreement.PrivateKey() {
            key = .enclave(enclaveKey)
            backend = .secureEnclave
            file = KeyFile(backend: .secureEnclave, key: enclaveKey.dataRepresentation, createdAt: Date())
        } else {
            let soft = P256.KeyAgreement.PrivateKey()
            key = .software(soft)
            backend = .software
            file = KeyFile(backend: .software, key: soft.rawRepresentation, createdAt: Date())
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        try data.write(to: keyFileURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFileURL.path)
    }

    public static var secureEnclaveAvailable: Bool { SecureEnclave.isAvailable }

    // MARK: - Seal / open

    /// Blob layout: `version(1) | ephemeralPublicKey(65, X9.63) | nonce(12) | ciphertext | tag(16)`.
    public func seal(_ plaintext: Data) throws -> Data {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: key.publicKey)
        let ephemeralPub = ephemeral.publicKey.x963Representation
        let symmetric = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeralPub,
                                                       sharedInfo: Vault.hkdfInfo, outputByteCount: 32)
        let sealed = try AES.GCM.seal(plaintext, using: symmetric)
        var blob = Data([Vault.blobVersion])
        blob.append(ephemeralPub)
        blob.append(sealed.nonce.withUnsafeBytes { Data($0) })
        blob.append(sealed.ciphertext)
        blob.append(sealed.tag)
        return blob
    }

    public func open(_ blob: Data) throws -> Data {
        guard blob.count >= 1 + 65 + 12 + 16 else { throw Error.corruptBlob }
        var cursor = blob.startIndex
        let version = blob[cursor]; cursor += 1
        guard version == Vault.blobVersion else { throw Error.wrongVersion(version) }
        let ephemeralPub = blob.subdata(in: cursor..<(cursor + 65)); cursor += 65
        let nonceData = blob.subdata(in: cursor..<(cursor + 12)); cursor += 12
        let tag = blob.subdata(in: (blob.endIndex - 16)..<blob.endIndex)
        let ciphertext = blob.subdata(in: cursor..<(blob.endIndex - 16))
        let pub = try P256.KeyAgreement.PublicKey(x963Representation: ephemeralPub)
        let shared = try key.sharedSecret(with: pub)
        let symmetric = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeralPub,
                                                       sharedInfo: Vault.hkdfInfo, outputByteCount: 32)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceData), ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: symmetric)
    }

    public func sealString(_ s: String) throws -> Data { try seal(Data(s.utf8)) }
    public func openString(_ blob: Data) throws -> String {
        String(decoding: try open(blob), as: UTF8.self)
    }

    public func seal<T: Encodable>(json value: T) throws -> Data {
        try seal(JSONEncoder().encode(value))
    }
    public func open<T: Decodable>(json blob: Data, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: try open(blob))
    }
}
