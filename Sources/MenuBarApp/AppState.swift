import Foundation
import Combine
import ChatGPTUsageCore

/// メニューバーアプリ全体の状態を保持し、Core層(ChatGPTUsageCore)とUIをつなぐオーケストレーター。
///
/// 責務:
/// - 起動時に Keychain のアクセストークンを確認し、使用量取得 -> 定期更新開始までの初期フローを実行する
/// - PollingScheduler による5分おきの定期更新
/// - 通知ON/OFFの永続化(UserDefaults.standard)
/// - トークン失効(401)時は WebView でトークンを1回だけ取り直し、それでもダメならログアウト状態へ遷移
@MainActor
final class AppState: ObservableObject {
    private enum Keys {
        static let notificationsEnabled = "notificationsEnabled"
    }

    @Published private(set) var loginState: LoginState = .checking
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var history: [HistoryPoint] = []
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }
    @Published private(set) var isRefreshing: Bool = false
    @Published var lastErrorMessage: String?

    private let store: UsageStore
    private let keychain: KeychainStore
    private let scheduler: PollingScheduler
    private let notificationManager: NotificationManager
    private let tokenRefreshService: TokenRefreshService
    private let defaults: UserDefaults
    private var apiClient: ChatGPTAPIClient?
    /// 401を受けてトークンの取り直しを試みた後、まだ成功していない間 true。
    /// 取り直したトークンでも401が返るケースで、取り直しが無限に繰り返されるのを防ぐ。
    private var authRecoveryAttempted = false

    init(
        store: UsageStore = UsageStore(),
        keychain: KeychainStore = KeychainStore(),
        scheduler: PollingScheduler = PollingScheduler(interval: 300),
        notificationManager: NotificationManager = NotificationManager(),
        tokenRefreshService: TokenRefreshService? = nil
    ) {
        self.store = store
        self.keychain = keychain
        self.scheduler = scheduler
        self.notificationManager = notificationManager
        self.defaults = .standard
        self.notificationsEnabled = (self.defaults.object(forKey: Keys.notificationsEnabled) as? Bool) ?? true
        // 直近のキャッシュ値を即座に表示できるよう、ネットワーク疎通前にロードしておく。
        self.snapshot = store.loadSnapshot()
        self.history = store.loadHistory()
        self.tokenRefreshService = tokenRefreshService ?? TokenRefreshService(keychain: keychain)

        self.tokenRefreshService.onLoginExpired = { [weak self] in
            Task { @MainActor in
                self?.markLoggedOut()
            }
        }
        self.tokenRefreshService.onTokenRefreshed = { [weak self] in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        self.tokenRefreshService.onRefreshInconclusive = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // 判定できなかっただけなので、次の401では改めて取り直しを試せるようにする。
                self.authRecoveryAttempted = false
                if self.loginState == .checking {
                    self.loginState = .error("ChatGPTへの接続を確認できませんでした")
                } else if self.loginState == .loggedIn {
                    self.lastErrorMessage = "ログイン情報の更新を確認できませんでした(次回の更新で再試行します)"
                }
            }
        }
    }

    /// アプリ起動時に一度だけ呼ぶ。
    func start() async {
        tokenRefreshService.start()
        await bootstrap()
    }

    /// トークンの有無を確認し、あれば使用量取得 -> 定期更新開始まで行う。
    /// 無ければ `.loggedOut` にして呼び出し側でログイン画面を出せるようにする。
    func bootstrap() async {
        guard let token = keychain.loadToken(), !token.isEmpty else {
            // 古い数字ではなく「要ログイン」を表示できるよう、キャッシュがあれば
            // needsLogin: true に付け替えて保存し直す。
            if snapshot != nil {
                markNeedsLoginSnapshot()
            }
            loginState = .loggedOut
            return
        }

        if apiClient == nil {
            apiClient = ChatGPTAPIClient(tokenProvider: { [keychain] in keychain.loadToken() })
        }
        if case .error = loginState {
            loginState = .checking
        }
        await refresh()
    }

    /// 「今すぐ更新」ボタンから呼ぶ。
    func refreshNow() {
        Task { await refresh() }
    }

    /// 現在の session / weekly のうち、より厳しい(percentが高い)方。どちらも無ければ nil。
    var dominantLimit: (label: String, limit: UsageLimit)? {
        guard let snapshot else { return nil }
        switch (snapshot.session, snapshot.weekly) {
        case let (s?, w?):
            return s.percent >= w.percent ? ("5時間制限", s) : ("週間制限", w)
        case let (s?, nil):
            return ("5時間制限", s)
        case let (nil, w?):
            return ("週間制限", w)
        case (nil, nil):
            return nil
        }
    }

    /// ログインウィンドウでの成功検知後に呼ぶ。トークンを保存し、初回データ取得をトリガーする。
    func handleLoginSucceeded(token: String) {
        do {
            try keychain.saveToken(token)
        } catch {
            lastErrorMessage = "トークンの保存に失敗しました: \(error)"
            return
        }
        authRecoveryAttempted = false
        loginState = .checking
        Task { await bootstrap() }
    }

    /// ログアウト操作(将来UIから呼べるように用意)。
    func logout() {
        scheduler.stop()
        keychain.clearToken()
        apiClient = nil
        loginState = .loggedOut
    }

    // MARK: - Private

    private func refresh() async {
        guard !isRefreshing else { return }
        guard let client = apiClient else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let newSnapshot = try await client.fetchUsage()
            let previous = self.snapshot
            self.snapshot = newSnapshot
            store.save(snapshot: newSnapshot)
            store.appendHistory(
                HistoryPoint(
                    timestamp: newSnapshot.fetchedAt,
                    sessionPercent: newSnapshot.session?.percent,
                    weeklyPercent: newSnapshot.weekly?.percent
                ),
                maxPoints: 288
            )
            self.history = store.loadHistory()

            if notificationsEnabled {
                notificationManager.evaluate(previous: previous, current: newSnapshot)
            }

            authRecoveryAttempted = false
            lastErrorMessage = nil
            if loginState != .loggedIn {
                loginState = .loggedIn
                scheduler.start { [weak self] in
                    await self?.refresh()
                }
            }
        } catch {
            handleFetchError(error)
        }
    }

    /// `refresh()` の失敗時ハンドラ。
    /// - 認証エラー(notLoggedIn/401/403): まず WebView でトークンを取り直す(アクセストークンは
    ///   数日で失効するが、WebView内のログインセッションはもっと長く有効なため)。
    ///   取り直しても直らなければログアウト状態にする。
    /// - それ以外(ネットワーク一時障害等): ログイン画面には落とさず、直前のsnapshotがあれば
    ///   `isStale: true` に付け替えて保存し直す(値はそのまま維持しつつ「古い可能性」を表せるように)。
    ///   初回取得(`.checking`)で失敗した場合は、再試行ボタンを出せるよう `.error` にする。
    private func handleFetchError(_ error: Error) {
        switch error {
        case ChatGPTAPIError.notLoggedIn, ChatGPTAPIError.httpError(401), ChatGPTAPIError.httpError(403):
            if !authRecoveryAttempted, keychain.loadToken() != nil {
                authRecoveryAttempted = true
                tokenRefreshService.refreshNow()
            } else {
                markLoggedOut()
            }
        default:
            if loginState == .checking {
                loginState = .error("使用量の取得に失敗しました: \(error)")
            } else {
                markStaleSnapshot()
                lastErrorMessage = "使用量の取得に失敗しました: \(error)"
            }
        }
    }

    private func markLoggedOut() {
        markNeedsLoginSnapshot()
        loginState = .loggedOut
    }

    /// 直前のsnapshotの値をそのまま(無ければnilのまま)引き継ぎつつ、
    /// `needsLogin: true` のsnapshotを組み立てて反映・永続化する。
    /// 直前のsnapshotが無い場合でも(要ログインを示すために)新規に組み立てる。
    private func markNeedsLoginSnapshot() {
        let updated = snapshot?.with(isStale: false, needsLogin: true)
            ?? UsageSnapshot(session: nil, weekly: nil, fetchedAt: Date(), isStale: false, needsLogin: true)
        snapshot = updated
        store.save(snapshot: updated)
    }

    /// 直前のsnapshotがあれば、値は変えずに `isStale: true` へ付け替えて反映・永続化する。
    /// 直前のsnapshotが無ければ何もしない(表示すべきデータ自体が無いため)。
    private func markStaleSnapshot() {
        guard let previous = snapshot else { return }
        let updated = previous.with(isStale: true, needsLogin: false)
        snapshot = updated
        store.save(snapshot: updated)
    }
}
