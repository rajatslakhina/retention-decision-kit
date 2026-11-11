import Foundation

/// Errors from parsing a JWS compact serialization.
public enum JWSError: Error, Sendable, Hashable {
    case tooLarge(bytes: Int)
    case malformed
    case invalidBase64URL
}

/// A JWS compact serialization split into its three parts (RFC 7515 §7.1).
///
/// This type only *parses*. It proves nothing about who signed the payload — that is the job of a
/// ``SignedPayloadVerifier``.
public struct CompactJWS: Sendable, Hashable {
    /// Requests are a few hundred bytes plus an x5c certificate chain; anything far larger is not
    /// from Apple, and decoding it would spend the response budget on an attacker.
    public static let maximumLength = 64 * 1024

    public let header: Data
    public let payload: Data
    public let signature: Data
    /// `BASE64URL(header) || "." || BASE64URL(payload)` — the bytes the signature covers.
    public let signingInput: String

    public init(parsing compact: String) throws {
        let length = compact.utf8.count
        guard length <= Self.maximumLength else { throw JWSError.tooLarge(bytes: length) }
        let parts = compact.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else { throw JWSError.malformed }
        guard
            let header = Self.decodeBase64URL(parts[0]),
            let payload = Self.decodeBase64URL(parts[1]),
            let signature = Self.decodeBase64URL(parts[2])
        else { throw JWSError.invalidBase64URL }
        self.header = header
        self.payload = payload
        self.signature = signature
        self.signingInput = String(parts[0]) + "." + String(parts[1])
    }

    /// Decodes unpadded base64url (RFC 4648 §5). Returns `nil` for any character outside the alphabet.
    public static func decodeBase64URL<S: StringProtocol>(_ text: S) -> Data? {
        var base64 = ""
        base64.reserveCapacity(text.utf8.count + 3)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9": base64.unicodeScalars.append(scalar)
            case "-": base64.append("+")
            case "_": base64.append("/")
            default: return nil
            }
        }
        switch base64.utf8.count % 4 {
        case 0: break
        case 2: base64.append("==")
        case 3: base64.append("=")
        default: return nil
        }
        return Data(base64Encoded: base64)
    }

    /// Encodes bytes as unpadded base64url.
    public static func encodeBase64URL(_ data: Data) -> String {
        var text = data.base64EncodedString()
        text = text.replacingOccurrences(of: "+", with: "-")
        text = text.replacingOccurrences(of: "/", with: "_")
        while text.hasSuffix("=") { text.removeLast() }
        return text
    }
}

/// Verifies a JWS and returns its payload.
///
/// Production implementations wrap Apple's App Store Server Library, which validates the x5c
/// certificate chain against Apple's root CA and checks the ES256 signature. This kit
/// deliberately does not reimplement X.509 path validation (build-vs-buy: buy). Verification runs
/// inside the response budget, so the endpoint races it against its own deadline.
public protocol SignedPayloadVerifier: Sendable {
    func verifiedPayload(of jws: CompactJWS) async throws -> Data
}

/// Accepts any well-formed JWS without checking its signature.
///
/// For unit tests and the offline demo **only**. Deploying this would let anyone on the internet
/// impersonate the App Store server.
public struct InsecureAcceptAnyVerifier: SignedPayloadVerifier {
    public init() {}
    public func verifiedPayload(of jws: CompactJWS) async throws -> Data { jws.payload }
}

public extension CompactJWS {
    /// Builds an unsigned compact JWS (`alg: none`) around `payload`. Test and demo fixture only.
    static func unsignedFixture<T: Encodable>(_ payload: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let header = try encoder.encode(["alg": "none", "typ": "JWT"])
        let body = try encoder.encode(payload)
        return encodeBase64URL(header) + "." + encodeBase64URL(body) + "."
    }
}
