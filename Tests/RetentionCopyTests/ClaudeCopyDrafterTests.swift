import Foundation
import RetentionEngine
import XCTest
@testable import RetentionCopy

final class StubTransport: HTTPTransport, Sendable {
    private let sent = Locked<[HTTPRequest]>([])
    let response: HTTPResponse

    init(status: Int = 200, json: String) {
        response = HTTPResponse(status: status, body: Data(json.utf8))
    }

    var requests: [HTTPRequest] { sent.withLock { $0 } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.withLock { $0.append(request) }
        return response
    }
}

final class ClaudeCopyDrafterTests: XCTestCase {
    let brief = CopyBrief(productId: "pro", productName: "Notes Pro", locale: "en-US", segment: .loyal, kind: .promotionalOffer(offerId: "o"), offerDiscountPercent: 50, valuePoints: ["offline mode"], variantCount: 2)

    static let toolResponse = #"""
    {"id":"msg_1","type":"message","role":"assistant","stop_reason":"tool_use",
     "content":[{"type":"text","text":"Here you go."},
                {"type":"tool_use","id":"toolu_1","name":"submit_variants",
                 "input":{"variants":[{"header":"Stay for 50% less","body":"Keep offline mode.","rationale":"r"},
                                      {"header":"Thanks","body":"Here's 50% off."},
                                      {"header":"incomplete"}]}}]}
    """#

    func testRequestShape() async throws {
        let transport = StubTransport(json: Self.toolResponse)
        let drafter = ClaudeCopyDrafter(model: "pinned-model-id", apiKey: { "sk-test" }, transport: transport)
        _ = try await drafter.draft(brief)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["x-api-key"], "sk-test")
        XCTAssertEqual(request.headers["anthropic-version"], "2023-06-01")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "pinned-model-id")
        XCTAssertNil(body["temperature"], "sampling parameters are left to the model's defaults")
        let choice = try XCTUnwrap(body["tool_choice"] as? [String: Any])
        XCTAssertEqual(choice["type"] as? String, "tool")
        XCTAssertEqual(choice["name"] as? String, "submit_variants")
        let schema = String(decoding: try JSONSerialization.data(withJSONObject: body["tools"] ?? [], options: [.sortedKeys]), as: UTF8.self)
        XCTAssertTrue(schema.contains(#""maxLength":66"#))
        XCTAssertTrue(schema.contains(#""maxLength":144"#))
        XCTAssertTrue(schema.contains(#""maxItems":2"#))
        let message = String(decoding: request.body, as: UTF8.self)
        XCTAssertTrue(message.contains("offer_discount_percent"))
    }

    func testParsesCompleteVariantsOnly() throws {
        let variants = try ClaudeCopyDrafter.parseVariants(from: HTTPResponse(status: 200, body: Data(Self.toolResponse.utf8)), limit: 6)
        XCTAssertEqual(variants.map(\.header), ["Stay for 50% less", "Thanks"])
        XCTAssertEqual(variants.first?.rationale, "r")
        XCTAssertEqual(try ClaudeCopyDrafter.parseVariants(from: HTTPResponse(status: 200, body: Data(Self.toolResponse.utf8)), limit: 1).count, 1)
    }

    func testTruncationAndMissingToolUseAreErrors() {
        let truncated = #"{"content":[{"type":"tool_use","name":"submit_variants","input":{"variants":[]}}],"stop_reason":"max_tokens"}"#
        XCTAssertThrowsError(try ClaudeCopyDrafter.parseVariants(from: HTTPResponse(status: 200, body: Data(truncated.utf8)))) {
            XCTAssertEqual($0 as? ClaudeDraftError, .truncated)
        }
        let textOnly = #"{"content":[{"type":"text","text":"no tool"}],"stop_reason":"end_turn"}"#
        XCTAssertThrowsError(try ClaudeCopyDrafter.parseVariants(from: HTTPResponse(status: 200, body: Data(textOnly.utf8)))) {
            XCTAssertEqual($0 as? ClaudeDraftError, .noToolUse(stopReason: "end_turn"))
        }
        let empty = #"{"content":[{"type":"tool_use","name":"submit_variants","input":{"variants":[{"header":"h"}]}}],"stop_reason":"tool_use"}"#
        XCTAssertThrowsError(try ClaudeCopyDrafter.parseVariants(from: HTTPResponse(status: 200, body: Data(empty.utf8))))
        XCTAssertThrowsError(try ClaudeCopyDrafter.parseVariants(from: HTTPResponse(status: 200, body: Data("not json".utf8))))
    }

    func testHTTPErrorsAreClassified() {
        let overloaded = #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        XCTAssertThrowsError(try ClaudeCopyDrafter.parseVariants(from: HTTPResponse(status: 529, body: Data(overloaded.utf8)))) {
            XCTAssertEqual($0 as? ClaudeDraftError, .http(status: 529, errorType: "overloaded_error", message: "Overloaded", retryable: true))
        }
        XCTAssertThrowsError(try ClaudeCopyDrafter.parseVariants(from: HTTPResponse(status: 400, body: Data()))) {
            XCTAssertEqual($0 as? ClaudeDraftError, .http(status: 400, errorType: nil, message: nil, retryable: false))
        }
    }

    func testMissingKeyFailsBeforeAnyRequest() async {
        struct NoKey: Error {}
        let transport = StubTransport(json: Self.toolResponse)
        let drafter = ClaudeCopyDrafter(model: "m", apiKey: { throw NoKey() }, transport: transport)
        do {
            _ = try await drafter.draft(brief)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is NoKey)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }
}
