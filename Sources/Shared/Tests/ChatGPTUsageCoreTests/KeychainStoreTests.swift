import Testing
import Foundation
@testable import ChatGPTUsageCore

struct KeychainStoreTests {
    @Test func saveLoadAndClearRoundTrip() throws {
        // accessGroup: nil — the test binary isn't signed with the shared keychain-access-group
        // entitlement, so it must use the default (unshared) group to run outside Xcode.
        let store = KeychainStore(service: "test.chatgptusagemeter.\(UUID().uuidString)", account: "sessionCookie", accessGroup: nil)
        defer { store.clearToken() }

        #expect(store.loadToken() == nil)

        try store.saveToken("sessionKey=abc123; other=xyz")
        #expect(store.loadToken() == "sessionKey=abc123; other=xyz")

        // Saving again should overwrite (upsert), not throw a duplicate-item error.
        try store.saveToken("sessionKey=newvalue")
        #expect(store.loadToken() == "sessionKey=newvalue")

        store.clearToken()
        #expect(store.loadToken() == nil)
    }
}
