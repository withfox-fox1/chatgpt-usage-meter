import SwiftUI
import AppKit

/// ドロップダウン上部のアカウント切り替えメニュー。
/// 選択中アカウントの名前を表示し、クリックで「切り替え / 追加 / 削除」を選べる。
struct AccountSwitcher: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Menu {
            ForEach(appState.accounts) { account in
                Button {
                    appState.switchAccount(to: account.id)
                } label: {
                    if account.id == appState.activeAccountID {
                        Label(appState.displayName(of: account), systemImage: "checkmark")
                    } else {
                        Text(appState.displayName(of: account))
                    }
                }
            }

            Divider()

            Button {
                appState.beginAddAccount()
            } label: {
                Label("アカウントを追加…", systemImage: "plus")
            }

            if let active = appState.activeAccount {
                Button(role: .destructive) {
                    confirmRemoval(of: active)
                } label: {
                    Label("「\(appState.displayName(of: active))」を削除…", systemImage: "trash")
                }
                .disabled(appState.accounts.count <= 1)
            }
        } label: {
            Label(
                appState.activeAccount.map { appState.displayName(of: $0) } ?? "アカウント",
                systemImage: "person.crop.circle"
            )
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .help("アカウントを切り替え")
    }

    private func confirmRemoval(of account: Account) {
        let alert = NSAlert()
        alert.messageText = "「\(appState.displayName(of: account))」を削除しますか？"
        alert.informativeText = "このアカウントのログイン情報と使用量の履歴をこのMacから削除します。もう一度使うには再ログインが必要です。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "削除")
        alert.addButton(withTitle: "キャンセル")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            appState.removeAccount(id: account.id)
        }
    }
}
