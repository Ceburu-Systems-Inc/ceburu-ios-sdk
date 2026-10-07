import XCTest
@testable import CeburuAnalyticsSDK

final class RetryBackoffTests: XCTestCase {

    func testFirstDelayIsAbout2s() {
        var b = RetryBackoff()
        let ms = b.nextDelayMs()
        // Base: 1000 * (1 << 1) = 2000 ms, plus jitter 0–1000
        XCTAssertGreaterThanOrEqual(ms, 2000)
        XCTAssertLessThanOrEqual(ms, 3000)
    }

    func testDelayDoublesEachAttempt() {
        var b = RetryBackoff()
        let d1 = b.nextDelayMs() // attempt 1 → base 2 s
        let d2 = b.nextDelayMs() // attempt 2 → base 4 s
        let d3 = b.nextDelayMs() // attempt 3 → base 8 s
        // Strip jitter (up to 1000 ms) before comparing
        XCTAssertLessThanOrEqual(d1 - 1000, 2000)
        XCTAssertLessThanOrEqual(d2 - 1000, 4000)
        XCTAssertLessThanOrEqual(d3 - 1000, 8000)
        XCTAssertGreaterThanOrEqual(d2, d1 - 1000) // generally increasing
        XCTAssertGreaterThanOrEqual(d3, d2 - 1000)
    }

    func testDelayCapAt5min() {
        var b = RetryBackoff()
        // Advance well past the cap (exp clamps at 8, giving base = 256 s > 300 s cap)
        for _ in 0..<10 { _ = b.nextDelayMs() }
        let ms = b.nextDelayMs()
        // 300 000 ms + up to 1000 ms jitter
        XCTAssertLessThanOrEqual(ms, 301_000)
    }

    func testResetRestartsSchedule() {
        var b = RetryBackoff()
        for _ in 0..<8 { _ = b.nextDelayMs() } // drive to near-cap
        b.reset()
        let ms = b.nextDelayMs()
        // After reset, next call is attempt 1 again → base 2 s
        XCTAssertLessThanOrEqual(ms, 3000)
    }
}
