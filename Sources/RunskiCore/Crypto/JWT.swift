import Foundation

/// Minimal JWT builder for the OAuth2 JWT-bearer client-credentials grant the
/// Actions service uses (`urn:ietf:params:oauth:client-assertion-type:jwt-bearer`).
public enum JWT {
    public struct Claims: Encodable {
        public var iss: String
        public var sub: String
        public var aud: String
        public var jti: String
        public var nbf: Int
        public var iat: Int
        public var exp: Int
    }

    public static func clientAssertion(clientId: String, audience: String, key: RSAKey,
                                       scheme: RSAKey.SignatureScheme, now: Date = Date(),
                                       lifetime: TimeInterval = 300) throws -> String {
        // Back-date slightly to tolerate clock skew between us and GitHub.
        let nbf = Int(now.timeIntervalSince1970) - 30
        let claims = Claims(iss: clientId, sub: clientId, aud: audience, jti: UUID().uuidString,
                            nbf: nbf, iat: nbf, exp: nbf + Int(lifetime))
        let header = ["alg": scheme.jwtAlgorithm, "typ": "JWT"]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let h = try encoder.encode(header).base64URLEncoded()
        let c = try encoder.encode(claims).base64URLEncoded()
        let signingInput = "\(h).\(c)"
        let sig = try key.sign(Data(signingInput.utf8), scheme: scheme).base64URLEncoded()
        return "\(signingInput).\(sig)"
    }
}

public extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}
