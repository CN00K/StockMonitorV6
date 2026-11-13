import Foundation

/// Decodes the legacy public quote text feeds without changing Apple behavior.
enum QuoteTextDecoder {
    static func gbkOrUTF8(_ data: Data) -> String? {
#if canImport(Darwin)
        return String(data: data, encoding: .gbk) ?? String(data: data, encoding: .utf8)
#else
        // swift-corelibs-foundation has no GBK String.Encoding; this is only the Linux package/test path.
        return String(data: data, encoding: .utf8)
#endif
    }
}
