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
/// - 複数アカウントの切り替え・追加・削除(使用量を取得するのは選択中のアカウントだけ)
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
    @Published private(set) var accounts: [Account]
    @Published private(set) var activeAccountID: String

    // 以下4つは選択中アカウント専用のインスタンス。切り替え時に作り直す。
    private var store: UsageStore
    private var keychain: KeychainStore
    private var notificationManager: NotificationManager
    private var apiClient: ChatGPTAPIClient?

    private let scheduler: PollingScheduler
    private let tokenRefreshService: TokenRefreshService
    private let defaults: UserDefaults
    private let registry: AccountRegistry
    private var didStart = false
    /// アカウントを切り替えるたびに増やす。通信の完了時に値が変わっていたら、
    /// その結果は切り替え前のアカウントのものなので破棄する。
    private var accountGeneration = 0
    /// 401を受けてトークンの取り直しを試みた後、まだ成功していない間 true。
    /// 取り直したトークンでも401が返るケースで、取り直しが無限に繰り返されるのを防ぐ。
    private var authRecoveryAttempted = false

    init(scheduler: PollingScheduler = PollingScheduler(interval: 300)) {
        let registry = AccountRegistry()
        let accounts = registry.loadAccounts()
        let active = accounts.first(where: { $0.id == registry.activeAccountID }) ?? accounts[0]
        registry.activeAccountID = active.id

        self.registry = registry
        self.accounts = accounts
        self.activeAccountID = active.id
        self.store = UsageStore(namespace: active.storageNamespace)
        self.keychain = active.makeKeychain()
        self.notificationManager = NotificationManager(namespace: active.storageNamespace)
        self.scheduler = scheduler
        self.defaults = .standard
        self.notificationsEnabled = (self.defaults.object(forKey: Keys.notificationsEnabled) as? Bool) ?? true
        // 直近のキャッシュ値を即座に表示できるよう、ネットワーク疎通前にロードしておく。
        self.snapshot = store.loadSnapshot()
        self.history = store.loadHistory()
        self.tokenRefreshService = TokenRefreshService(keychain: keychain, dataStore: active.dataStore)

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

    /// アプリ起動時に一度だけ呼ぶ(2回目以降は何もしない)。
    func start() async {
        guard !didStart else { return }
        didStart = true
        tokenRefreshService.start()
        await WebsiteDataStores.removeOrphans(keeping: accounts)
        await bootstrap()
    }

    // MARK: - Accounts

    var activeAccount: Account? { accounts.first(where: { $0.id == activeAccountID }) }

    func displayName(of account: Account) -> String {
        account.displayName(index: accounts.firstIndex(of: account) ?? 0)
    }

    /// メニューで別のアカウントを選んだときに呼ぶ。
    func switchAccount(to id: String) {
        guard id != activeAccountID, let account = accounts.first(where: { $0.id == id }) else { return }
        activate(account)
        Task { await bootstrap() }
    }

    /// 新しいアカウント用の(空の)保存領域でログインウィンドウを開き、ログインできたら一覧に加えて切り替える。
    func beginAddAccount() {
        let pending = Account.makeNew()
        LoginWindowController.shared.present(
            dataStore: pending.dataStore,
            onLoginDetected: { [weak self] token in
                Task { await self?.completeAddAccount(pending, token: token) }
            },
            onCancel: {
                Task { await WebsiteDataStores.remove(pending.dataStoreIdentifier) }
            }
        )
    }

    /// 選択中アカウントのログインウィンドウを開く(ログイン切れからの再ログイン用)。
    func beginLoginForActiveAccount() {
        guard let account = activeAccount else { return }
        LoginWindowController.shared.present(dataStore: account.dataStore) { [weak self] token in
            guard let self, self.activeAccountID == account.id else { return }
            self.handleLoginSucceeded(token: token)
        }
    }

    /// アカウントを一覧から削除し、保存していたトークン・使用量・WebViewのログイン情報も消す。
    /// 最後の1件は削除できない(削除するとログイン先が無くなるため)。
    func removeAccount(id: String) {
        guard accounts.count > 1, let account = accounts.first(where: { $0.id == id }) else { return }
        if account.id == activeAccountID, let next = accounts.first(where: { $0.id != id }) {
            activate(next)
            Task { await bootstrap() }
        }
        accounts.removeAll { $0.id == id }
        registry.save(accounts: accounts)
        Task { await purgeData(of: account) }
    }

    private func completeAddAccount(_ pending: Account, token: String) async {
        do {
            try pending.makeKeychain().saveToken(token)
        } catch {
            lastErrorMessage = "トークンの保存に失敗しました: \(error)"
            await WebsiteDataStores.remove(pending.dataStoreIdentifier)
            return
        }

        var added = pending
        added.email = AccessTokenClaims.email(fromJWT: token)
        added.label = added.email ?? ""

        // 同じアカウント(メールアドレスが一致)にもう一度ログインした場合は、既存のアカウントを残して
        // ログイン情報とWebViewの保存領域だけを新しいものに差し替える(使用量の履歴を消さないため)。
        if let email = added.email, let index = accounts.firstIndex(where: { $0.email == email }) {
            var existing = accounts[index]
            let oldDataStoreID = existing.dataStoreIdentifier
            try? existing.makeKeychain().saveToken(token)
            pending.makeKeychain().clearToken()
            existing.dataStoreID = pending.dataStoreID
            existing.label = added.label
            accounts[index] = existing
            registry.save(accounts: accounts)
            activate(existing)
            if let oldDataStoreID {
                await WebsiteDataStores.remove(oldDataStoreID)
            } else {
                await WebsiteDataStores.clearDefaultStore()
            }
        } else {
            accounts.append(added)
            registry.save(accounts: accounts)
            activate(added)
        }
        await bootstrap()
    }

    /// 選択中アカウントを切り替え、そのアカウント用のKeychain・保存先・通知状態に付け替える。
    private func activate(_ account: Account) {
        accountGeneration += 1
        scheduler.stop()
        isRefreshing = false
        apiClient = nil
        authRecoveryAttempted = false
        lastErrorMessage = nil

        activeAccountID = account.id
        registry.activeAccountID = account.id
        keychain = account.makeKeychain()
        store = UsageStore(namespace: account.storageNamespace)
        notificationManager = NotificationManager(namespace: account.storageNamespace)
        tokenRefreshService.setAccount(keychain: keychain, dataStore: account.dataStore)
        snapshot = store.loadSnapshot()
        history = store.loadHistory()
        loginState = .checking
    }

    private func purgeData(of account: Account) async {
        account.makeKeychain().clearToken()
        UsageStore(namespace: account.storageNamespace).clear()
        NotificationManager(namespace: account.storageNamespace).clear()
        if let identifier = account.dataStoreIdentifier {
            await WebsiteDataStores.remove(identifier)
        } else {
            // 従来アカウントは既定の保存領域を使っているので、その中身(ログインCookie等)を消す。
            await WebsiteDataStores.clearDefaultStore()
        }
    }

    /// メールアドレス未取得のアカウント(従来アカウント等)に、トークンに含まれるメールアドレスを付ける。
    private func updateLabelIfNeeded(token: String) {
        guard let index = accounts.firstIndex(where: { $0.id == activeAccountID }),
              accounts[index].email == nil,
              let email = AccessTokenClaims.email(fromJWT: token) else { return }
        accounts[index].email = email
        accounts[index].label = email
        registry.save(accounts: accounts)
    }

    /// URLSession のキャンセル(NSURLErrorCancelled = -999)や Task のキャンセルかどうか。
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case ChatGPTAPIError.network(let underlying) = error {
            return (underlying as? URLError)?.code == .cancelled || underlying is CancellationError
        }
        return (error as? URLError)?.code == .cancelled
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

        updateLabelIfNeeded(token: token)
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
        let generation = accountGeneration
        isRefreshing = true
        defer {
            // 切り替え後は activate() がリセット済みなので、新しいアカウントの更新中フラグを消さない。
            if generation == accountGeneration { isRefreshing = false }
        }

        do {
            let newSnapshot = try await client.fetchUsage()
            guard generation == accountGeneration else { return }
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
            // 切り替え前のアカウントの結果、または通信のキャンセル(-999)は状態に反映しない。
            guard generation == accountGeneration, !Self.isCancellation(error) else { return }
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
