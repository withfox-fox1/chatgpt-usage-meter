import SwiftUI
import ChatGPTUsageCore

// MARK: - Severity -> 見た目のマッピング
//
// dataviz スキル方針に準拠: 色だけに頼らず、アイコン(形状)とラベル(文言)を必ず併記する。
// 色覚多様性のあるユーザーでも "正常/注意/危険" が判別できるようにする。
extension UsageSeverity {
    /// 状態を表す基調色。単独では使わず、必ず symbolName / label と併用すること。
    var accentColor: Color {
        switch self {
        case .normal: return .green
        case .warning: return .yellow
        case .critical: return .red
        }
    }

    /// 状態を形状でも判別できるようにするための SF Symbol。
    var symbolName: String {
        switch self {
        case .normal: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    /// 状態を表す短い日本語ラベル。
    var label: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "注意"
        case .critical: return "危険"
        }
    }
}

/// UsageLimit の percent から severity を求めるショートハンド。
func severity(of limit: UsageLimit) -> UsageSeverity {
    severity(forPercent: limit.percent)
}
