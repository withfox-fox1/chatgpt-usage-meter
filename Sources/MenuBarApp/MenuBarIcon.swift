import AppKit
import SwiftUI
import ChatGPTUsageCore

/// メニューバーに出す画像の生成。
///
/// MenuBarExtra のラベルは標準ではテンプレート(単色)として描かれ、`foregroundStyle` の色は無視される。
/// Claude版メーターと並べても一目で見分けられるよう、アイコンはブランド色で塗った
/// 非テンプレート画像にして色を保持させる。
///
/// MenuBarExtra のラベルはステータスボタンの「画像1枚+タイトル文字列」に変換されるため、
/// 2枚目以降の Image は表示されない。色付きの要素が複数ある場合は `composite` で1枚に合成して渡す。
enum MenuBarIcon {
    /// ChatGPT版の目印: 緑の六角形(Claude版はオレンジの光)。
    static let brandSymbolName = "hexagon.fill"
    static let brandColor = NSColor(srgbRed: 0x10 / 255, green: 0xA3 / 255, blue: 0x7F / 255, alpha: 1)

    /// ブランド色で塗ったアイコン。`dimmed` は未ログイン時など、値が当てにならない状態に使う。
    static func brandImage(dimmed: Bool = false) -> NSImage {
        let color = dimmed ? brandColor.withAlphaComponent(0.6) : brandColor
        return coloredSymbol(brandSymbolName, colors: [color])
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
        return composite([brandImage(), text])
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
