import SwiftUI
import UserNotifications
import ChatGPTUsageCore

@main
struct ChatGPTUsageMeterApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(appState: appState)
                .task {
                    await requestNotificationAuthorizationIfNeeded()
                    await appState.start()
                }
        } label: {
            MenuBarLabel(appState: appState)
        }
        .menuBarExtraStyle(.window)
    }

    /// NotificationManager (Core側) は通知の "内容判定" のみを担うため、OS権限のリクエストは
    /// アプリ側の責務として行う。ユーザーが後で設定から拒否していても問題なく動作する。
    private func requestNotificationAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }
}

/// メニューバー常時表示のラベル。ブランド色のアイコン(緑の六角形)+「5時間制限」の使用率。
/// 文字で横に長くしないよう、Claude版とはアイコンの形と色だけで見分ける。
/// 使用率は通常域ではメニューバー標準の文字色、注意/危険域では黄/赤で表示する。
/// データが無い/未ログインの場合も落ちないようにする。
private struct MenuBarLabel: View {
    @ObservedObject var appState: AppState

    var body: some View {
        // ステータスボタンには画像1枚+文字列しか載らないので、色付き要素は1枚に合成済みの画像を使う。
        if appState.loginState == .loggedOut {
            Image(nsImage: MenuBarIcon.loggedOutImage())
        } else if let session = appState.snapshot?.session {
            if let colored = MenuBarIcon.brandImage(percent: session.percent, severity: severity(of: session)) {
                Image(nsImage: colored)
            } else {
                HStack(spacing: 4) {
                    Image(nsImage: MenuBarIcon.brandImage())
                    Text("\(session.percent)%")
                }
            }
        } else {
            Image(nsImage: MenuBarIcon.brandImage())
        }
    }
}
