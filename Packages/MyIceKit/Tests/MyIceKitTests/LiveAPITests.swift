import XCTest
@testable import MyIceKit

/// Opt-in smoke test against the real backend: `LIVE_API=1 swift test --filter LiveAPITests`.
/// Uses invalid credentials and only checks that the request is understood.
final class LiveAPITests: XCTestCase {
    func testLoginWithInvalidCredentialsIsRejectedCleanly() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_API"] == "1")
        let client = APIClient(context: TestContext())
        let p: SessionPayload = try await client.send(.login(email: "probe@example.invalid", password: "x"))
        XCTAssertEqual(p.status, 0)
        XCTAssertNotNil(p.message)
    }
}
