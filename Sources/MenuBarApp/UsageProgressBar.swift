import SwiftUI
import ChatGPTUsageCore

/// 1本の使用率バー(セッション or 週間)。
/// 色 + アイコン + パーセント数値 + リセット時刻文言、をワンセットで表示する。
struct UsageProgressBar: View {
    let title: String
    let limit: UsageLimit?
    /// リセット時刻の文言化(相対 or 絶対はケースによって呼び出し側が選ぶ)。
    let resetDescription: (Date) -> String
    var isEmphasized: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 4) {
                    if isEmphasized {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(.subheadline.weight(isEmphasized ? .bold : .semibold))
                }
                Spacer()
                percentLabel
            }
            barTrack
            if let limit {
                Text(resetDescription(limit.resetsAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("データなし")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var percentLabel: some View {
        if let limit {
            let sev = severity(of: limit)
            Label("\(limit.percent)%", systemImage: sev.symbolName)
                .font(.subheadline)
                .foregroundStyle(sev.accentColor)
                .accessibilityLabel("\(title) \(sev.label) \(limit.percent)パーセント")
        } else {
            Text("--")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var barTrack: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))
                if let limit {
                    let sev = severity(of: limit)
                    let fraction = CGFloat(max(0, min(100, limit.percent))) / 100.0
                    RoundedRectangle(cornerRadius: 4)
                        .fill(sev.accentColor)
                        .frame(width: max(4, geo.size.width * fraction))
                }
            }
        }
        .frame(height: 8)
    }
}
