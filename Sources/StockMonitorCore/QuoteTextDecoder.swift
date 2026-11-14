import Foundation
#if canImport(Darwin)
import CoreFoundation
#endif

/// Decodes the legacy public quote text feeds without changing Apple behavior.
enum QuoteTextDecoder {
    static func gbkOrUTF8(_ data: Data) -> String? {
#if canImport(Darwin)
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        return String(data: data, encoding: gb18030) ?? String(data: data, encoding: .utf8)
#else
        // swift-corelibs-foundation has no GBK String.Encoding; this is only the Linux package/test path.
        return String(data: data, encoding: .utf8)
#endif
    }
}
