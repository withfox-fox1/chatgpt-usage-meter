import SwiftUI
import ChatGPTUsageCore

/// メニューバーアイコンをクリックした時に開くドロップダウンの中身。
/// `AppState` のあらゆるプロパティは初期状態(nil/空配列)でも安全に扱う。
struct MenuBarContentView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            switch appState.loginState {
            case .checking:
                checkingView
            case .loggedOut:
                loggedOutView
            case .loggedIn:
                loggedInView
            case .error(let message):
                errorView(message: message)
            }

            if let errorMessage = appState.lastErrorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label {
                Text("ChatGPT使用量メーター")
            } icon: {
                Image(systemName: MenuBarIcon.brandSymbolName)
                    .foregroundStyle(Color(nsColor: MenuBarIcon.brandColor))
            }
            .font(.headline)
            if let plan = appState.snapshot?.planType, !plan.isEmpty {
                Text(plan.capitalized)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Spacer()
            if appState.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - States

    private var checkingView: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("確認しています…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func errorView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("読み込みに失敗しました", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await appState.bootstrap() }
            } label: {
                Label("再試行", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var loggedOutView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("ログインが必要です", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("ChatGPT のログインセッションが見つからないか、期限切れです。ログインすると使用量の取得を再開します。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                LoginWindowController.shared.present { token in
                    appState.handleLoginSucceeded(token: token)
                }
            } label: {
                Label("ログイン", systemImage: "arrow.right.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var loggedInView: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let snapshot = appState.snapshot {
                dominantHighlight(snapshot: snapshot)

                if snapshot.limitReached {
                    Label("使用上限に達しています", systemImage: "hand.raised.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }

                UsageProgressBar(
                    title: "5時間制限",
                    limit: snapshot.session,
                    resetDescription: { UsageFormatting.relativeResetString($0) },
                    isEmphasized: isDominant(snapshot.session, in: snapshot)
                )

                UsageProgressBar(
                    title: "週間制限",
                    limit: snapshot.weekly,
                    resetDescription: { UsageFormatting.absoluteResetString($0) },
                    isEmphasized: isDominant(snapshot.weekly, in: snapshot)
                )

                Divider()

                SparklineView(history: appState.history)

                Divider()

                footerRow(snapshot: snapshot)
            } else {
                emptyStateView
            }

            Toggle("しきい値に達したら通知する", isOn: $appState.notificationsEnabled)
                .toggleStyle(.switch)
                .font(.caption)
        }
    }

    private var emptyStateView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("まだ使用量データがありません")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                appState.refreshNow()
            } label: {
                Label("今すぐ取得", systemImage: "arrow.clockwise")
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Components

    @ViewBuilder
    private func dominantHighlight(snapshot: UsageSnapshot) -> some View {
        if let dominant = appState.dominantLimit {
            let sev = severity(of: dominant.limit)
            HStack(spacing: 8) {
                Image(systemName: sev.symbolName)
                    .foregroundStyle(sev.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("主な注意対象: \(dominant.label)")
                        .font(.caption.weight(.semibold))
                    Text("\(sev.label) ・ \(dominant.limit.percent)% 使用中")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(8)
            .background(sev.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func isDominant(_ limit: UsageLimit?, in snapshot: UsageSnapshot) -> Bool {
        guard let limit, let dominant = appState.dominantLimit else { return false }
        return dominant.limit == limit
    }

    private func footerRow(snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最終更新: \(UsageFormatting.relativeUpdateString(snapshot.fetchedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if snapshot.isStale {
                    Label("古い可能性", systemImage: "clock.badge.exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button {
                    appState.refreshNow()
                } label: {
                    Label("今すぐ更新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appState.isRefreshing)
            }
        }
    }
}
