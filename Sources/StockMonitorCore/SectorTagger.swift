import Foundation

public struct SectorTagger: Sendable {
    private struct SectorMap: Decodable, Sendable {
        let titleSectorMap: [String: [String]]
        let sectorSynonyms: [String: String]
        let clusterPools: [String: ClusterPool]

        enum CodingKeys: String, CodingKey {
            case titleSectorMap = "title_sector_map"
            case sectorSynonyms = "sector_synonyms"
            case clusterPools = "cluster_pools"
        }
    }

    private struct ClusterPool: Decodable, Sendable {
        let keywords: [String]
        let sectors: [String]
    }

    private let titleMap: [String: [String]]
    private let synonyms: [String: String]
    private let pools: [ClusterPool]

    public init(data: Data) throws {
        let decoded = try JSONDecoder().decode(SectorMap.self, from: data)
        self.titleMap = decoded.titleSectorMap
        self.synonyms = Dictionary(uniqueKeysWithValues: decoded.sectorSynonyms.map { ($0.key.lowercased(), $0.value) })
        self.pools = decoded.clusterPools.keys.sorted().compactMap { decoded.clusterPools[$0] }
    }

    public init(bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: "sector_map", withExtension: "json") else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        try self.init(data: Data(contentsOf: url))
    }

    /// Returns deterministic, de-duplicated sector candidates in longest-match-first order.
    public func tags(in text: String) -> [String] {
        let normalized = text.lowercased()
        var candidates: [(matchLength: Int, order: Int, value: String)] = []
        for key in titleMap.keys.sorted(by: { $0.count == $1.count ? $0 < $1 : $0.count > $1.count })
        where containsKeyword(key, in: normalized) {
            for value in titleMap[key] ?? [] {
                candidates.append((key.count, candidates.count, value))
            }
        }
        for pool in pools {
            let matchedLength = pool.keywords.filter { containsKeyword($0, in: normalized) }.map(\.count).max() ?? 0
            guard matchedLength > 0 else { continue }
            for value in pool.sectors { candidates.append((matchedLength, candidates.count, value)) }
        }

        var seen = Set<String>()
        var result: [String] = []
        for candidate in candidates.sorted(by: {
            $0.matchLength == $1.matchLength ? $0.order < $1.order : $0.matchLength > $1.matchLength
        }) {
            let canonical = synonyms[candidate.value.lowercased()] ?? candidate.value
            let key = canonical.lowercased()
            if seen.insert(key).inserted { result.append(canonical) }
        }
        return result
    }

    private func containsKeyword(_ keyword: String, in text: String) -> Bool {
        let needle = keyword.lowercased()
        guard !needle.isEmpty else { return false }
        let isASCIIToken = needle.unicodeScalars.allSatisfy { $0.value < 128 && CharacterSet.alphanumerics.contains($0) }
        if isASCIIToken {
            let escaped = NSRegularExpression.escapedPattern(for: needle)
            return text.range(of: "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])", options: .regularExpression) != nil
        }
        return text.contains(needle)
    }
}
