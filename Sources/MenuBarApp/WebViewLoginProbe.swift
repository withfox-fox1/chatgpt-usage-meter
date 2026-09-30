import Foundation
import WebKit

/// `LoginWebView.Coordinator`(ログイン画面)と `TokenRefreshService.RefreshCoordinator`
/// (バックグラウンドでのトークン再取得)の両方が必要とする、
/// 「chatgpt.com のページ内から `/api/auth/session` を叩き、ログイン済みならアクセストークンを取り出す」
/// という手順を共通化した小さなヘルパー。
///
/// chatgpt.com のCookie系エンドポイントはCloudflareの保護下にあり、URLSessionから直接叩くと403になる。
/// そのためトークン取得だけはWebView(=本物のブラウザ)の中で行い、取れたトークンで
/// `ChatGPTAPIClient` が使用量APIを叩く。
///
/// ライフサイクル管理(ウィンドウの表示/非表示、タイムアウト、コールバックの意味づけ)は
/// 呼び出し側ごとに異なるため、そこは各Coordinatorに残し、ここには純粋なWebView操作だけを置く。
enum WebViewLoginProbe {
    /// Googleアカウント等でのログインは「埋め込みWebView」のUAだと拒否されるため、Safari相当のUAを名乗る。
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// ログイン画面・バックグラウンド再取得で共通のWebView設定(Cookieはアプリ内の既定ストアに永続化)。
    @MainActor
    static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = userAgent
        return webView
    }

    /// `/api/auth/session` を叩き、ログイン済みなら `accessToken` を返す。
    /// 未ログイン・chatgpt.com以外のページ(ログイン途中の認証画面など)・JS実行失敗の場合は `nil`。
    @MainActor
    static func fetchAccessToken(webView: WKWebView) async -> String? {
        guard webView.url?.host?.hasSuffix("chatgpt.com") == true else { return nil }
        let body = """
        try {
            const r = await fetch('/api/auth/session', { credentials: 'include' });
            if (!r.ok) return null;
            const j = await r.json();
            return (j && typeof j.accessToken === 'string') ? j.accessToken : null;
        } catch (e) {
            return null;
        }
        """
        guard let value = try? await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page),
              let token = value as? String, !token.isEmpty else {
            return nil
        }
        return token
    }
}
