import XCTest
@testable import RunskiCore

final class CryptoTests: XCTestCase {
    func testRSAKeyRoundTrip() throws {
        let key = try RSAKey.generate()
        XCTAssertEqual(key.exponent, Data([1, 0, 1]))
        XCTAssertEqual(key.modulus.count, 256)
        let reloaded = try RSAKey(pkcs1: key.pkcs1)
        XCTAssertEqual(reloaded.modulus, key.modulus)
        let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        for hash in [RSAKey.OAEPHash.sha1, .sha256] {
            let ct = try key.encryptOAEP(secret, hash: hash)
            XCTAssertEqual(try reloaded.decryptOAEP(ct, hash: hash), secret)
        }
        let sig = try key.sign(Data("hello".utf8), scheme: .rs256)
        XCTAssertEqual(sig.count, 256)
        let sig2 = try key.sign(Data("hello".utf8), scheme: .ps256)
        XCTAssertEqual(sig2.count, 256)
        XCTAssertTrue(key.xmlPublicKey.hasPrefix("<RSAKeyValue><Modulus>"))
    }

    func testJWT() throws {
        let key = try RSAKey.generate()
        let jwt = try JWT.clientAssertion(clientId: "cid", audience: "https://aud", key: key, scheme: .ps256)
        let parts = jwt.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        let header = try JSONSerialization.jsonObject(with: Data(base64URL: String(parts[0]))!) as! [String: Any]
        XCTAssertEqual(header["alg"] as? String, "PS256")
        let claims = try JSONSerialization.jsonObject(with: Data(base64URL: String(parts[1]))!) as! [String: Any]
        XCTAssertEqual(claims["iss"] as? String, "cid")
        XCTAssertEqual(claims["aud"] as? String, "https://aud")
    }

    func testAESCBCWithBOM() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let iv = Data((0..<16).map { UInt8($0 * 3) })
        var plain = Data([0xEF, 0xBB, 0xBF])
        plain.append(Data("{\"a\":1}".utf8))
        let ct = try AESCBC.encrypt(plain, key: key, iv: iv)
        XCTAssertEqual(ct.count % 16, 0)
        XCTAssertEqual(String(decoding: try AESCBC.decryptMessageBody(ct, key: key, iv: iv), as: UTF8.self), "{\"a\":1}")
    }

    func testVaultSoftwareRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runski-vault-\(UUID().uuidString)")
        let vault = try Vault(directory: dir, preferSecureEnclave: false)
        XCTAssertEqual(vault.backend, .software)
        let blob = try vault.sealString("s3cret")
        XCTAssertEqual(try vault.openString(blob), "s3cret")
        // Re-open from disk.
        let vault2 = try Vault(directory: dir, preferSecureEnclave: false)
        XCTAssertEqual(try vault2.openString(blob), "s3cret")
        var tampered = blob; tampered[tampered.count - 1] ^= 0xFF
        XCTAssertThrowsError(try vault2.open(tampered))
        let store = SecretStore(vault: vault2, directory: dir)
        try store.set("API_KEY", value: "abc")
        XCTAssertEqual(store.names(), ["API_KEY"])
        XCTAssertEqual(try store.all()["API_KEY"], "abc")
        try? FileManager.default.removeItem(at: dir)
    }

    func testVaultSecureEnclaveIfAvailable() throws {
        guard Vault.secureEnclaveAvailable else { throw XCTSkip("no Secure Enclave") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runski-se-\(UUID().uuidString)")
        let vault = try Vault(directory: dir)
        XCTAssertEqual(vault.backend, .secureEnclave)
        let blob = try vault.seal(Data("hello".utf8))
        XCTAssertEqual(try Vault(directory: dir).open(blob), Data("hello".utf8))
        try? FileManager.default.removeItem(at: dir)
    }

    func testTimestamps() {
        let ts = ServiceJSON.timestamp(Date(timeIntervalSince1970: 1_700_000_000.5))
        XCTAssertEqual(ts, "2023-11-14T22:13:20.5000000Z")
        XCTAssertNotNil(ServiceJSON.parseTimestamp("2023-11-14T22:13:20.5000000Z"))
        XCTAssertNotNil(ServiceJSON.parseTimestamp("2023-11-14T22:13:20Z"))
    }

    func testVSSRouteBuilding() async {
        let c = VSSClient(baseURL: URL(string: "https://pipelines.example.com/abc/")!, authorization: .none, http: HTTPClient(), useLocationService: false)
        let u = await c.url(for: VSSResource.sessions, route: ["poolId": "1"], query: ["api": "x"])
        XCTAssertEqual(u.absoluteString, "https://pipelines.example.com/abc/_apis/distributedtask/pools/1/sessions?api=x")
        let u2 = await c.url(for: VSSResource.timelineRecords, route: ["scopeIdentifier": "s", "hubName": "actions", "planId": "p", "timelineId": "t"])
        XCTAssertEqual(u2.absoluteString, "https://pipelines.example.com/abc/s/_apis/distributedtask/hubs/actions/plans/p/timelines/t/records")
    }

    func testGitHubAPIScopes() throws {
        XCTAssertEqual(GitHubAPI.apiBase(for: "https://github.com/o/r").absoluteString, "https://api.github.com")
        XCTAssertEqual(GitHubAPI.apiBase(for: "https://ghe.corp.net/o/r").absoluteString, "https://ghe.corp.net/api/v3")
        XCTAssertEqual(try GitHubAPI.scope(for: "https://github.com/o/r").pathPrefix, "repos/o/r")
        XCTAssertEqual(try GitHubAPI.scope(for: "https://github.com/myorg").pathPrefix, "orgs/myorg")
        XCTAssertEqual(try GitHubAPI.scope(for: "https://github.com/enterprises/e").pathPrefix, "enterprises/e")
        XCTAssertThrowsError(try GitHubAPI.scope(for: "https://github.com/a/b/c"))
    }

    func testGlobAndHashFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runski-glob-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
        try "a".write(to: dir.appendingPathComponent("package-lock.json"), atomically: true, encoding: .utf8)
        try "b".write(to: dir.appendingPathComponent("src/x.js"), atomically: true, encoding: .utf8)
        try "c".write(to: dir.appendingPathComponent("src/deep/y.js"), atomically: true, encoding: .utf8)
        try "d".write(to: dir.appendingPathComponent("src/deep/z.ts"), atomically: true, encoding: .utf8)
        let ws = dir.path
        let g1 = try Glob(patterns: "**/*.js", workspace: ws).matches().map { $0.replacingOccurrences(of: ws + "/", with: "") }
        XCTAssertEqual(g1, ["src/deep/y.js", "src/x.js"])
        let g2 = try Glob(patterns: "src/**\n!**/*.ts", workspace: ws).matches().map { $0.replacingOccurrences(of: ws + "/", with: "") }
        XCTAssertEqual(g2, ["src/deep/y.js", "src/x.js"])
        let g3 = try Glob(patterns: "package-lock.json", workspace: ws).matches().count
        XCTAssertEqual(g3, 1)
        let h1 = try HashFiles.hash(patterns: "**/package-lock.json", workspace: ws)
        XCTAssertEqual(h1.count, 64)
        XCTAssertEqual(try HashFiles.hash(patterns: "nothing/**", workspace: ws), "")
        XCTAssertNotEqual(h1, try HashFiles.hash(patterns: "src/**", workspace: ws))
        try? FileManager.default.removeItem(at: dir)
    }
}
