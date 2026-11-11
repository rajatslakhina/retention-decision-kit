import Foundation
import RetentionEngine

/// A minimal HTTP abstraction so the drafter is testable without a network.
public struct HTTPRequest: Sendable, Hashable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data

    public init(url: URL, method: String, headers: [String: String], body: Data) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable, Hashable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// A small JSON value type for tool schemas and tool inputs.
public indirect enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

public enum ClaudeDraftError: Error, Sendable, Hashable {
    /// An HTTP error. `retryable` covers 408, 429, 500, 503 and 529 (overloaded).
    case http(status: Int, errorType: String?, message: String?, retryable: Bool)
    /// The model stopped at `max_tokens`; the tool input may be cut off, so nothing is trusted.
    case truncated
    /// The response contained no `submit_variants` tool call.
    case noToolUse(stopReason: String?)
    case malformed(String)
}

/// Drafts copy with the Claude Messages API.
///
/// Offline only — this runs in a build job or a back-office tool, never in the app and never on
/// the request path. The API key comes from the environment of that job; it is never compiled
/// into an app. Structured output uses a forced tool call (`tool_choice`), so the response is
/// JSON with a known shape — and the eval gate still re-checks every field, because a schema is a
/// request to the model, not a guarantee.
public struct ClaudeCopyDrafter: CopyDrafter {
    /// Provably valid: a constant, well-formed absolute URL literal.
    public static let messagesEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2023-06-01"
    public static let toolName = "submit_variants"

    public let model: String
    public let maxTokens: Int
    private let apiKey: @Sendable () throws -> String
    private let transport: any HTTPTransport
    private let endpoint: URL

    /// - Parameters:
    ///   - model: The model to call. Deliberately has no default: pin the model you evaluated.
    ///   - apiKey: Read at call time, so the key is never stored in this value.
    public init(
        model: String,
        maxTokens: Int = 1_024,
        apiKey: @escaping @Sendable () throws -> String,
        transport: any HTTPTransport,
        endpoint: URL = ClaudeCopyDrafter.messagesEndpoint
    ) {
        self.model = model
        self.maxTokens = min(max(maxTokens, 256), 8_192)
        self.apiKey = apiKey
        self.transport = transport
        self.endpoint = endpoint
    }

    public func draft(_ brief: CopyBrief) async throws -> [CopyCandidate] {
        let request = try makeRequest(for: brief)
        let response = try await transport.send(request)
        return try Self.parseVariants(from: response, limit: brief.variantCount)
    }

