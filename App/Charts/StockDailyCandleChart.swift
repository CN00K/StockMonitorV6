import SwiftUI
import StockMonitorCore

@MainActor
struct StockDailyCandleChart: View {
    @Environment(\.stockMonitorPalette) private var palette
    let bars: [DailyBar]

    private var lowestPrice: Double { bars.map(\.low).min() ?? 0 }
    private var highestPrice: Double { bars.map(\.high).max() ?? 0 }
    private var scalePadding: Double {
        let range = highestPrice - lowestPrice
        return max(range * 0.06, max(abs(highestPrice) * 0.002, 0.01))
    }
    private var scaleMinimum: Double { max(0, lowestPrice - scalePadding) }
    private var scaleMaximum: Double { highestPrice + scalePadding }
    private var scaleRange: Double { max(scaleMaximum - scaleMinimum, 0.01) }

    var body: some View {
        VStack(spacing: StockMonitorTokens.Space.small) {
            HStack(alignment: .top, spacing: StockMonitorTokens.Space.small) {
                priceAxis
                candlePlot
            }
            dateAxis
        }
        .padding(StockMonitorTokens.Space.small)
        .background(palette.paper2, in: RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.small))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chartDescription)
    }

    private var priceAxis: some View {
        VStack(alignment: .trailing) {
            axisValue(scaleMaximum)
            Spacer(minLength: 0)
            axisValue((scaleMaximum + scaleMinimum) / 2)
            Spacer(minLength: 0)
            axisValue(scaleMinimum)
        }
        .frame(width: 48, height: StockMonitorTokens.Size.chartSkeletonHeight + 38, alignment: .topTrailing)
        .accessibilityHidden(true)
    }

    private func axisValue(_ value: Double) -> some View {
        Text(ChartFormatters.price(value))
            .font(.system(size: 10, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(palette.inkMuted)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var candlePlot: some View {
        let chartScaleMaximum = scaleMaximum
        let chartScaleRange = scaleRange
        return Canvas { context, size in
            guard !bars.isEmpty else { return }

            let topInset: CGFloat = 7
            let bottomInset: CGFloat = 7
            let plotHeight = max(1, size.height - topInset - bottomInset)
            func yPosition(_ price: Double) -> CGFloat {
                topInset + CGFloat((chartScaleMaximum - price) / chartScaleRange) * plotHeight
            }

            var grid = Path()
            for fraction in [CGFloat(0), 0.5, 1] {
                let y = topInset + fraction * plotHeight
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid,
                           with: .color(palette.hair.opacity(StockMonitorTokens.Opacity.chartGrid)),
                           lineWidth: StockMonitorTokens.Size.hairline)

            let slotWidth = size.width / CGFloat(bars.count)
            let bodyWidth = min(8, max(1.5, slotWidth * 0.58))
            for (index, bar) in bars.enumerated() {
                let centerX = (CGFloat(index) + 0.5) * slotWidth
                let color = candleColor(for: bar)

                var wick = Path()
                wick.move(to: CGPoint(x: centerX, y: yPosition(bar.high)))
                wick.addLine(to: CGPoint(x: centerX, y: yPosition(bar.low)))
                context.stroke(wick, with: .color(color), lineWidth: 1)

                let openY = yPosition(bar.open)
                let closeY = yPosition(bar.close)
                let bodyTop = min(openY, closeY)
                let bodyHeight = max(abs(closeY - openY), 1.5)
                let body = CGRect(x: centerX - bodyWidth / 2, y: bodyTop,
                                  width: bodyWidth, height: bodyHeight)
                context.fill(Path(body), with: .color(color))
            }
        }
        .frame(height: StockMonitorTokens.Size.chartSkeletonHeight + 38)
    }

    private var dateAxis: some View {
        HStack {
            if let first = bars.first {
                dateLabel(first.tradeDate)
            }
            Spacer(minLength: 0)
            if bars.count > 2 {
                dateLabel(bars[bars.count / 2].tradeDate)
            }
            Spacer(minLength: 0)
            if let last = bars.last, bars.count > 1 {
                dateLabel(last.tradeDate)
            }
        }
        .padding(.leading, 48 + StockMonitorTokens.Space.small)
        .accessibilityHidden(true)
    }

    private func dateLabel(_ date: Date) -> some View {
        Text(date.formatted(date: .abbreviated, time: .omitted))
            .font(.system(size: StockMonitorTokens.TypeScale.caption))
            .foregroundStyle(palette.inkMuted)
            .lineLimit(1)
    }

    private func candleColor(for bar: DailyBar) -> Color {
        if bar.close > bar.open { return palette.dataUp }
        if bar.close < bar.open { return palette.dataDown }
        return palette.dataFlat
    }

    private var chartDescription: String {
        guard let first = bars.first, let last = bars.last else { return "没有本机缓存日K线" }
        return "本机未复权日K线，共 \(bars.count) 条；从 \(first.tradeDate.formatted(date: .complete, time: .omitted)) 到 \(last.tradeDate.formatted(date: .complete, time: .omitted))。每根蜡烛表示一条缓存日线的开盘、最高、最低和收盘价；不是逐笔行情。"
    }
}
