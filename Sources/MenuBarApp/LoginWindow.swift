import SwiftUI
import AppKit
import WebKit

// MARK: - ログイン用 WKWebView

/// chatgpt.com のログインページを表示する WKWebView ラッパー。
///
/// - このアプリ自身はメールアドレス/パスワードを一切扱わない。あくまでユーザーが
///   ページ上で直接入力し、chatgpt.com(またはGoogle等の認証プロバイダ)に送信する。
/// - ログイン成功の検知は、ページ遷移が終わるたびに `/api/auth/session` を叩き、
///   アクセストークンが返るかで判定する。
/// - 成功したらアクセストークンをコールバックで呼び出し元に渡す(呼び出し元が Keychain へ保存する)。
struct LoginWebView: NSViewRepresentable {
    let url: URL
    let onLoginDetected: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoginDetected: onLoginDetected)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WebViewLoginProbe.makeWebView()
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        // no-op: ナビゲーションは Coordinator が管理する
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onLoginDetected: (String) -> Void
        private var didSucceed = false

        init(onLoginDetected: @escaping (String) -> Void) {
            self.onLoginDetected = onLoginDetected
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !didSucceed else { return }
            checkLoginStatus(webView: webView)
        }

        /// ページ遷移完了ごとに /api/auth/session を叩いてログイン済みか確認する。
        /// fetch は Promise を返すので、Promise解決まで待てる callAsyncJavaScript を使う
        /// (素の evaluateJavaScript は Promise オブジェクト自体を返してしまい解決値を取れないため)。
        private func checkLoginStatus(webView: WKWebView) {
            guard !didSucceed else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.didSucceed else { return }
                guard let token = await WebViewLoginProbe.fetchAccessToken(webView: webView), !self.didSucceed else {
                    // 失敗時は何もしない(未ログイン状態が続いているだけの可能性が高く、次のページ遷移で再判定する)。
                    return
                }
                self.didSucceed = true
                self.onLoginDetected(token)
            }
        }
    }
}

// MARK: - ログイン画面(説明文 + WebView)

struct LoginContentView: View {
    let onLoginDetected: (String) -> Void

    private var loginURL: URL {
        URL(string: "https://chatgpt.com/auth/login")!
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Label("ChatGPTにログイン", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.headline)
                Text(
                    "これはお使いのブラウザ(Safari / Chrome など)のログイン状態とは別の、"
                    + "このアプリ専用のログインです。下のページで直接メールアドレスやパスワードを入力してください。"
                    + "本アプリはパスワードを一切保存・送信せず、ログイン後に発行されるアクセストークンのみを"
                    + "このMac内のKeychainに安全に保管します。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding()

            Divider()

            LoginWebView(url: loginURL, onLoginDetected: onLoginDetected)
                .frame(minWidth: 480, minHeight: 560)
        }
    }
}

// MARK: - ウィンドウ表示

/// ログイン用の独立ウィンドウを管理する。MenuBarExtra には標準ウィンドウが無いため、
/// 明示的に NSWindow を生成して前面に出す。
@MainActor
final class LoginWindowController {
    static let shared = LoginWindowController()

    private var window: NSWindow?

    private init() {}

    func present(onLoginDetected: @escaping (String) -> Void) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = LoginContentView(onLoginDetected: { [weak self] token in
            onLoginDetected(token)
            self?.close()
        })

        let hosting = NSHostingController(rootView: contentView)
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "ChatGPTにログイン"
        newWindow.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        newWindow.setContentSize(NSSize(width: 480, height: 680))
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = WindowCloseObserver.shared
        WindowCloseObserver.shared.onClose = { [weak self] in self?.window = nil }

        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }
}

/// NSWindowDelegate はクラス毎にインスタンスが必要なため、ユーザーが手動でウィンドウの
/// 閉じるボタンを押した場合の後始末だけを行う小さなオブザーバ。
private final class WindowCloseObserver: NSObject, NSWindowDelegate {
    static let shared = WindowCloseObserver()
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
