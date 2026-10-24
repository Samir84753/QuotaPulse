import Foundation
import XCTest
@testable import QuotaCore

final class IntegrationSafetyTests: XCTestCase {
    func testCancellationStopsSubprocess() async throws {
        let started = Date()
        let task = Task { await Shell.run("/bin/sleep", ["2"], timeout: 10) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let result = await task.value
        XCTAssertNotEqual(result.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testHTTPErrorMessageDoesNotExposeResponseBody() {
        let message = ProviderSnapshot.failure(.codex, QuotaError.http(400, "fake-private-response")).message
        XCTAssertFalse(message?.contains("fake-private-response") ?? true)
    }

    func testNonFiniteNumbersAreRejected() {
        XCTAssertNil(JSON.double("NaN"))
        XCTAssertNil(JSON.double("Infinity"))
        XCTAssertNil(DateParsing.date("Infinity"))
    }
    func testTimeoutKillsChildIgnoringTermination() async {
        let started = Date()
        let result = await Shell.run("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.15)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testBothSubprocessPipesDrainWithoutDeadlock() async {
        let script = "i=0; while [ $i -lt 4000 ]; do printf 'abcdefghijklmnopqrstuvwxyz012345'; printf 'abcdefghijklmnopqrstuvwxyz012345' >&2; i=$((i+1)); done"
        let result = await Shell.run("/bin/sh", ["-c", script], timeout: 3)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.count, 128_000)
        XCTAssertEqual(result.stderr.count, 128_000)
    }

    func testCodexOutOfRangeDurationDoesNotCrash() throws {
        let data = Data(#"{"rate_limit":{"primary_window":{"used_percent":23,"limit_window_seconds":1e100}}}"#.utf8)
        let parsed = try CodexProvider.parseUsage(data)
        XCTAssertEqual(parsed.windows.first?.usedPercent, 23)
        XCTAssertNil(parsed.windows.first?.windowSeconds)
        XCTAssertNil(JSON.seconds("Infinity"))
        XCTAssertNil(JSON.seconds(1e100, multiplier: 60))
    }

    func testAntigravityRejectsInvalidPort() async {
        do {
            _ = try await AntigravityProvider().call(scheme: "http", port: -1, method: "GetUserStatus", token: nil)
            XCTFail("Invalid port must fail before making a request")
        } catch {
            XCTAssertTrue(error is QuotaError)
        }
    }

}
