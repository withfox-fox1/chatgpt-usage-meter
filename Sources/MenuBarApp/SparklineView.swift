import SwiftUI
import ChatGPTUsageCore

/// 直近の使用率推移を示す簡易スパークライン。
///
/// dataviz方針: 識別(セッション/週間)は色だけに頼らず、線種(実線/破線)と凡例ラベルを併用する。
struct SparklineView: View {
    let history: [HistoryPoint]

    private static let sessionColor = Color.blue
    private static let weeklyColor = Color.purple

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            legend
            if history.isEmpty {
                Text("まだ推移データがありません")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(height: 44)
            } else {
                GeometryReader { geo in
                    ZStack {
                        gridLines(size: geo.size)
                        lineView(values: history.map(\.sessionPercent), color: Self.sessionColor, dashed: false, size: geo.size)
                        lineView(values: history.map(\.weeklyPercent), color: Self.weeklyColor, dashed: true, size: geo.size)
                    }
                }
                .frame(height: 44)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(color: Self.sessionColor, dashed: false, label: "5時間")
            legendItem(color: Self.weeklyColor, dashed: true, label: "週間")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendItem(color: Color, dashed: Bool, label: String) -> some View {
        HStack(spacing: 4) {
            ZStack {
                if dashed {
                    Rectangle()
                        .stroke(style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                        .foregroundStyle(color)
                } else {
                    Rectangle().fill(color)
                }
            }
            .frame(width: 12, height: 2)
            Text(label)
        }
    }

    private func gridLines(size: CGSize) -> some View {
        Path { path in
            for fraction in [0.0, 0.5, 1.0] {
                let y = size.height * (1 - fraction)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
    }

    private func lineView(values: [Int?], color: Color, dashed: Bool, size: CGSize) -> some View {
        let points = points(from: values, size: size)
        return Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: dashed ? [4, 3] : []))
    }

    private func points(from values: [Int?], size: CGSize) -> [CGPoint] {
        guard values.count > 1, size.width > 0, size.height > 0 else {
            // 1点しかない場合は水平線として描画できるよう、無理に補間はしない。
            if values.count == 1, let only = values[0] {
                let y = size.height - (CGFloat(only) / 100.0 * size.height)
                return [CGPoint(x: 0, y: y), CGPoint(x: size.width, y: y)]
            }
            return []
        }
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().compactMap { index, value in
            guard let value else { return nil }
            let x = CGFloat(index) * step
            let clamped = max(0, min(100, value))
            let y = size.height - (CGFloat(clamped) / 100.0 * size.height)
            return CGPoint(x: x, y: y)
        }
    }
}
