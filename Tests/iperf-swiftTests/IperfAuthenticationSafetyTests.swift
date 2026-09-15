import CryptoKit
import Darwin
import IperfCLib
import Security
import XCTest

final class IperfAuthenticationSafetyTests: XCTestCase {
    func testAuthenticationRoundTripsBothPaddingModes() throws {
        let test = try makeAuthenticationTest()
        defer { iperf_free_test(test) }
        for padding: Int32 in [0, 1] {
            var token: UnsafeMutablePointer<CChar>?
            XCTAssertEqual(encode_auth_setting("audit", "password", test.pointee.server_rsa_private_key, &token, padding), 0)
            let encoded = try XCTUnwrap(token)
            defer { free(encoded) }
            var username: UnsafeMutablePointer<CChar>?
            var password: UnsafeMutablePointer<CChar>?
            var timestamp: time_t = 0
            XCTAssertEqual(decode_auth_setting(0, encoded, test.pointee.server_rsa_private_key, &username, &password, &timestamp, padding), 0)
            defer { free(username); free(password) }
            XCTAssertEqual(username.map { String(cString: $0) }, "audit")
            XCTAssertEqual(password.map { String(cString: $0) }, "password")
            XCTAssertLessThanOrEqual(abs(time(nil) - timestamp), 10)
        }
    }

    func testOverlongCredentialsFailWithoutProducingToken() throws {
        let test = try makeAuthenticationTest()
        defer { iperf_free_test(test) }
        // 200 bytes exceeds OAEP's capacity after the authentication framing;
        // 1,024 bytes also exceeds the RSA modulus-sized buffer used upstream.
        for count in [200, 1_024] {
            var token: UnsafeMutablePointer<CChar>?
            XCTAssertNotEqual(encode_auth_setting("audit", String(repeating: "x", count: count), test.pointee.server_rsa_private_key, &token, 0), 0)
            defer { free(token) }
            XCTAssertNil(token)
        }
    }

    func testMalformedAndOversizedTokensLeaveNoCredentials() throws {
        let test = try makeAuthenticationTest()
        defer { iperf_free_test(test) }
        let tokens = ["", "!", "A", "====", "aGVsbG8=", Data(repeating: 65, count: 1_024).base64EncodedString()]
        for token in tokens {
            var username: UnsafeMutablePointer<CChar>?
            var password: UnsafeMutablePointer<CChar>?
            var timestamp: time_t = 42
            XCTAssertNotEqual(decode_auth_setting(0, token, test.pointee.server_rsa_private_key, &username, &password, &timestamp, 0), 0)
            defer { free(username); free(password) }
            XCTAssertNil(username)
            XCTAssertNil(password)
            XCTAssertEqual(timestamp, 0)
        }
    }

    func testAuthorizedUsersPreserveCLILineEndingsAndComments() {
        let hash = SHA256.hash(data: Data("{audit}password".utf8)).map { String(format: "%02x", $0) }.joined()
        for lineEnding in ["\n", "\r\n"] {
            XCTAssertEqual(check_authentication("audit", "password", time(nil), "audit,\(hash)\(lineEnding)", 10), 0)
        }
        let commentedHash = SHA256.hash(data: Data("{#audit}password".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertNotEqual(check_authentication("#audit", "password", time(nil), "#audit,\(commentedHash)\n", 10), 0)
    }

    func testInvalidBase64KeysAreRejected() {
        for key in ["", "A", "====", "AA=A", "aGVsbG8="] {
            XCTAssertEqual(iperf_validate_client_rsa_pubkey(key), -1)
            XCTAssertEqual(iperf_validate_server_rsa_privkey(key), -1)
        }
    }

    private func makeAuthenticationTest() throws -> UnsafeMutablePointer<iperf_test> {
        let key = try XCTUnwrap(SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2_048
        ] as CFDictionary, nil))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(key, nil)) as Data
        let pem = "-----BEGIN RSA PRIVATE KEY-----\n\(der.base64EncodedString(options: .lineLength64Characters))\n-----END RSA PRIVATE KEY-----\n"
        let test = try XCTUnwrap(iperf_new_test())
        guard iperf_defaults(test) == 0 else {
            iperf_free_test(test)
            throw NSError(domain: "AuthenticationSafetyTests", code: 1)
        }
        iperf_set_test_server_rsa_privkey(test, Data(pem.utf8).base64EncodedString())
        guard test.pointee.server_rsa_private_key != nil else {
            iperf_free_test(test)
            throw NSError(domain: "AuthenticationSafetyTests", code: 2)
        }
        return test
    }
}
