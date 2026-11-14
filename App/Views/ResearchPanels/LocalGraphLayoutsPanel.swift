import SwiftUI
import StockMonitorCore

/// A presentation-only visualization for already-computed local graph layouts.
/// Missing layouts remain explicitly unknown/partial; this view never synthesizes graph data.
struct LocalGraphLayoutsPanel: View {
    let sankeyLayout: SankeyLayout?
    let forceGraphLayout: ForceGraphLayout?
    let missingDataExplanation: String

    @Environment(\.stockMonitorPalette) private var palette

    init(
        sankeyLayout: SankeyLayout? = nil,
        forceGraphLayout: ForceGraphLayout? = nil,
        missingDataExplanation: String
    ) {
        self.sankeyLayout = sankeyLayout
        self.forceGraphLayout = forceGraphLayout
        self.missingDataExplanation = missingDataExplanation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.large) {
            Text("本地关系图")
                .font(.system(size: StockMonitorTokens.TypeScale.title, weight: .semibold))
                .foregroundStyle(palette.inkPrimary)

            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                layoutSection(title: "事件来源 → 板块关联数（非资金流）", layout: sankeyLayout,
                              hasRecords: { !$0.nodes.isEmpty }) {
                    SankeyCanvas(layout: $0)
                }
                layoutSection(title: "因子相关网络（连线值为 |r|；正负见矩阵）", layout: forceGraphLayout,
                              hasRecords: { !$0.nodes.isEmpty }) {
                    ForceGraphCanvas(layout: $0)
                }
            }
        }
        .padding(StockMonitorTokens.Space.large)
        .background(palette.paper1, in: RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.panel))
        .overlay {
            RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.panel)
                .stroke(palette.hair, lineWidth: StockMonitorTokens.Size.hairline)
        }
    }

    @ViewBuilder
    private func layoutSection<Layout, Content: View>(
        title: String,
        layout: Layout?,
        hasRecords: (Layout) -> Bool,
        @ViewBuilder content: (Layout) -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
            Text(title)
                .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                .foregroundStyle(palette.inkPrimary)

            if let layout, hasRecords(layout) {
                content(layout)
            } else {
                missingState(title: title)
            }
        }
    }

    @ViewBuilder
    private func missingState(title: String) -> some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
            Label("未知 / 部分数据", systemImage: "questionmark.diamond")
                .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .semibold))
                .foregroundStyle(palette.inkSecondary)
            Text(missingDataExplanation)
                .font(.system(size: StockMonitorTokens.TypeScale.footnote))
                .foregroundStyle(palette.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.heroSkeletonHeight, alignment: .leading)
        .padding(StockMonitorTokens.Space.medium)
        .background(palette.paper2, in: RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.medium))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，未知或部分数据。\(missingDataExplanation)")
    }
}

private struct SankeyCanvas: View {
    let layout: SankeyLayout
    @Environment(\.stockMonitorPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
            GeometryReader { proxy in
                Canvas { context, size in
                    let bounds = GraphCanvasBounds.sankey(layout, in: size)
                    drawSankey(layout, in: &context, bounds: bounds)
                }
                .frame(minHeight: StockMonitorTokens.Size.heroSkeletonHeight)
            }
            .frame(minHeight: StockMonitorTokens.Size.heroSkeletonHeight)
            .background(palette.paper0, in: RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.medium))
            .accessibilityElement()
            .accessibilityLabel(Text(accessibilityDescription))

            GraphDataSummary(sankey: layout)
        }
    }

    private var accessibilityDescription: String {
        let nodeText = layout.nodes.map { node in
            "节点 \(node.id)，值 \(GraphLabel.value(node.value))"
        }.joined(separator: "; ")
        let linkText = layout.links.map { link in
            "连接 \(link.sourceID) 到 \(link.targetID)，值 \(GraphLabel.value(link.value))"
        }.joined(separator: "; ")
        return "桑基关系图。\(nodeText)。\(linkText)"
    }

    private func drawSankey(_ layout: SankeyLayout, in context: inout GraphicsContext, bounds: GraphCanvasBounds) {
        let nodes = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0) })
        for link in layout.links {
            guard let source = nodes[link.sourceID], let target = nodes[link.targetID],
                  link.value.isFinite, link.thickness.isFinite else { continue }
            let sourcePoint = bounds.sankeyPoint(x: source.x + source.width, y: link.sourceY)
            let targetPoint = bounds.sankeyPoint(x: target.x, y: link.targetY)
            var path = Path()
            path.move(to: sourcePoint)
            path.addCurve(to: targetPoint,
                          control1: CGPoint(x: (sourcePoint.x + targetPoint.x) / 2, y: sourcePoint.y),
                          control2: CGPoint(x: (sourcePoint.x + targetPoint.x) / 2, y: targetPoint.y))
            context.stroke(path, with: .color(palette.flowOut.opacity(0.55)), lineWidth: bounds.lineWidth(for: link.thickness))
        }
        for node in layout.nodes {
            guard node.x.isFinite, node.y.isFinite, node.width.isFinite, node.height.isFinite else { continue }
            let rect = bounds.sankeyRect(x: node.x, y: node.y, width: node.width, height: node.height)
            context.fill(Path(roundedRect: rect, cornerRadius: StockMonitorTokens.Radius.small), with: .color(palette.accent))
            context.stroke(Path(roundedRect: rect, cornerRadius: StockMonitorTokens.Radius.small), with: .color(palette.paper1), lineWidth: StockMonitorTokens.Size.hairline)
        }
    }
}

