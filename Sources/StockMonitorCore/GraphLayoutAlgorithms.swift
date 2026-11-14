import Foundation

public struct GraphLayoutNodeInput: Sendable, Equatable {
    public let id: String
    /// A source-provided value. `nil` means the source did not provide one.
    public let value: Double?

    public init(id: String, value: Double? = nil) {
        self.id = id
        self.value = value
    }
}

public struct GraphLayoutLinkInput: Sendable, Equatable {
    public let sourceID: String
    public let targetID: String
    public let value: Double

    public init(sourceID: String, targetID: String, value: Double) {
        self.sourceID = sourceID
        self.targetID = targetID
        self.value = value
    }
}

public struct SankeyNodeLayout: Sendable, Equatable {
    public let id: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let value: Double?

    public init(id: String, x: Double, y: Double, width: Double, height: Double, value: Double?) {
        self.id = id; self.x = x; self.y = y; self.width = width; self.height = height; self.value = value
    }
}

public struct SankeyLinkLayout: Sendable, Equatable {
    public let sourceID: String
    public let targetID: String
    public let value: Double
    public let sourceY: Double
    public let targetY: Double
    public let thickness: Double

    public init(sourceID: String, targetID: String, value: Double, sourceY: Double, targetY: Double, thickness: Double) {
        self.sourceID = sourceID; self.targetID = targetID; self.value = value
        self.sourceY = sourceY; self.targetY = targetY; self.thickness = thickness
    }
}

public struct SankeyLayout: Sendable, Equatable {
    public let nodes: [SankeyNodeLayout]
    public let links: [SankeyLinkLayout]
    public init(nodes: [SankeyNodeLayout], links: [SankeyLinkLayout]) { self.nodes = nodes; self.links = links }
}

public struct ForceGraphNodeLayout: Sendable, Equatable {
    public let id: String
    public let x: Double
    public let y: Double
    public init(id: String, x: Double, y: Double) { self.id = id; self.x = x; self.y = y }
}

public struct ForceGraphLayout: Sendable, Equatable {
    public let nodes: [ForceGraphNodeLayout]
    public let links: [GraphLayoutLinkInput]
    public init(nodes: [ForceGraphNodeLayout], links: [GraphLayoutLinkInput]) { self.nodes = nodes; self.links = links }
}

