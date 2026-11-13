import Foundation

public enum SimHash {
    /// Stable 64-bit fingerprint built from normalized word/CJK bigram features.
    public static func fingerprint(_ text: String) -> UInt64 {
        let normalized = text.lowercased()
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return 0 }

        var features: [String] = []
        for token in normalized.split(whereSeparator: \.isWhitespace).map(String.init) {
            features.append(token)
            let scalars = Array(token.unicodeScalars)
            if scalars.count > 1 {
                for index in 0..<(scalars.count - 1) {
                    features.append(String(String.UnicodeScalarView([scalars[index], scalars[index + 1]])))
                }
            }
        }

        var weights = Array(repeating: 0, count: 64)
        for feature in Set(features) {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in feature.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            for bit in 0..<64 {
                weights[bit] += (hash & (UInt64(1) << bit)) == 0 ? -1 : 1
            }
        }
        var result: UInt64 = 0
        for bit in 0..<64 where weights[bit] >= 0 { result |= UInt64(1) << bit }
        return result
    }

    public static func distance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    public static func isDuplicate(_ lhs: UInt64, _ rhs: UInt64, threshold: Int = 3) -> Bool {
        distance(lhs, rhs) <= max(0, threshold)
    }
}