private struct ForceGraphCanvas: View {
    let layout: ForceGraphLayout
    @Environment(\.stockMonitorPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
            GeometryReader { proxy in
                Canvas { context, size in
                    let bounds = GraphCanvasBounds.force(layout, in: size)
                    drawForceGraph(layout, in: &context, bounds: bounds)
                }
                .frame(minHeight: StockMonitorTokens.Size.heroSkeletonHeight)
            }
            .frame(minHeight: StockMonitorTokens.Size.heroSkeletonHeight)
            .background(palette.paper0, in: RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.medium))
            .accessibilityElement()
            .accessibilityLabel(Text(accessibilityDescription))

            GraphDataSummary(force: layout)
        }
    }

    private var accessibilityDescription: String {
        let nodeText = layout.nodes.map { "节点 \($0.id)，位置 \(GraphLabel.coordinate($0.x)), \(GraphLabel.coordinate($0.y))" }.joined(separator: "; ")
        let linkText = layout.links.map { "连接 \($0.sourceID) 到 \($0.targetID)，值 \(GraphLabel.value($0.value))" }.joined(separator: "; ")
        return "力导向关系图。\(nodeText)。\(linkText)"
    }

    private func drawForceGraph(_ layout: ForceGraphLayout, in context: inout GraphicsContext, bounds: GraphCanvasBounds) {
        let nodes = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0) })
        for link in layout.links {
            guard let source = nodes[link.sourceID], let target = nodes[link.targetID], link.value.isFinite else { continue }
            var path = Path()
            path.move(to: bounds.forcePoint(x: source.x, y: source.y))
            path.addLine(to: bounds.forcePoint(x: target.x, y: target.y))
            context.stroke(path, with: .color(palette.flowIn.opacity(0.55)), lineWidth: StockMonitorTokens.Size.hairline)
        }
        for node in layout.nodes {
            guard node.x.isFinite, node.y.isFinite else { continue }
            let point = bounds.forcePoint(x: node.x, y: node.y)
            let radius = StockMonitorTokens.Space.medium
            context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                 width: radius * 2, height: radius * 2)), with: .color(palette.accent2))
        }
    }
}

private struct GraphDataSummary: View {
    let lines: [String]
    @Environment(\.stockMonitorPalette) private var palette

    init(sankey: SankeyLayout) {
        lines = sankey.nodes.map { "\($0.id): \(GraphLabel.value($0.value))" } + sankey.links.map { "\($0.sourceID) → \($0.targetID): \(GraphLabel.value($0.value))" }
    }

    init(force: ForceGraphLayout) {
        lines = force.nodes.map { "\($0.id): (\(GraphLabel.coordinate($0.x)), \(GraphLabel.coordinate($0.y)))" } + force.links.map { "\($0.sourceID) → \($0.targetID): \(GraphLabel.value($0.value))" }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: StockMonitorTokens.Size.minimumHitTarget), alignment: .leading)], alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: StockMonitorTokens.TypeScale.caption, design: .monospaced))
                    .foregroundStyle(palette.inkSecondary)
                    .accessibilityLabel(line)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct GraphCanvasBounds {
    let minX: Double
    let maxX: Double
    let minY: Double
    let maxY: Double
    let size: CGSize

    static func sankey(_ layout: SankeyLayout, in size: CGSize) -> Self {
        let xs = layout.nodes.flatMap { [$0.x, $0.x + $0.width] }.filter(\.isFinite)
        let ys = layout.nodes.flatMap { [$0.y, $0.y + $0.height] }.filter(\.isFinite)
        return Self(x: xs, y: ys, size: size)
    }

    static func force(_ layout: ForceGraphLayout, in size: CGSize) -> Self {
        Self(x: layout.nodes.map(\.x), y: layout.nodes.map(\.y), size: size)
    }

    private init(x: [Double], y: [Double], size: CGSize) {
        let finiteX = x.filter(\.isFinite)
        let finiteY = y.filter(\.isFinite)
        minX = finiteX.min() ?? 0
        maxX = max(finiteX.max() ?? 1, minX + 1)
        minY = finiteY.min() ?? 0
        maxY = max(finiteY.max() ?? 1, minY + 1)
        self.size = size
    }

    func sankeyPoint(x: Double, y: Double) -> CGPoint {
        CGPoint(x: normalized(x, lower: minX, upper: maxX) * size.width,
                y: normalized(y, lower: minY, upper: maxY) * size.height)
    }

    func sankeyRect(x: Double, y: Double, width: Double, height: Double) -> CGRect {
        let origin = sankeyPoint(x: x, y: y)
        let end = sankeyPoint(x: x + max(0, width), y: y + max(0, height))
        return CGRect(x: min(origin.x, end.x), y: min(origin.y, end.y), width: max(StockMonitorTokens.Size.hairline, abs(end.x - origin.x)), height: max(StockMonitorTokens.Size.hairline, abs(end.y - origin.y)))
    }

    func forcePoint(x: Double, y: Double) -> CGPoint {
        sankeyPoint(x: x, y: y)
    }

    func lineWidth(for thickness: Double) -> CGFloat {
        let normalizedThickness = normalized(thickness, lower: 0, upper: max(maxX - minX, maxY - minY))
        return max(StockMonitorTokens.Size.hairline, CGFloat(normalizedThickness) * size.height)
    }

    private func normalized(_ value: Double, lower: Double, upper: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, (value - lower) / max(upper - lower, Double.leastNonzeroMagnitude)))
    }
}

private enum GraphLabel {
    static func value(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "unknown" }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }

    static func value(_ value: Double) -> String {
        guard value.isFinite else { return "unknown" }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }

    static func coordinate(_ value: Double) -> String {
        guard value.isFinite else { return "unknown" }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }
}
