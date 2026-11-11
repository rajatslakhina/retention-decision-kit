import Foundation

// Wire types for Apple's Retention Messaging API "Get Retention Message" endpoint.
// Field names follow Apple's documentation:
// https://developer.apple.com/documentation/retentionmessaging/decodedrealtimerequestbody
// https://developer.apple.com/documentation/retentionmessaging/realtimeresponsebody

/// The App Store server environment a request was signed for.
///
/// Modelled as an open set of raw values so an environment string Apple adds later decodes
/// (and is then rejected by an explicit comparison) instead of failing JSON decoding.
public struct AppStoreEnvironment: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let sandbox = AppStoreEnvironment(rawValue: "Sandbox")
    public static let production = AppStoreEnvironment(rawValue: "Production")
    public var description: String { rawValue }
}

/// The POST body Apple sends: a single JWS compact serialization.
public struct RealtimeRequestBody: Codable, Sendable, Hashable {
    public let signedPayload: String
    public init(signedPayload: String) { self.signedPayload = signedPayload }
}

/// The verified, decoded payload of a real-time request (`DecodedRealtimeRequestBody`).
public struct DecodedRealtimeRequest: Codable, Sendable, Hashable {
    /// The original transaction identifier of the customer's subscription.
    public let originalTransactionId: String
    /// The app's App Store identifier. Apple: if it doesn't match yours, don't respond.
    public let appAppleId: Int64
    /// The auto-renewable subscription the customer is looking at.
    public let productId: String
    /// The device's locale, for example `en-US`.
    public let userLocale: String
    /// A UUID the App Store server creates to identify each request.
    public let requestIdentifier: String
    public let environment: AppStoreEnvironment
    /// UNIX time in milliseconds at which the App Store signed the request. The engine uses this —
    /// never the server's wall clock — as "now" for every business rule.
    public let signedDate: Int64

    public init(
        originalTransactionId: String,
        appAppleId: Int64,
        productId: String,
        userLocale: String,
        requestIdentifier: String,
        environment: AppStoreEnvironment,
        signedDate: Int64
    ) {
        self.originalTransactionId = originalTransactionId
        self.appAppleId = appAppleId
        self.productId = productId
        self.userLocale = userLocale
        self.requestIdentifier = requestIdentifier
        self.environment = environment
        self.signedDate = signedDate
    }
}

/// The real-time response (`RealtimeResponseBody`).
///
/// Apple's object has four optional fields and says "if you supply this field, don't include
/// the other fields". An enum makes the illegal combinations unrepresentable instead of
/// relying on every call site to remember. (`advancedCommerceInfo`, which only applies to
/// Advanced Commerce API subscriptions, is out of scope.)
public enum RealtimeResponse: Sendable, Hashable {
    /// A text message, optionally with an image (`message`).
    case message(messageIdentifier: String)
    /// A switch-plan message (`alternateProduct`). The product must be in the same subscription group.
    case alternateProduct(messageIdentifier: String, productId: String)
    /// A message with a promotional offer (`promotionalOffer`), signed with a V2 (JWS) signature.
    case promotionalOffer(messageIdentifier: String, signatureV2: String)

    public var messageIdentifier: String {
        switch self {
        case .message(let id), .alternateProduct(let id, _), .promotionalOffer(let id, _):
            return id
        }
    }
}

extension RealtimeResponse: Codable {
    private enum RootKey: String, CodingKey {
        case message, alternateProduct, promotionalOffer
    }

    private enum FieldKey: String, CodingKey {
        case messageIdentifier, productId, promotionalOfferSignatureV2
    }

    public func encode(to encoder: any Encoder) throws {
        var root = encoder.container(keyedBy: RootKey.self)
        switch self {
        case .message(let id):
            var nested = root.nestedContainer(keyedBy: FieldKey.self, forKey: .message)
            try nested.encode(id, forKey: .messageIdentifier)
        case .alternateProduct(let id, let productId):
            var nested = root.nestedContainer(keyedBy: FieldKey.self, forKey: .alternateProduct)
            try nested.encode(id, forKey: .messageIdentifier)
            try nested.encode(productId, forKey: .productId)
        case .promotionalOffer(let id, let signature):
            var nested = root.nestedContainer(keyedBy: FieldKey.self, forKey: .promotionalOffer)
            try nested.encode(id, forKey: .messageIdentifier)
            try nested.encode(signature, forKey: .promotionalOfferSignatureV2)
        }
    }

    public init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: RootKey.self)
        guard root.allKeys.count == 1, let key = root.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Exactly one of message, alternateProduct or promotionalOffer is allowed"
            ))
        }
        let nested = try root.nestedContainer(keyedBy: FieldKey.self, forKey: key)
        let id = try nested.decode(String.self, forKey: .messageIdentifier)
        switch key {
        case .message:
            self = .message(messageIdentifier: id)
        case .alternateProduct:
            self = .alternateProduct(
                messageIdentifier: id,
                productId: try nested.decode(String.self, forKey: .productId)
            )
        case .promotionalOffer:
            self = .promotionalOffer(
                messageIdentifier: id,
                signatureV2: try nested.decode(String.self, forKey: .promotionalOfferSignatureV2)
            )
        }
    }

    /// Deterministic JSON bytes (sorted keys), so a replayed response is byte-identical.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// Signs a promotional offer for a real-time response.
///
/// Production implementations wrap Apple's App Store Server Library and your In-App Purchase
/// key. Signing happens inside the response budget, so the engine races it against the deadline
/// and degrades to a non-offer message if it is slow.
public protocol OfferSigner: Sendable {
    func signatureV2(productId: String, offerId: String, originalTransactionId: String) async throws -> String
}
