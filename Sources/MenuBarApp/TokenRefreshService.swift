import Foundation
import AppKit
import WebKit
import ChatGPTUsageCore

/// 非表示(オフスクリーン)のWKWebViewで chatgpt.com を開き、`/api/auth/session` から
/// アクセストークンを再取得してKeychainに上書き保存する。
/// 1日1回の定期実行に加え、使用量APIが401を返したときにも `refreshNow()` で即時実行される。
/// `PollingScheduler`(使用量の定期取得)とは独立した、シンプルな `DispatchSourceTimer` ベースの仕組み。
///
/// WebView内のログインセッション(Cookie)自体が切れていてトークンが取れない場合は
/// `onLoginExpired` を呼び出し、呼び出し側(AppState)でメニューバー表示を「要ログイン」へ
/// 切り替えられるようにする。
@MainActor
final class TokenRefreshService {
    private let keychain: KeychainStore
    private let refreshInterval: TimeInterval
    private var timer: DispatchSourceTimer?
    private var hiddenWindow: NSWindow?
    private var webView: WKWebView?
    private var coordinator: RefreshCoordinator?
    private var timeoutWorkItem: DispatchWorkItem?

    /// トークンの再取得に成功した(=ログインはまだ有効)ときに呼ばれる。
    var onTokenRefreshed: (() -> Void)?
    /// 再取得を試みたがログインが切れていたときに呼ばれる。
    var onLoginExpired: (() -> Void)?
    /// タイムアウト等でログイン状態を判定できなかったときに呼ばれる(ログイン切れ扱いにはしない)。
    var onRefreshInconclusive: (() -> Void)?

    var isRefreshing: Bool { hiddenWindow != nil }

    init(keychain: KeychainStore, refreshInterval: TimeInterval = 60 * 60 * 24) {
        self.keychain = keychain
        self.refreshInterval = refreshInterval
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + refreshInterval, repeating: refreshInterval)
        t.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.refreshNow()
            }
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// 即時実行。
    func refreshNow() {
        guard keychain.loadToken() != nil else { return } // 未ログインなら何もしない
        guard hiddenWindow == nil else { return } // 実行中は多重起動しない
        guard let url = URL(string: "https://chatgpt.com/") else { return }

        let newWebView = WebViewLoginProbe.makeWebView()

        let newCoordinator = RefreshCoordinator(
            onSuccess: { [weak self] token in
                guard let self else { return }
                try? self.keychain.saveToken(token)
                self.teardownOffscreenWebView()
                self.onTokenRefreshed?()
            },
            onFailure: { [weak self] in
                guard let self else { return }
                self.teardownOffscreenWebView()
                self.onLoginExpired?()
            }
        )
        newWebView.navigationDelegate = newCoordinator
        self.webView = newWebView
        self.coordinator = newCoordinator

        // WKWebView は完全にウィンドウの外にあると読み込みが不安定になることがあるため、
        // 画面外に配置した非表示ウィンドウにぶら下げておく(表示はしない = orderBack のみ)。
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = newWebView
        window.orderBack(nil)
        self.hiddenWindow = window

        newWebView.load(URLRequest(url: url))

        // 一定時間内に成否が判定できなければ諦めて後片付けする(ネットワーク断など)。
        // タイムアウトはネットワーク不調等の可能性もあるためログイン切れ扱いにはしない。
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.teardownOffscreenWebView()
            self.onRefreshInconclusive?()
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: timeout)
    }

    private func teardownOffscreenWebView() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        hiddenWindow?.contentView = nil
        hiddenWindow?.close()
        hiddenWindow = nil
        webView?.navigationDelegate = nil
        webView = nil
        coordinator = nil
    }
}

/// オフスクリーンWebViewのナビゲーション監視 + トークン取得用コーディネータ。
/// トークン取得の実処理自体は `WebViewLoginProbe` に共通化しており、
/// `LoginWebView.Coordinator` とはライフサイクル(ウィンドウ表示の有無、
/// 呼び出し元へのコールバックの意味)が異なるためコーディネータとしては専用に実装している。
private final class RefreshCoordinator: NSObject, WKNavigationDelegate {
    private let onSuccess: (String) -> Void
    private let onFailure: () -> Void
    private var didFinishOnce = false

    init(onSuccess: @escaping (String) -> Void, onFailure: @escaping () -> Void) {
        self.onSuccess = onSuccess
        self.onFailure = onFailure
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Cloudflareのチェック画面を経由すると didFinish が複数回来るため、
        // トークンが取れるまでは毎回試す(取れないまま終わればタイムアウトで後片付け)。
        guard !didFinishOnce else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.didFinishOnce else { return }
            if let token = await WebViewLoginProbe.fetchAccessToken(webView: webView) {
                self.didFinishOnce = true
                self.onSuccess(token)
            } else if Self.isLoginPage(webView.url) {
                // ログインページへ飛ばされた = セッション切れ。
                self.didFinishOnce = true
                self.onFailure()
            } else if webView.url?.host?.hasSuffix("chatgpt.com") == true, await Self.sessionIsEmpty(webView: webView) {
                // chatgpt.com は未ログインでもトップページを表示するため、セッションが空かどうかで判定する。
                self.didFinishOnce = true
                self.onFailure()
            }
        }
    }

    // ネットワークエラーはログイン切れとは限らないため何もせず、タイムアウトでの後片付けに任せる。
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {}
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {}

    private static func isLoginPage(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.host?.hasPrefix("auth.") == true || url.path.hasPrefix("/auth/login")
    }

    /// `/api/auth/session` が 200 で空オブジェクト(`{}`)を返す = 未ログインが確定。
    @MainActor
    private static func sessionIsEmpty(webView: WKWebView) async -> Bool {
        let body = """
        try {
            const r = await fetch('/api/auth/session', { credentials: 'include' });
            if (!r.ok) return false;
            const j = await r.json();
            return !j || Object.keys(j).length === 0;
        } catch (e) {
            return false;
        }
        """
        let value = try? await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
        return (value as? Bool) ?? false
    }
}
