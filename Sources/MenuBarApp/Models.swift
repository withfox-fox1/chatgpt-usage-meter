import Foundation

/// アプリ全体のログイン状態。
enum LoginState: Equatable {
    /// 起動直後、Keychainの確認やAPI疎通がまだ済んでいない状態。
    case checking
    /// トークンが無い、または失効している(要ログイン)。
    case loggedOut
    /// ログイン済みで通常運用中。
    case loggedIn
    /// 認証エラー以外の理由(ネットワーク一時障害等)で初期化に失敗した状態。
    /// ユーザーに見せるメッセージを保持し、再試行できるようにする。
    case error(String)
}
