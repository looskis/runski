import Foundation
import Security

/// RSA-2048 key pair backed by Security.framework.
///
/// The GitHub Actions service authenticates a runner with an RSA key: the public
/// key (modulus + exponent) is uploaded at registration time, and every access
/// token is obtained by presenting a JWT signed with the private key (RS256 for the
/// legacy flow, PS256 when the service requests FIPS crypto or when the runner was
/// registered through the v2 flow). The session AES key that encrypts every job
/// message is wrapped with RSA-OAEP for this same key.
///
/// Secure Enclave cannot hold RSA keys, so the PKCS#1 private key bytes are sealed
/// by ``Vault`` at rest and only unwrapped into memory while the runner is running.
public struct RSAKey: @unchecked Sendable {
    public enum Error: Swift.Error, CustomStringConvertible {
        case generation(String)
        case importFailed(String)
        case exportFailed(String)
        case signing(String)
        case decryption(String)
        case malformedPublicKey

        public var description: String {
            switch self {
            case .generation(let s): return "RSA key generation failed: \(s)"
            case .importFailed(let s): return "RSA key import failed: \(s)"
            case .exportFailed(let s): return "RSA key export failed: \(s)"
            case .signing(let s): return "RSA signing failed: \(s)"
            case .decryption(let s): return "RSA decryption failed: \(s)"
            case .malformedPublicKey: return "RSA public key DER is malformed"
            }
        }
    }

    public enum SignatureScheme: Sendable {
        /// RSASSA-PKCS1-v1_5 with SHA-256 (JWT "RS256").
        case rs256
        /// RSASSA-PSS with SHA-256 (JWT "PS256").
        case ps256

        var jwtAlgorithm: String {
            switch self {
            case .rs256: return "RS256"
            case .ps256: return "PS256"
            }
        }

        var secAlgorithm: SecKeyAlgorithm {
            switch self {
            case .rs256: return .rsaSignatureMessagePKCS1v15SHA256
            case .ps256: return .rsaSignatureMessagePSSSHA256
            }
        }
    }

    public enum OAEPHash: Sendable {
        case sha1, sha256
        var secAlgorithm: SecKeyAlgorithm {
            switch self {
            case .sha1: return .rsaEncryptionOAEPSHA1
            case .sha256: return .rsaEncryptionOAEPSHA256
            }
        }
    }

    /// PKCS#1 DER encoding of the private key (`RSAPrivateKey`).
    public let pkcs1: Data

    /// Big-endian modulus with no leading zero byte.
    public let modulus: Data
    /// Big-endian public exponent with no leading zero bytes.
    public let exponent: Data

    private let secKey: SecKey

    // SecKey is thread-safe for signing/decrypting but not marked Sendable, hence @unchecked.

    // MARK: - Creation

    public static func generate(bits: Int = 2048) throws -> RSAKey {
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: bits,
            kSecAttrIsPermanent: false,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            throw Error.generation(error?.takeRetainedValue().localizedDescription ?? "unknown")
        }
        return try RSAKey(secKey: key)
    }

    /// Import from PKCS#1 DER (`RSAPrivateKey`) bytes.
    public init(pkcs1: Data) throws {
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &error) else {
            throw Error.importFailed(error?.takeRetainedValue().localizedDescription ?? "unknown")
        }
        try self.init(secKey: key)
    }

    private init(secKey: SecKey) throws {
        var error: Unmanaged<CFError>?
        guard let priv = SecKeyCopyExternalRepresentation(secKey, &error) as Data? else {
            throw Error.exportFailed(error?.takeRetainedValue().localizedDescription ?? "unknown")
        }
        guard let pub = SecKeyCopyPublicKey(secKey),
              let pubData = SecKeyCopyExternalRepresentation(pub, &error) as Data? else {
            throw Error.exportFailed(error?.takeRetainedValue().localizedDescription ?? "public key")
        }
        let (n, e) = try RSAKey.parsePKCS1PublicKey(pubData)
        self.secKey = secKey
        self.pkcs1 = priv
        self.modulus = n
        self.exponent = e
    }

    // MARK: - Operations

    public func sign(_ message: Data, scheme: SignatureScheme) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(secKey, scheme.secAlgorithm, message as CFData, &error) as Data? else {
            throw Error.signing(error?.takeRetainedValue().localizedDescription ?? "unknown")
        }
        return sig
    }

    public func decryptOAEP(_ ciphertext: Data, hash: OAEPHash) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(secKey, hash.secAlgorithm, ciphertext as CFData, &error) as Data? else {
            throw Error.decryption(error?.takeRetainedValue().localizedDescription ?? "unknown")
        }
        return plain
    }

    /// Encrypt with the public key (used by tests to round-trip the session key).
    public func encryptOAEP(_ plaintext: Data, hash: OAEPHash) throws -> Data {
        guard let pub = SecKeyCopyPublicKey(secKey) else { throw Error.exportFailed("public key") }
        var error: Unmanaged<CFError>?
        guard let ct = SecKeyCreateEncryptedData(pub, hash.secAlgorithm, plaintext as CFData, &error) as Data? else {
            throw Error.decryption(error?.takeRetainedValue().localizedDescription ?? "encrypt")
        }
        return ct
    }

    /// The `<RSAKeyValue>` XML the v2 registration endpoint expects (`public_key`).
    public var xmlPublicKey: String {
        "<RSAKeyValue><Modulus>\(modulus.base64EncodedString())</Modulus><Exponent>\(exponent.base64EncodedString())</Exponent></RSAKeyValue>"
    }

    // MARK: - DER parsing

    /// Parse `RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }`.
    static func parsePKCS1PublicKey(_ der: Data) throws -> (Data, Data) {
        var reader = DERReader(der)
        let seq = try reader.readTLV()
        guard seq.tag == 0x30 else { throw Error.malformedPublicKey }
        var inner = DERReader(seq.value)
        let n = try inner.readTLV()
        let e = try inner.readTLV()
        guard n.tag == 0x02, e.tag == 0x02 else { throw Error.malformedPublicKey }
        return (stripLeadingZeros(n.value), stripLeadingZeros(e.value))
    }

    private static func stripLeadingZeros(_ d: Data) -> Data {
        var d = d
        while d.count > 1, d.first == 0 { d.removeFirst() }
        return d
    }
}

struct DERReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func readTLV() throws -> (tag: UInt8, value: Data) {
        guard offset < data.endIndex else { throw RSAKey.Error.malformedPublicKey }
        let tag = data[offset]
        offset += 1
        guard offset < data.endIndex else { throw RSAKey.Error.malformedPublicKey }
        var length = Int(data[offset])
        offset += 1
        if length & 0x80 != 0 {
            let count = length & 0x7f
            guard count > 0, count <= 4, offset + count <= data.endIndex else { throw RSAKey.Error.malformedPublicKey }
            length = 0
            for _ in 0..<count {
                length = (length << 8) | Int(data[offset])
                offset += 1
            }
        }
        guard offset + length <= data.endIndex else { throw RSAKey.Error.malformedPublicKey }
        let value = data.subdata(in: offset..<(offset + length))
        offset += length
        return (tag, value)
    }
}
