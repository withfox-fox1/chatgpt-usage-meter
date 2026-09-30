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

/// メニューバー常時表示のラベル。常に「5時間制限」の使用率を
/// アイコン+テキストで表示する。Claude版メーターと並べても区別できるよう "GPT" を前置する。データが無い/未ログインの場合も落ちないようにする。
private struct MenuBarLabel: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbolName)
            if let session = appState.snapshot?.session {
                Text("GPT \(session.percent)%")
            } else {
                Text("GPT")
            }
        }
        .foregroundStyle(labelColor)
    }

    private var symbolName: String {
        if appState.loginState == .loggedOut {
            return "person.crop.circle.badge.exclamationmark"
        }
        guard let session = appState.snapshot?.session else {
            return "gauge.with.dots.needle.bottom.0percent"
        }
        return severity(of: session).gaugeSymbolName
    }

    private var labelColor: Color {
        if appState.loginState == .loggedOut {
            return .orange
        }
        guard let session = appState.snapshot?.session else {
            return .primary
        }
        return severity(of: session).accentColor
    }
}