public enum GraphLayoutAlgorithms {
    /// Computes a bounded, stable left-to-right Sankey layout. Invalid values and
    /// links to unknown IDs are excluded; no node is synthesized for missing data.
    public static func sankey(nodes inputs: [GraphLayoutNodeInput], links inputsLinks: [GraphLayoutLinkInput], width: Double, height: Double, nodeWidth: Double = 16, nodePadding: Double = 12) -> SankeyLayout {
        guard width.isFinite, height.isFinite, width >= 0, height >= 0,
              nodeWidth.isFinite, nodePadding.isFinite, nodeWidth >= 0, nodePadding >= 0 else { return SankeyLayout(nodes: [], links: []) }
        guard !inputs.contains(where: { $0.id.isEmpty || ($0.value != nil && (!$0.value!.isFinite || $0.value! < 0)) }),
              Set(inputs.map(\.id).filter { !$0.isEmpty }).count == inputs.count else { return SankeyLayout(nodes: [], links: []) }
        guard !inputs.isEmpty else { return SankeyLayout(nodes: [], links: []) }
        let ids = inputs.map(\.id)
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        let validLinks = inputsLinks.filter { link in
            link.value.isFinite && link.value >= 0 && index[link.sourceID] != nil && index[link.targetID] != nil && link.sourceID != link.targetID
        }

        var depth = Array(repeating: 0, count: inputs.count)
        for _ in 0..<inputs.count {
            var changed = false
            for link in validLinks {
                guard let source = index[link.sourceID], let target = index[link.targetID] else { continue }
                if depth[target] < depth[source] + 1 { depth[target] = depth[source] + 1; changed = true }
            }
            if !changed { break }
        }
        let maxDepth = depth.max() ?? 0
        let usableWidth = max(0, width - nodeWidth)
        let xStep = maxDepth == 0 ? 0 : usableWidth / Double(maxDepth)
        let incoming = Dictionary(grouping: validLinks, by: { $0.targetID })
        let outgoing = Dictionary(grouping: validLinks, by: { $0.sourceID })
        let computed: [Double?] = inputs.map { node in
            if let value = node.value { return value }
            let total = (incoming[node.id] ?? []).reduce(0.0) { $0 + $1.value } + (outgoing[node.id] ?? []).reduce(0.0) { $0 + $1.value }
            return total > 0 ? total : nil
        }
        let columns = Dictionary(grouping: Array(0..<inputs.count), by: { depth[$0] })
        var layouts = [SankeyNodeLayout]()
        for i in 0..<inputs.count {
            let column = columns[depth[i]] ?? [i]
            let slot = column.firstIndex(of: i) ?? 0
            let gapTotal = nodePadding * Double(max(0, column.count - 1))
            let slotHeight = max(0, (height - gapTotal) / Double(max(1, column.count)))
            let y = min(max(0, height - slotHeight), Double(slot) * (slotHeight + nodePadding))
            layouts.append(SankeyNodeLayout(id: inputs[i].id, x: min(max(0, Double(depth[i]) * xStep), usableWidth), y: y, width: min(nodeWidth, width), height: slotHeight, value: computed[i]))
        }
        var offsets = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0.0) })
        var linkLayouts = [SankeyLinkLayout]()
        for link in validLinks {
            guard let source = layouts.first(where: { $0.id == link.sourceID }), let target = layouts.first(where: { $0.id == link.targetID }) else { continue }
            let sourceTotal = max(1e-12, (outgoing[link.sourceID] ?? []).reduce(0) { $0 + $1.value })
            let targetTotal = max(1e-12, (incoming[link.targetID] ?? []).reduce(0) { $0 + $1.value })
            let thickness = min(source.height, min(target.height, min(source.height * link.value / sourceTotal, target.height * link.value / targetTotal)))
            let safeThickness = max(0, min(min(source.height, target.height), thickness.isFinite ? thickness : 0))
            let sourceY = min(source.y + source.height, source.y + (offsets[link.sourceID] ?? 0) + safeThickness / 2)
            let targetY = min(target.y + target.height, target.y + (offsets[link.targetID] ?? 0) + safeThickness / 2)
            offsets[link.sourceID, default: 0] += safeThickness
            offsets[link.targetID, default: 0] += safeThickness
            linkLayouts.append(SankeyLinkLayout(sourceID: link.sourceID, targetID: link.targetID, value: link.value, sourceY: sourceY, targetY: targetY, thickness: safeThickness))
        }
        return SankeyLayout(nodes: layouts, links: linkLayouts)
    }

    /// Places nodes using a fixed-seed-free deterministic relaxation. Coordinates
    /// are always clamped to the supplied rectangle and links with missing IDs are omitted.
    public static func forceGraph(nodes inputs: [GraphLayoutNodeInput], links inputsLinks: [GraphLayoutLinkInput], width: Double, height: Double, iterations: Int = 60) -> ForceGraphLayout {
        guard width.isFinite, height.isFinite, width >= 0, height >= 0, iterations >= 0,
              !inputs.contains(where: { $0.id.isEmpty }), Set(inputs.map(\.id)).count == inputs.count else { return ForceGraphLayout(nodes: [], links: []) }
        guard !inputs.isEmpty else { return ForceGraphLayout(nodes: [], links: []) }
        if inputs.count == 1 {
            return ForceGraphLayout(nodes: [ForceGraphNodeLayout(id: inputs[0].id, x: width / 2, y: height / 2)], links: [])
        }
        let ids = inputs.map(\.id)
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        let links = inputsLinks.filter { $0.value.isFinite && $0.value >= 0 && $0.sourceID != $0.targetID && index[$0.sourceID] != nil && index[$0.targetID] != nil }
        var points = ids.enumerated().map { i, _ in
            let angle = Double(i) * 2.399963229728653
            let radius = min(width, height) * 0.3
            return (x: width / 2 + cos(angle) * radius, y: height / 2 + sin(angle) * radius)
        }
        for _ in 0..<iterations {
            var dx = Array(repeating: 0.0, count: points.count), dy = dx
            for i in 0..<points.count { for j in (i + 1)..<points.count {
                let ax = points[i].x - points[j].x, ay = points[i].y - points[j].y
                let d2 = max(1, ax * ax + ay * ay), force = min(2, 120 / d2)
                dx[i] += ax * force; dy[i] += ay * force; dx[j] -= ax * force; dy[j] -= ay * force
            }}
            for link in links { guard let a = index[link.sourceID], let b = index[link.targetID] else { continue }; let ax = points[b].x - points[a].x, ay = points[b].y - points[a].y; dx[a] += ax * 0.01; dy[a] += ay * 0.01; dx[b] -= ax * 0.01; dy[b] -= ay * 0.01 }
            for i in 0..<points.count { points[i].x = min(width, max(0, points[i].x + dx[i])); points[i].y = min(height, max(0, points[i].y + dy[i])) }
        }
        return ForceGraphLayout(nodes: zip(ids, points).map { ForceGraphNodeLayout(id: $0.0, x: $0.1.x, y: $0.1.y) }, links: links)
    }
}
