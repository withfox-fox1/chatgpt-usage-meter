import Foundation

/// Reads display-only information from a chatgpt.com access token (a JWT).
///
/// The signature is NOT verified: the result is used only as a label in the
/// account switcher, never for any security decision.
public enum AccessTokenClaims {
    /// The account's email address, or nil if the token does not carry one.
    public static func email(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let payload = decodeBase64URL(String(parts[1])),
              let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            return nil
        }
        if let profile = json["https://api.openai.com/profile"] as? [String: Any],
           let email = profile["email"] as? String, !email.isEmpty {
            return email
        }
        if let email = json["email"] as? String, !email.isEmpty {
            return email
        }
        return nil
    }

    private static func decodeBase64URL(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}
