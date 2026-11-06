import Testing
import Foundation
@testable import ChatGPTUsageCore

struct AccessTokenClaimsTests {
    private func makeJWT(payload: String) -> String {
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJSUzI1NiJ9.\(encoded).signature"
    }

    @Test func readsEmailFromOpenAIProfileClaim() {
        let token = makeJWT(payload: #"{"https://api.openai.com/profile":{"email":"a@example.com"}}"#)
        #expect(AccessTokenClaims.email(fromJWT: token) == "a@example.com")
    }

    @Test func fallsBackToTopLevelEmail() {
        let token = makeJWT(payload: #"{"email":"b@example.com"}"#)
        #expect(AccessTokenClaims.email(fromJWT: token) == "b@example.com")
    }

    @Test func returnsNilForMalformedToken() {
        #expect(AccessTokenClaims.email(fromJWT: "not-a-jwt") == nil)
        #expect(AccessTokenClaims.email(fromJWT: makeJWT(payload: "{}")) == nil)
    }
}