    public func makeRequest(for brief: CopyBrief) throws -> HTTPRequest {
        let body = MessagesRequest(
            model: model,
            maxTokens: maxTokens,
            system: Self.systemPrompt,
            messages: [.init(role: "user", content: try Self.userMessage(for: brief))],
            tools: [Self.tool(variantCount: brief.variantCount)],
            toolChoice: .init(type: "tool", name: Self.toolName)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return HTTPRequest(
            url: endpoint,
            method: "POST",
            headers: [
                "x-api-key": try apiKey(),
                "anthropic-version": Self.apiVersion,
                "content-type": "application/json",
            ],
            body: try encoder.encode(body)
        )
    }

    public static let systemPrompt = """
        You write retention messages that iOS shows on the subscription cancellation screen.
        Hard rules: header at most 66 characters; body at most 144 characters. Write in the
        brief's locale. Use only facts from value_points; never invent numbers. Never state a
        price or currency (the App Store shows localized prices). Mention a percentage only if
        the brief has offer_discount_percent, and then exactly that percentage. No urgency, no
        guilt, no claims that cancelling deletes anything. Do not mention other platforms.
        Submit the variants with the submit_variants tool.
        """

    static func userMessage(for brief: CopyBrief) throws -> String {
        struct Payload: Encodable {
            let product_name: String
            let locale: String
            let segment: String
            let message_kind: String
            let offer_discount_percent: Int?
            let value_points: [String]
            let variant_count: Int
        }
        let payload = Payload(
            product_name: brief.productName,
            locale: brief.locale,
            segment: brief.segment.rawValue,
            message_kind: brief.kind.canonical,
            offer_discount_percent: brief.offerDiscountPercent,
            value_points: brief.valuePoints,
            variant_count: brief.variantCount
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(payload), as: UTF8.self)
        return "Draft retention message variants for this brief:\n" + json
    }

    static func tool(variantCount: Int) -> Tool {
        Tool(
            name: toolName,
            description: "Submit the drafted retention message variants.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "variants": .object([
                        "type": .string("array"),
                        "minItems": .int(1),
                        "maxItems": .int(variantCount),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "header": .object(["type": .string("string"), "maxLength": .int(LengthRule.headerLimit)]),
                                "body": .object(["type": .string("string"), "maxLength": .int(LengthRule.bodyLimit)]),
                                "rationale": .object(["type": .string("string")]),
                            ]),
                            "required": .array([.string("header"), .string("body")]),
                        ]),
                    ]),
                ]),
                "required": .array([.string("variants")]),
            ])
        )
    }

    /// Parses a Messages API response into candidates, trusting nothing that is not complete.
    public static func parseVariants(from response: HTTPResponse, limit: Int = 6) throws -> [CopyCandidate] {
        let decoder = JSONDecoder()
        guard (200..<300).contains(response.status) else {
            let envelope = try? decoder.decode(ErrorEnvelope.self, from: response.body)
            let retryable = [408, 429, 500, 503, 529].contains(response.status)
            throw ClaudeDraftError.http(
                status: response.status,
                errorType: envelope?.error.type,
                message: envelope?.error.message,
                retryable: retryable
            )
        }
        let message: MessagesResponse
        do {
            message = try decoder.decode(MessagesResponse.self, from: response.body)
        } catch {
            throw ClaudeDraftError.malformed("response is not a Messages API message")
        }
        if message.stopReason == "max_tokens" { throw ClaudeDraftError.truncated }
        guard let call = message.content.first(where: { $0.type == "tool_use" && $0.name == toolName }),
              let input = call.input
        else { throw ClaudeDraftError.noToolUse(stopReason: message.stopReason) }
        guard case .array(let items)? = input["variants"] else {
            throw ClaudeDraftError.malformed("tool input has no variants array")
        }
        let candidates = items.compactMap { item -> CopyCandidate? in
            guard let header = item["header"]?.stringValue, let body = item["body"]?.stringValue else { return nil }
            return CopyCandidate(header: header, body: body, rationale: item["rationale"]?.stringValue)
        }
        guard !candidates.isEmpty else { throw ClaudeDraftError.malformed("no complete variants") }
        return Array(candidates.prefix(max(1, limit)))
    }

    // MARK: Wire types

    struct MessagesRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        struct ToolChoice: Encodable {
            let type: String
            let name: String
        }

        let model: String
        let maxTokens: Int
        let system: String
        let messages: [Message]
        let tools: [Tool]
        let toolChoice: ToolChoice

        enum CodingKeys: String, CodingKey {
            case model, system, messages, tools
            case maxTokens = "max_tokens"
            case toolChoice = "tool_choice"
        }
    }

    struct Tool: Encodable {
        let name: String
        let description: String
        let inputSchema: JSONValue

        enum CodingKeys: String, CodingKey {
            case name, description
            case inputSchema = "input_schema"
        }
    }

    struct MessagesResponse: Decodable {
        struct Block: Decodable {
            let type: String
            let name: String?
            let input: JSONValue?
        }

        let content: [Block]
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }
    }

    struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
            let type: String?
            let message: String?
        }

        let error: Detail
    }
}

#if canImport(Darwin)
/// `URLSession`-backed transport (Apple platforms).
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return HTTPResponse(status: status, body: data)
    }
}
#endif
