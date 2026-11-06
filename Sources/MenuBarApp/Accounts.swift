import Foundation
import WebKit
import ChatGPTUsageCore

/// メニューから切り替えられる ChatGPT アカウント1件分。
///
/// アカウントごとに以下を分離して保存する:
/// - Keychain のアクセストークン(`keychainAccount`)
/// - 使用量のキャッシュ・履歴・通知状態(`storageNamespace`)
/// - ログイン用WebViewの Cookie 保存領域(`dataStore`)
///
/// `isLegacy` は複数アカウント対応前から使っていたアカウント。既存のデータをそのまま
/// 引き継ぐため、従来のキー名と既定の WebView 保存領域(`.default()`)を使う。
struct Account: Codable, Identifiable, Hashable {
    let id: String
    /// メニューに表示する名前(メールアドレス等)。未取得なら空文字。
    var label: String
    let isLegacy: Bool
    /// 同じアカウントへの再ログインを見分けるためのメールアドレス。取得できなければ nil。
    /// (表示名は組織名になる場合があり、別アカウントと同じになり得るため重複判定には使わない)
    var email: String?
    /// ログイン用WebViewの保存領域の識別子。nil は既定の保存領域(従来アカウント)。
    /// 再ログイン時に新しい保存領域へ差し替えられるよう、`id` とは別に持つ。
    var dataStoreID: String?

    static func makeNew() -> Account {
        let id = UUID().uuidString
        return Account(id: id, label: "", isLegacy: false, email: nil, dataStoreID: id)
    }

    var keychainAccount: String { isLegacy ? "accessToken" : "accessToken.\(id)" }
    var storageNamespace: String? { isLegacy ? nil : id }
    var dataStoreIdentifier: UUID? { dataStoreID.flatMap(UUID.init(uuidString:)) }

    func makeKeychain() -> KeychainStore { KeychainStore(account: keychainAccount) }

    @MainActor
    var dataStore: WKWebsiteDataStore { WebsiteDataStores.store(for: dataStoreIdentifier) }

    /// 表示用の名前。ラベル未取得時は一覧内の順番で「アカウント N」とする。
    func displayName(index: Int) -> String {
        label.isEmpty ? "アカウント\(index + 1)" : label
    }
}

/// アカウント一覧と選択中アカウントを UserDefaults に永続化する。
struct AccountRegistry {
    private enum Keys {
        static let accounts = "accounts"
        static let activeAccountID = "activeAccountID"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 保存済みの一覧を返す。初回(複数アカウント対応前からの利用者を含む)は、
    /// 既存データを引き継ぐ従来アカウント1件だけの一覧を作って保存する。
    func loadAccounts() -> [Account] {
        if let data = defaults.data(forKey: Keys.accounts),
           let accounts = try? JSONDecoder().decode([Account].self, from: data),
           !accounts.isEmpty {
            return accounts
        }
        let initial = [Account(id: UUID().uuidString, label: "", isLegacy: true, email: nil, dataStoreID: nil)]
        save(accounts: initial)
        return initial
    }

    func save(accounts: [Account]) {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: Keys.accounts)
    }

    var activeAccountID: String? {
        get { defaults.string(forKey: Keys.activeAccountID) }
        nonmutating set { defaults.set(newValue, forKey: Keys.activeAccountID) }
    }
}

/// アカウント別の WKWebsiteDataStore を管理する。
/// 同じ識別子の保存領域を何度も生成しないよう、インスタンスをキャッシュして使い回す。
@MainActor
enum WebsiteDataStores {
    private static var cache: [UUID: WKWebsiteDataStore] = [:]

    /// `identifier` が nil の場合は既定の保存領域(従来アカウント用)。
    static func store(for identifier: UUID?) -> WKWebsiteDataStore {
        guard let identifier else { return .default() }
        if let cached = cache[identifier] { return cached }
        let store = WKWebsiteDataStore(forIdentifier: identifier)
        cache[identifier] = store
        return store
    }

    /// 既定の保存領域(従来アカウント用)に残っているCookie等をすべて消す。
    static func clearDefaultStore() async {
        await WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        )
    }

    /// 保存領域をディスクから削除する。使用中のWebViewが解放されるまで削除できないことがあるため、
    /// 失敗しても無視する(次回起動時の `removeOrphans` で再度消される)。
    static func remove(_ identifier: UUID?) async {
        guard let identifier else { return }
        cache[identifier] = nil
        try? await WKWebsiteDataStore.remove(forIdentifier: identifier)
    }

    /// どのアカウントにも属さない保存領域(ログイン途中で閉じた、削除に失敗した等)を掃除する。
    static func removeOrphans(keeping accounts: [Account]) async {
        let keep = Set(accounts.compactMap(\.dataStoreIdentifier))
        let all = await WKWebsiteDataStore.allDataStoreIdentifiers
        for identifier in all where !keep.contains(identifier) {
            await remove(identifier)
        }
    }
}
