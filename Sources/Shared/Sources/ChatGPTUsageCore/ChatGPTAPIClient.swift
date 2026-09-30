import Foundation

public enum ChatGPTAPIError: Error {
    case notLoggedIn
    case httpError(Int)
    case decodingFailed
    case network(Error)
}

/// Thin client around the (undocumented) chatgpt.com endpoint that Codex uses
/// to report its plan usage limits (`/backend-api/wham/usage`).
///
/// Authentication is a bearer access token: the caller supplies a closure that
/// returns the current token (or nil if there is no session yet); this type
/// never acquires/refreshes the token itself (that happens in a WKWebView via
/// `/api/auth/session`, because chatgpt.com's cookie endpoints sit behind
/// Cloudflare and reject plain URLSession requests).
public final class ChatGPTAPIClient {
    private let tokenProvider: () -> String?
    private let urlSession: URLSession
    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// Windows no longer than this are treated as the short "session" limit;
    /// longer ones as the weekly limit.
    private static let sessionWindowMaxSeconds = 24 * 60 * 60

    public init(tokenProvider: @escaping () -> String?, urlSession: URLSession = .shared) {
        self.tokenProvider = tokenProvider
        self.urlSession = urlSession
    }

    /// Fetches and parses the current usage snapshot.
    ///
    /// Robustness note: the response shape may evolve, so this never throws on
    /// a parsing problem once the HTTP call itself has succeeded — it always
    /// returns the best `UsageSnapshot` it can build (possibly with
    /// `session`/`weekly` set to nil individually).
    public func fetchUsage(now: Date = Date()) async throws -> UsageSnapshot {
        let data = try await performRequest(url: usageURL)

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ChatGPTAPIError.decodingFailed
        }

        let rateLimit = json["rate_limit"] as? [String: Any] ?? [:]
        let windows = ["primary_window", "secondary_window"].compactMap { key -> (seconds: Int?, limit: UsageLimit)? in
            guard let window = rateLimit[key] as? [String: Any] else { return nil }
            return Self.parseWindow(window, now: now)
        }

        // Classify by window length rather than primary/secondary position, so a
        // plan that only has a weekly window doesn't show it as the session one.
        var session: UsageLimit?
        var weekly: UsageLimit?
        for window in windows {
            let isSession = window.seconds.map { $0 <= Self.sessionWindowMaxSeconds } ?? (session == nil)
            if isSession, session == nil {
                session = UsageLimit(kind: "session", percent: window.limit.percent, resetsAt: window.limit.resetsAt, isActive: true)
            } else if weekly == nil {
                weekly = UsageLimit(kind: "weekly", percent: window.limit.percent, resetsAt: window.limit.resetsAt, isActive: true)
            }
        }

        return UsageSnapshot(
            session: session,
            weekly: weekly,
            fetchedAt: now,
            isStale: false,
            needsLogin: false,
            planType: json["plan_type"] as? String,
            limitReached: rateLimit["limit_reached"] as? Bool ?? false
        )
    }

    // MARK: - Request plumbing

    private func performRequest(url: URL) async throws -> Data {
        guard let token = tokenProvider(), !token.isEmpty else {
            throw ChatGPTAPIError.notLoggedIn
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw ChatGPTAPIError.network(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatGPTAPIError.decodingFailed
        }

        if httpResponse.statusCode == 401 {
            throw ChatGPTAPIError.notLoggedIn
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ChatGPTAPIError.httpError(httpResponse.statusCode)
        }

        return data
    }

    // MARK: - Lenient parsing

    /// Parses one `{used_percent, limit_window_seconds, reset_at, reset_after_seconds}`
    /// window. `reset_at` (epoch seconds) wins; `reset_after_seconds` is the fallback.
    /// Returns nil (rather than throwing) if no usable percent + reset time is present.
    private static func parseWindow(_ window: [String: Any], now: Date) -> (seconds: Int?, limit: UsageLimit)? {
        guard let percent = intValue(window["used_percent"]) else { return nil }

        let resetsAt: Date
        if let epoch = doubleValue(window["reset_at"]) {
            resetsAt = Date(timeIntervalSince1970: epoch)
        } else if let after = doubleValue(window["reset_after_seconds"]) {
            resetsAt = now.addingTimeInterval(after)
        } else {
            return nil
        }

        let limit = UsageLimit(kind: "", percent: percent, resetsAt: resetsAt, isActive: true)
        return (intValue(window["limit_window_seconds"]), limit)
    }

    private static func intValue(_ any: Any?) -> Int? {
        doubleValue(any).map { Int($0.rounded()) }
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let value = any as? NSNumber {
            return value.doubleValue
        }
        if let value = any as? String {
            return Double(value)
        }
        return nil
    }
}
