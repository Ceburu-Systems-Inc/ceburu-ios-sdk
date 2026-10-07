import XCTest
import CryptoKit
@testable import CeburuAnalyticsSDK

final class PIIRedactionTests: XCTestCase {

    // MARK: - Drop rules

    func testPasswordDropped() {
        XCTAssertNil(Security.redact(["user.password": "hunter2"])["user.password"])
    }

    func testAuthorizationDropped() {
        XCTAssertNil(Security.redact(["Authorization": "Bearer tok"])["Authorization"])
    }

    func testCookieDropped() {
        XCTAssertNil(Security.redact(["session.cookie": "abc123"])["session.cookie"])
    }

    func testSecretDropped() {
        XCTAssertNil(Security.redact(["client.secret": "s3cr3t"])["client.secret"])
    }

    // MARK: - Redact rules

    func testTokenRedacted() {
        XCTAssertEqual(Security.redact(["auth.token": "jwt.xyz"])["auth.token"], "[REDACTED]")
    }

    func testCardRedacted() {
        XCTAssertEqual(Security.redact(["card.number": "4111111111111111"])["card.number"], "[REDACTED]")
    }

    // MARK: - Hash rules

    func testEmailHashed() {
        let result = Security.redact(["user.email": "alice@example.com"])
        let raw    = result["user.email"] ?? ""
        // Must be a 64-char hex string (SHA-256)
        XCTAssertEqual(raw.count, 64)
        XCTAssertTrue(raw.allSatisfy { $0.isHexDigit })
        // Must match the expected digest
        let expected = SHA256.hash(data: Data("alice@example.com".utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(raw, expected)
    }

    func testPhoneHashed() {
        let result = Security.redact(["contact.phone": "+15555550100"])
        let raw    = result["contact.phone"] ?? ""
        XCTAssertEqual(raw.count, 64)
    }

    // MARK: - Passthrough

    func testNormalKeyPassthrough() {
        XCTAssertEqual(Security.redact(["screen": "checkout"])["screen"], "checkout")
    }

    func testUserNamePassthrough() {
        XCTAssertEqual(Security.redact(["user.name": "Alice"])["user.name"], "Alice")
    }

    // MARK: - Case-insensitivity

    func testPasswordKeyIsCaseInsensitive() {
        XCTAssertNil(Security.redact(["User.PASSWORD": "x"])["User.PASSWORD"])
    }

    func testTokenKeyIsCaseInsensitive() {
        XCTAssertEqual(Security.redact(["Auth.TOKEN": "y"])["Auth.TOKEN"], "[REDACTED]")
    }

    func testEmailKeyIsCaseInsensitive() {
        let result = Security.redact(["User.Email": "bob@test.com"])
        XCTAssertEqual(result["User.Email"]?.count, 64)
    }

    // MARK: - Empty input

    func testEmptyInputProducesEmptyOutput() {
        XCTAssertTrue(Security.redact([:]).isEmpty)
    }

    // MARK: - Multiple keys in one call

    func testMixedKeys() {
        let input: [String: String] = [
            "screen":       "checkout",
            "user.email":   "a@b.com",
            "user.token":   "tok",
            "user.password":"pw",
            "amount":       "99"
        ]
        let out = Security.redact(input)
        XCTAssertEqual(out["screen"], "checkout")
        XCTAssertEqual(out["amount"], "99")
        XCTAssertEqual(out["user.token"], "[REDACTED]")
        XCTAssertNil(out["user.password"])
        XCTAssertEqual(out["user.email"]?.count, 64)
        // Exactly 4 keys survive (password dropped)
        XCTAssertEqual(out.count, 4)
    }
}
