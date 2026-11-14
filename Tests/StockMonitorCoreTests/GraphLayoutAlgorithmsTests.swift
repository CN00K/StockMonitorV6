import XCTest
@testable import StockMonitorCore

final class GraphLayoutAlgorithmsTests: XCTestCase {
    private let nodes = [GraphLayoutNodeInput(id: "market", value: 10), GraphLayoutNodeInput(id: "tech", value: 6), GraphLayoutNodeInput(id: "bank", value: 4)]
    private let links = [GraphLayoutLinkInput(sourceID: "market", targetID: "tech", value: 6), GraphLayoutLinkInput(sourceID: "market", targetID: "bank", value: 4)]

    func testSankeyIsDeterministicBoundedAndPreservesOnlyValidLinks() {
        let first = GraphLayoutAlgorithms.sankey(nodes: nodes, links: links + [GraphLayoutLinkInput(sourceID: "missing", targetID: "tech", value: 9), GraphLayoutLinkInput(sourceID: "market", targetID: "bank", value: -1)], width: 320, height: 180)
        let second = GraphLayoutAlgorithms.sankey(nodes: nodes, links: links + [GraphLayoutLinkInput(sourceID: "missing", targetID: "tech", value: 9), GraphLayoutLinkInput(sourceID: "market", targetID: "bank", value: -1)], width: 320, height: 180)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.nodes.count, 3)
        XCTAssertEqual(first.links.count, 2)
        for node in first.nodes { XCTAssertGreaterThanOrEqual(node.x, 0); XCTAssertLessThanOrEqual(node.x + node.width, 320); XCTAssertGreaterThanOrEqual(node.y, 0); XCTAssertLessThanOrEqual(node.y + node.height, 180) }
        for link in first.links { XCTAssertTrue(link.value.isFinite && link.value >= 0); XCTAssertTrue(link.thickness.isFinite && link.thickness >= 0) }
    }

    func testSankeyRejectsNonFiniteNegativeAndDuplicateNodes() {
        let malformed = [GraphLayoutNodeInput(id: "a", value: .nan), GraphLayoutNodeInput(id: "b", value: -2)]
        XCTAssertEqual(GraphLayoutAlgorithms.sankey(nodes: malformed, links: [], width: 100, height: 100).nodes, [])
        XCTAssertEqual(GraphLayoutAlgorithms.sankey(nodes: [GraphLayoutNodeInput(id: "a"), GraphLayoutNodeInput(id: "a")], links: [], width: 100, height: 100).nodes, [])
        XCTAssertEqual(GraphLayoutAlgorithms.sankey(nodes: [], links: [], width: 100, height: 100), SankeyLayout(nodes: [], links: []))
    }

    func testSankeyHandlesSingleNodeAndZeroLinksWithoutInventingValue() {
        let result = GraphLayoutAlgorithms.sankey(nodes: [GraphLayoutNodeInput(id: "only")], links: [], width: 80, height: 60)
        XCTAssertEqual(result.nodes.count, 1); XCTAssertEqual(result.links, []); XCTAssertNil(result.nodes[0].value)
        XCTAssertEqual(result.nodes[0].x, 0); XCTAssertEqual(result.nodes[0].y, 0)
    }

    func testForceGraphIsDeterministicBoundedAndBatchedLinksAreValidated() {
        let inputs = links + [GraphLayoutLinkInput(sourceID: "unknown", targetID: "tech", value: 1), GraphLayoutLinkInput(sourceID: "market", targetID: "tech", value: .infinity)]
        let first = GraphLayoutAlgorithms.forceGraph(nodes: nodes, links: inputs, width: 200, height: 120, iterations: 20)
        let second = GraphLayoutAlgorithms.forceGraph(nodes: nodes, links: inputs, width: 200, height: 120, iterations: 20)
        XCTAssertEqual(first, second); XCTAssertEqual(first.nodes.count, 3); XCTAssertEqual(first.links.count, 2)
        for node in first.nodes { XCTAssertTrue(node.x.isFinite && node.y.isFinite); XCTAssertGreaterThanOrEqual(node.x, 0); XCTAssertLessThanOrEqual(node.x, 200); XCTAssertGreaterThanOrEqual(node.y, 0); XCTAssertLessThanOrEqual(node.y, 120) }
    }

    func testForceGraphHandlesEmptySingleAndZeroLinkCasesAndRejectsDuplicates() {
        XCTAssertEqual(GraphLayoutAlgorithms.forceGraph(nodes: [], links: [], width: 10, height: 10), ForceGraphLayout(nodes: [], links: []))
        let single = GraphLayoutAlgorithms.forceGraph(nodes: [GraphLayoutNodeInput(id: "only")], links: [], width: 100, height: 50, iterations: 0)
        XCTAssertEqual(single.nodes.count, 1); XCTAssertEqual(single.links, []); XCTAssertEqual(single.nodes[0].x, 50); XCTAssertEqual(single.nodes[0].y, 25)
        XCTAssertEqual(GraphLayoutAlgorithms.forceGraph(nodes: [GraphLayoutNodeInput(id: "a"), GraphLayoutNodeInput(id: "a")], links: [], width: 10, height: 10).nodes, [])
    }

    func testBatchedLayoutsMapManyNodesAndLinksWithinBounds() {
        let batch = (0..<64).map { GraphLayoutNodeInput(id: "n\($0)", value: Double($0 + 1)) }
        let links = (0..<63).map {
            GraphLayoutLinkInput(sourceID: "n\($0)", targetID: "n\($0 + 1)", value: Double($0 + 1))
        }
        let sankey = GraphLayoutAlgorithms.sankey(nodes: batch, links: links, width: 800, height: 600)
        let force = GraphLayoutAlgorithms.forceGraph(nodes: batch, links: links, width: 800, height: 600, iterations: 8)
        XCTAssertEqual(sankey.nodes.count, 64)
        XCTAssertEqual(sankey.links.count, 63)
        XCTAssertEqual(force.nodes.count, 64)
        XCTAssertEqual(force.links.count, 63)
        XCTAssertTrue(force.nodes.allSatisfy { $0.x.isFinite && $0.y.isFinite && (0...800).contains($0.x) && (0...600).contains($0.y) })
        XCTAssertTrue(sankey.nodes.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.width.isFinite && $0.height.isFinite && $0.x >= 0 && $0.x + $0.width <= 800 && $0.y >= 0 && $0.y + $0.height <= 600 })
    }
}
