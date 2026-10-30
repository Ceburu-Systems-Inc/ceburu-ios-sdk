import XCTest
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

    // MARK: - Masked keys

    func testEmailAndPhoneMasked() {
        XCTAssertEqual(Security.redact(["user.email": "alice@example.com"])["user.email"], "[REDACTED]")
        XCTAssertEqual(Security.redact(["contact.phone": "+15555550100"])["contact.phone"], "[REDACTED]")
    }

    // MARK: - Free text

    func testFreeTextSecretsRedacted() {
        let out = Security.redactText("jo@example.com Bearer abc.def 4111 1111 1111 1111 api_key=s3cr3t")
        for leaked in ["jo@example.com", "abc.def", "4111", "s3cr3t"] { XCTAssertFalse(out.contains(leaked), leaked) }
        XCTAssertTrue(out.contains("api_key=[REDACTED]"))
    }

    func testIdsKept() {
        XCTAssertEqual(Security.redactText("4bf92f3577b34da6a3ce929d0e0e4736"), "4bf92f3577b34da6a3ce929d0e0e4736")
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
        XCTAssertEqual(Security.redact(["User.Email": "bob@test.com"])["User.Email"], "[REDACTED]")
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
        XCTAssertEqual(out["user.email"], "[REDACTED]")
        // Exactly 4 keys survive (password dropped)
        XCTAssertEqual(out.count, 4)
    }

    func testOnlyFlatBoundedScalarsAreKept() {
        let out = Security.bound(["nested": ["a": 1], "list": [1], "n": 3, "s": String(repeating: "x", count: 10_000),
                                  "exception.stacktrace": String(repeating: "y", count: 20_000), "ok": true])
        XCTAssertNil(out["nested"]); XCTAssertNil(out["list"])
        XCTAssertEqual(out["n"], "3"); XCTAssertEqual(out["ok"], "true")
        XCTAssertEqual(out["s"]?.count, 4_096)
        XCTAssertEqual(out["exception.stacktrace"]?.count, 16_000)
        XCTAssertEqual(Security.bound(Dictionary(uniqueKeysWithValues: (1...200).map { ("k\($0)", $0) })).count, Security.maxAttributes)
        XCTAssertNil(Security.redact(["db_credentials": "x"])["db_credentials"])
        XCTAssertEqual(Security.redact(["api_key": "k"])["api_key"], "[REDACTED]")
    }
}
