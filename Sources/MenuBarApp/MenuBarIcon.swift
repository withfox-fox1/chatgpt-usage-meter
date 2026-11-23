import AppKit
import SwiftUI
import ChatGPTUsageCore

/// メニューバーに出す画像の生成。
///
/// MenuBarExtra のラベルは標準ではテンプレート(単色)として描かれ、`foregroundStyle` の色は無視される。
/// アイコンは OpenAI 公式の Blossom(Assets の OpenAILogo、出典 openai.com/brand の公式ロゴ ZIP)。
/// ブランドガイドラインで Blossom への着色が禁じられているため、モノクロで表示する。
/// 単体表示はテンプレート画像にしてメニューバーの明暗に追従させ、警告マークや色付き数値と
/// 合成するときは `labelColor`(描画時の外観で解決される)で塗る。
///
/// MenuBarExtra のラベルはステータスボタンの「画像1枚+タイトル文字列」に変換されるため、
/// 2枚目以降の Image は表示されない。色付きの要素が複数ある場合は `composite` で1枚に合成して渡す。
enum MenuBarIcon {
    /// ChatGPT版の目印: OpenAI の Blossom(Claude版はオレンジの Claude ロゴ)。
    static let brandLogoName = "OpenAILogo"
    static let logoSize = NSSize(width: 16, height: 16)

    /// 単体で表示するアイコン。テンプレート画像なのでメニューバーの明暗に合わせて白/黒になる。
    /// `dimmed` は未ログイン時など、値が当てにならない状態に使う(合成用の半透明版を返す)。
    static func brandImage(dimmed: Bool = false) -> NSImage {
        if dimmed { return tintedLogo(alpha: 0.6) }
        let image = NSImage(size: logoSize, flipped: false) { rect in
            (NSImage(named: brandLogoName) ?? NSImage()).draw(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 合成用: ロゴを `labelColor` で塗った非テンプレート画像。
    /// 描画ハンドラ内で色を解決するので、メニューバーの外観(明/暗)に追従する。
    private static func tintedLogo(alpha: CGFloat = 1) -> NSImage {
        let base = NSImage(named: brandLogoName) ?? NSImage()
        let image = NSImage(size: logoSize, flipped: false) { rect in
            base.draw(in: rect)
            NSColor.labelColor.withAlphaComponent(alpha).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 未ログイン時の表示: 薄くしたアイコン + オレンジの警告マーク。
    static func loggedOutImage() -> NSImage {
        composite([brandImage(dimmed: true), coloredSymbol("exclamationmark.circle.fill", colors: [.white, .systemOrange])])
    }

    /// 注意/危険域の表示: アイコン + 黄/赤の使用率テキスト。
    /// 通常域では nil を返すので、呼び出し側は `brandImage()` + テンプレートの Text を使う
    /// (メニューバーの明暗に合わせて文字の白/黒が自動で切り替わるため)。
    static func brandImage(percent: Int, severity: UsageSeverity) -> NSImage? {
        guard let text = percentImage(percent, severity: severity) else { return nil }
        return composite([tintedLogo(), text])
    }

    private static func percentImage(_ percent: Int, severity: UsageSeverity) -> NSImage? {
        let color: NSColor
        switch severity {
        case .normal: return nil
        case .warning: color = .systemYellow
        case .critical: color = .systemRed
        }
        let text = NSAttributedString(
            string: "\(percent)%",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                .foregroundColor: color
            ]
        )
        let size = text.size()
        let image = NSImage(size: NSSize(width: ceil(size.width), height: ceil(size.height)), flipped: false) { rect in
            text.draw(in: rect)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 画像を横に並べ、上下中央揃えで1枚にする。
    private static func composite(_ images: [NSImage], spacing: CGFloat = 4) -> NSImage {
        let width = images.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(0, images.count - 1))
        let height = images.map(\.size.height).max() ?? 0
        let image = NSImage(size: NSSize(width: ceil(width), height: ceil(height)), flipped: false) { _ in
            var x: CGFloat = 0
            for part in images {
                let y = (height - part.size.height) / 2
                part.draw(in: NSRect(x: x, y: y, width: part.size.width, height: part.size.height))
                x += part.size.width + spacing
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// `colors` はシンボルのレイヤー順(例: exclamationmark.circle.fill なら [「!」, 丸])。
    /// 1色だけ渡すと全レイヤーが同じ色になり、「!」などの図柄が塗りつぶされて見えなくなる。
    private static func coloredSymbol(_ name: String, colors: [NSColor]) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: colors))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = false
        return image
    }
}
