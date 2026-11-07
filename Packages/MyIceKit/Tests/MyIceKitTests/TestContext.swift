@testable import MyIceKit

/// Shared `RequestContextProviding` fixture for every test that needs an `APIClient` —
/// was copy-pasted as a near-identical `Ctx` in three different test files.
final class TestContext: RequestContextProviding, @unchecked Sendable {
    var token: String?
    init(token: String? = nil) { self.token = token }
    func currentToken() async -> String? { token }
    func currentLanguage() async -> String { "de" }
}
