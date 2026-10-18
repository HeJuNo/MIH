import Foundation

public struct APIConfig: Sendable {
    public var baseURL: URL
    public var webBaseURL: URL { baseURL.deletingLastPathComponent().deletingLastPathComponent() }

    public init(baseURL: URL = URL(string: "https://app.myice.hockey/api/mobilerest")!) {
        self.baseURL = baseURL
    }
}

public enum APIError: Error, Equatable, Sendable {
    case http(status: Int)
    /// Server answered `status != "1"`; `message` is already localized server-side.
    case rejected(message: String?)
    case decoding(String)
}

/// Supplies the two implicit fields the original client adds to every body.
public protocol RequestContextProviding: Sendable {
    func currentToken() async -> String?
    func currentLanguage() async -> String
}

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, delegate: nil)
    }
}

public final class APIClient: Sendable {
    let config: APIConfig
    let transport: HTTPTransport
    let context: RequestContextProviding
    let decoder = JSONDecoder()

    public init(config: APIConfig = .init(), transport: HTTPTransport = URLSession.shared, context: RequestContextProviding) {
        self.config = config
        self.transport = transport
        self.context = context
    }

    /// Builds the request exactly like `fetchClient.post`: endpoint fields,
    /// then `token` (override → stored → null) and `language`.
    public func makeRequest(_ endpoint: Endpoint) async -> URLRequest {
        var form = MultipartForm()
        for (k, v) in endpoint.fields { form.append(k, v) }
        var token = endpoint.tokenOverride
        if token == nil { token = await context.currentToken() }
        form.append("token", token.map(MultipartForm.Value.string) ?? .null)
        form.append("language", .string(await context.currentLanguage()))

        var request = URLRequest(url: config.baseURL.appendingPathComponent(String(endpoint.path.dropFirst())))
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.encoded()
        return request
    }

    public func send<T: Decodable>(_ endpoint: Endpoint, as type: T.Type = T.self) async throws -> T {
        let (data, response) = try await transport.data(for: await makeRequest(endpoint))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.http(status: http.statusCode)
        }
        do {
            return try decoder.decode(T.self, from: JSONNormalizer.normalize(data))
        } catch {
            throw APIError.decoding(Self.describe(error))
        }
    }

    static func describe(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return String(describing: error) }
        func path(_ c: DecodingError.Context) -> String { c.codingPath.map(\.stringValue).joined(separator: ".") }
        switch e {
        case .typeMismatch(let t, let c): return "type \(t) at \(path(c))"
        case .valueNotFound(let t, let c): return "missing \(t) at \(path(c))"
        case .keyNotFound(let k, let c): return "missing key \(k.stringValue) at \(path(c))"
        case .dataCorrupted(let c): return "corrupted at \(path(c)): \(c.debugDescription)"
        @unknown default: return String(describing: e)
        }
    }

    /// For mutating calls: decodes the `{status, message}` envelope and throws on `status != 1`.
    @discardableResult
    public func perform(_ endpoint: Endpoint) async throws -> StatusEnvelope {
        let envelope: StatusEnvelope = try await send(endpoint)
        guard envelope.isSuccess else { throw APIError.rejected(message: envelope.message) }
        return envelope
    }
}
