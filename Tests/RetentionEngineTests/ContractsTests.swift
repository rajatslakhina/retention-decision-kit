import XCTest
@testable import RetentionEngine

final class ContractsTests: XCTestCase {
    func testResponseEncodesExactlyOneTopLevelField() throws {
        let cases: [(RealtimeResponse, String)] = [
            (.message(messageIdentifier: "m1"), #"{"message":{"messageIdentifier":"m1"}}"#),
            (.alternateProduct(messageIdentifier: "m2", productId: "lite"), #"{"alternateProduct":{"messageIdentifier":"m2","productId":"lite"}}"#),
            (.promotionalOffer(messageIdentifier: "m3", signatureV2: "jws"), #"{"promotionalOffer":{"messageIdentifier":"m3","promotionalOfferSignatureV2":"jws"}}"#),
        ]
        for (response, expected) in cases {
            XCTAssertEqual(String(decoding: try response.jsonData(), as: UTF8.self), expected)
            XCTAssertEqual(try JSONDecoder().decode(RealtimeResponse.self, from: Data(expected.utf8)), response)
        }
    }

    func testDecodingRejectsTwoFields() {
        let json = #"{"message":{"messageIdentifier":"a"},"promotionalOffer":{"messageIdentifier":"b","promotionalOfferSignatureV2":"s"}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(RealtimeResponse.self, from: Data(json.utf8)))
    }

    func testRequestDecodesAppleFieldNamesAndIgnoresUnknownOnes() throws {
        let json = """
        {"originalTransactionId":"2000000123","appAppleId":1234567890,"productId":"pro.monthly",
         "userLocale":"en-US","requestIdentifier":"6f1f2e0a-0000-4000-8000-000000000001",
         "environment":"Production","signedDate":1794268800000,"somethingNew":true}
        """
        let request = try JSONDecoder().decode(DecodedRealtimeRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.appAppleId, 1_234_567_890)
        XCTAssertEqual(request.environment, .production)
        XCTAssertEqual(request.signedDate, 1_794_268_800_000)
    }

    func testUnknownEnvironmentDecodesButDoesNotEqualKnownOnes() throws {
        let environment = try JSONDecoder().decode(AppStoreEnvironment.self, from: Data(#""Xcode""#.utf8))
        XCTAssertEqual(environment.rawValue, "Xcode")
        XCTAssertNotEqual(environment, .production)
        XCTAssertNotEqual(environment, .sandbox)
    }

    func testJWSRoundTripAndBase64URL() throws {
        let request = Fixture.request()
        let compact = try CompactJWS.unsignedFixture(request)
        let jws = try CompactJWS(parsing: compact)
        XCTAssertEqual(try JSONDecoder().decode(DecodedRealtimeRequest.self, from: jws.payload), request)
        XCTAssertTrue(jws.signature.isEmpty)
        XCTAssertFalse(compact.contains("="), "base64url is unpadded")
        XCTAssertEqual(CompactJWS.decodeBase64URL("-_8"), Data([0xFB, 0xFF]))
    }

    func testJWSRejectsMalformedInput() {
        XCTAssertThrowsError(try CompactJWS(parsing: "only.two")) { XCTAssertEqual($0 as? JWSError, .malformed) }
        XCTAssertThrowsError(try CompactJWS(parsing: "a.b.c.d")) { XCTAssertEqual($0 as? JWSError, .malformed) }
        XCTAssertThrowsError(try CompactJWS(parsing: ".payload.sig")) { XCTAssertEqual($0 as? JWSError, .malformed) }
        XCTAssertThrowsError(try CompactJWS(parsing: "a+b.cc.dd")) { XCTAssertEqual($0 as? JWSError, .invalidBase64URL) }
        XCTAssertThrowsError(try CompactJWS(parsing: "abcde.cc.dd")) { XCTAssertEqual($0 as? JWSError, .invalidBase64URL) }
        let huge = String(repeating: "a", count: CompactJWS.maximumLength + 1)
        XCTAssertThrowsError(try CompactJWS(parsing: huge)) {
            XCTAssertEqual($0 as? JWSError, .tooLarge(bytes: CompactJWS.maximumLength + 1))
        }
    }
}
