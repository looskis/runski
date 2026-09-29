import Foundation
import CommonCrypto

/// AES-CBC with PKCS#7 padding, matching .NET's `Aes` defaults used by the
/// Actions service to encrypt runner messages.
public enum AESCBC {
    public enum Error: Swift.Error, CustomStringConvertible {
        case badKeyLength(Int)
        case badIVLength(Int)
        case cryptError(Int32)
        public var description: String {
            switch self {
            case .badKeyLength(let n): return "AES key must be 16/24/32 bytes, got \(n)"
            case .badIVLength(let n): return "AES IV must be 16 bytes, got \(n)"
            case .cryptError(let s): return "CommonCrypto error \(s)"
            }
        }
    }

    public static func decrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(CCOperation(kCCDecrypt), ciphertext, key: key, iv: iv)
    }

    public static func encrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(CCOperation(kCCEncrypt), plaintext, key: key, iv: iv)
    }

    private static func crypt(_ op: CCOperation, _ input: Data, key: Data, iv: Data) throws -> Data {
        guard [16, 24, 32].contains(key.count) else { throw Error.badKeyLength(key.count) }
        guard iv.count == kCCBlockSizeAES128 else { throw Error.badIVLength(iv.count) }
        let outCapacity = input.count + kCCBlockSizeAES128
        var out = Data(count: outCapacity)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            input.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, key.count, ivPtr.baseAddress,
                                inPtr.baseAddress, input.count,
                                outPtr.baseAddress, outCapacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Error.cryptError(status) }
        out.count = moved
        return out
    }

    /// Decrypt a runner message body: strips the UTF-8 BOM that .NET's
    /// `CryptoStream`/`StreamWriter` prepends.
    public static func decryptMessageBody(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        var plain = try decrypt(ciphertext, key: key, iv: iv)
        if plain.count >= 3, plain[plain.startIndex] == 0xEF, plain[plain.startIndex + 1] == 0xBB, plain[plain.startIndex + 2] == 0xBF {
            plain = plain.subdata(in: (plain.startIndex + 3)..<plain.endIndex)
        }
        return plain
    }
}
