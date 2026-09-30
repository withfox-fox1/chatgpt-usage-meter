import Testing
import Foundation
@testable import ChatGPTUsageCore

// Serialized because tests share the process-wide MockURLProtocol.requestHandler.
@Suite(.serialized)
struct ChatGPTAPIClientTests {
    private let now = Date(timeIntervalSince1970: 1_790_750_000)

    private func makeClient(token: String? = "tok-abc") -> ChatGPTAPIClient {
        ChatGPTAPIClient(tokenProvider: { token }, urlSession: MockURLProtocol.makeSession())
    }

    private func stub(status: Int, jsonString: String) {
        let data = jsonString.data(using: .utf8)!
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }
    }

    // MARK: - fetchUsage: real response shape (captured from chatgpt.com, Plus plan)

    @Test func fetchUsageParsesPrimaryAndSecondaryWindows() async throws {
        stub(status: 200, jsonString: """
        {
          "user_id": "user-x", "account_id": "acc-x", "email": "a@example.com",
          "plan_type": "plus",
          "rate_limit": {
            "allowed": true,
            "limit_reached": false,
            "primary_window": {"used_percent": 18, "limit_window_seconds": 18000, "reset_after_seconds": 18000, "reset_at": 1790772729},
            "secondary_window": {"used_percent": 16, "limit_window_seconds": 604800, "reset_after_seconds": 515131, "reset_at": 1791269860}
          },
          "code_review_rate_limit": null,
          "credits": {"has_credits": false, "unlimited": false, "balance": "0"}
        }
        """)
        defer { MockURLProtocol.requestHandler = nil }

        let snapshot = try await makeClient().fetchUsage(now: now)

        #expect(snapshot.session?.kind == "session")
        #expect(snapshot.session?.percent == 18)
        #expect(snapshot.session?.resetsAt == Date(timeIntervalSince1970: 1_790_772_729))
        #expect(snapshot.weekly?.kind == "weekly")
        #expect(snapshot.weekly?.percent == 16)
        #expect(snapshot.weekly?.resetsAt == Date(timeIntervalSince1970: 1_791_269_860))
        #expect(snapshot.planType == "plus")
        #expect(!snapshot.limitReached)
        #expect(snapshot.fetchedAt == now)
        #expect(!snapshot.isStale)
        #expect(!snapshot.needsLogin)
    }

    @Test func fetchUsageRoundsFractionalPercent() async throws {
        stub(status: 200, jsonString: """
        {"rate_limit": {"primary_window": {"used_percent": 42.6, "limit_window_seconds": 18000, "reset_at": 1790772729}}}
        """)
        defer { MockURLProtocol.requestHandler = nil }

        let snapshot = try await makeClient().fetchUsage(now: now)

        #expect(snapshot.session?.percent == 43)
    }

    @Test func fetchUsageFallsBackToResetAfterSeconds() async throws {
        stub(status: 200, jsonString: """
        {"rate_limit": {"primary_window": {"used_percent": 5, "limit_window_seconds": 18000, "reset_after_seconds": 600}}}
        """)
        defer { MockURLProtocol.requestHandler = nil }

        let snapshot = try await makeClient().fetchUsage(now: now)

        #expect(snapshot.session?.resetsAt == now.addingTimeInterval(600))
    }

    // MARK: - Classification by window length

    @Test func weeklyOnlyPrimaryWindowIsTreatedAsWeekly() async throws {
        stub(status: 200, jsonString: """
        {"rate_limit": {"primary_window": {"used_percent": 30, "limit_window_seconds": 604800, "reset_at": 1791269860}, "secondary_window": null}}
        """)
        defer { MockURLProtocol.requestHandler = nil }

        let snapshot = try await makeClient().fetchUsage(now: now)

        #expect(snapshot.session == nil)
        #expect(snapshot.weekly?.percent == 30)
    }

    @Test func limitReachedIsReported() async throws {
        stub(status: 200, jsonString: """
        {"rate_limit": {"limit_reached": true, "primary_window": {"used_percent": 100, "limit_window_seconds": 18000, "reset_at": 1790772729}}}
        """)
        defer { MockURLProtocol.requestHandler = nil }

        let snapshot = try await makeClient().fetchUsage(now: now)

        #expect(snapshot.limitReached)
        #expect(snapshot.session?.percent == 100)
    }

    // MARK: - Lenient parsing

    @Test func fetchUsageReturnsNilFieldsWithoutThrowingWhenBodyIsEmptyObject() async throws {
        stub(status: 200, jsonString: "{}")
        defer { MockURLProtocol.requestHandler = nil }

        let snapshot = try await makeClient().fetchUsage(now: now)

        #expect(snapshot.session == nil)
        #expect(snapshot.weekly == nil)
        #expect(snapshot.planType == nil)
        #expect(!snapshot.needsLogin)
    }

    @Test func malformedWindowIsSkipped() async throws {
        stub(status: 200, jsonString: """
        {"rate_limit": {
            "primary_window": {"limit_window_seconds": 18000, "reset_at": 1790772729},
            "secondary_window": {"used_percent": 16, "limit_window_seconds": 604800, "reset_at": 1791269860}
        }}
        """)
        defer { MockURLProtocol.requestHandler = nil }

        let snapshot = try await makeClient().fetchUsage(now: now)

        #expect(snapshot.session == nil)
        #expect(snapshot.weekly?.percent == 16)
    }

    // MARK: - Auth / HTTP errors

    @Test func fetchUsageThrowsNotLoggedInOn401() async throws {
        stub(status: 401, jsonString: "{}")
        defer { MockURLProtocol.requestHandler = nil }

        do {
            _ = try await makeClient().fetchUsage(now: now)
            Issue.record("Expected notLoggedIn to be thrown")
        } catch ChatGPTAPIError.notLoggedIn {
            // expected
        } catch {
            Issue.record("Expected notLoggedIn, got \(error)")
        }
    }

    @Test func fetchUsageThrowsNotLoggedInWhenNoToken() async throws {
        do {
            _ = try await makeClient(token: nil).fetchUsage(now: now)
            Issue.record("Expected notLoggedIn to be thrown")
        } catch ChatGPTAPIError.notLoggedIn {
            // expected
        } catch {
            Issue.record("Expected notLoggedIn, got \(error)")
        }
    }

    @Test func fetchUsageThrowsHttpErrorOnServerError() async throws {
        stub(status: 500, jsonString: "{}")
        defer { MockURLProtocol.requestHandler = nil }

        do {
            _ = try await makeClient().fetchUsage(now: now)
            Issue.record("Expected httpError to be thrown")
        } catch ChatGPTAPIError.httpError(let code) {
            #expect(code == 500)
        } catch {
            Issue.record("Expected httpError, got \(error)")
        }
    }

    @Test func bearerTokenIsSent() async throws {
        let box = CapturedRequestBox()
        MockURLProtocol.requestHandler = { request in
            box.authorization = request.value(forHTTPHeaderField: "Authorization")
            box.url = request.url
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, "{}".data(using: .utf8)!)
        }
        defer { MockURLProtocol.requestHandler = nil }

        _ = try await makeClient(token: "tok-xyz").fetchUsage(now: now)

        #expect(box.authorization == "Bearer tok-xyz")
        #expect(box.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
    }
}

private final class CapturedRequestBox: @unchecked Sendable {
    var authorization: String?
    var url: URL?
}
