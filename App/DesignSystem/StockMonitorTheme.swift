import SwiftUI

enum StockMonitorAppearance: String, CaseIterable, Identifiable, Equatable {
    case dusk
    case contrastLight

    var id: String { rawValue }

    var palette: StockMonitorPalette {
        switch self {
        case .dusk: .dusk
        case .contrastLight: .contrastLight
        }
    }

    var colorScheme: ColorScheme {
        self == .dusk ? .dark : .light
    }

    var displayName: String {
        self == .dusk ? "Dusk 暗色" : "高对比浅色"
    }
}

struct StockMonitorPalette {
    let paper0: Color
    let paper1: Color
    let paper2: Color
    let paper3: Color
    let inkPrimary: Color
    let inkSecondary: Color
    let inkMuted: Color
    let hair: Color
    let accent: Color
    let accent2: Color
    let dataUp: Color
    let dataDown: Color
    let dataFlat: Color
    let heat1: Color
    let heat2: Color
    let heat3: Color
    let heat4: Color
    let heat5: Color
    let flowIn: Color
    let flowOut: Color

    var heatScale: [Color] { [heat1, heat2, heat3, heat4, heat5] }

    static let dusk = StockMonitorPalette(
        paper0: Color(rgbHex: 0x080D14),
        paper1: Color(rgbHex: 0x101923),
        paper2: Color(rgbHex: 0x1A2633),
        paper3: Color(rgbHex: 0x253443),
        inkPrimary: Color(rgbHex: 0xF3F6F8),
        inkSecondary: Color(rgbHex: 0xCED7E0),
        inkMuted: Color(rgbHex: 0x9EADBC),
        hair: Color(rgbHex: 0x425363),
        accent: Color(rgbHex: 0x55E0BE),
        accent2: Color(rgbHex: 0xA6A9FF),
        dataUp: Color(rgbHex: 0x43D79A),
        dataDown: Color(rgbHex: 0xFF7180),
        dataFlat: Color(rgbHex: 0xC0CBD5),
        heat1: Color(rgbHex: 0x164A3C),
        heat2: Color(rgbHex: 0x267357),
        heat3: Color(rgbHex: 0x719C4D),
        heat4: Color(rgbHex: 0xD2A342),
        heat5: Color(rgbHex: 0xD95D55),
        flowIn: Color(rgbHex: 0x55E0BE),
        flowOut: Color(rgbHex: 0xF1A36A))

    static let contrastLight = StockMonitorPalette(
        paper0: Color(rgbHex: 0xF2F5F8),
        paper1: Color(rgbHex: 0xFFFFFF),
        paper2: Color(rgbHex: 0xE4EBF1),
        paper3: Color(rgbHex: 0xCFDAE4),
        inkPrimary: Color(rgbHex: 0x111A24),
        inkSecondary: Color(rgbHex: 0x2D4052),
        inkMuted: Color(rgbHex: 0x4B6073),
        hair: Color(rgbHex: 0xA3B1BF),
        accent: Color(rgbHex: 0x006B58),
        accent2: Color(rgbHex: 0x394AAB),
        dataUp: Color(rgbHex: 0x08724C),
        dataDown: Color(rgbHex: 0xB92339),
        dataFlat: Color(rgbHex: 0x3F5366),
        heat1: Color(rgbHex: 0xD9EEE5),
        heat2: Color(rgbHex: 0xB5DCCB),
        heat3: Color(rgbHex: 0xEEE2A5),
        heat4: Color(rgbHex: 0xE9C185),
        heat5: Color(rgbHex: 0xE29A9A),
        flowIn: Color(rgbHex: 0x006B58),
        flowOut: Color(rgbHex: 0xA64420))
}

enum StockMonitorTokens {
    enum TypeScale {
        static let caption: CGFloat = 12
        static let footnote: CGFloat = 13
        static let body: CGFloat = 15
        static let subhead: CGFloat = 17
        static let title: CGFloat = 20
        static let titleLarge: CGFloat = 27
        static let display: CGFloat = 33
    }

    enum Space {
        static let xsmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xlarge: CGFloat = 24
        static let xxlarge: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let panel: CGFloat = 20
        static let pill: CGFloat = 999
    }

    enum Opacity {
        static let chartGrid: Double = 0.46
        static let volumeBar: Double = 0.72
        static let semanticWash: Double = 0.12
    }

    enum Scale {
        static let metricMinimum: CGFloat = 0.75
    }

    enum Size {
        static let minimumHitTarget: CGFloat = 44
        static let chartSkeletonHeight: CGFloat = 104
        static let heroSkeletonHeight: CGFloat = 148
        static let skeletonQuarter: CGFloat = 64
        static let skeletonHalf: CGFloat = 120
        static let skeletonTwoThirds: CGFloat = 180
        static let thresholdRailHeight: CGFloat = 16
        static let thresholdMarkerDiameter: CGFloat = 10
        static let marketBarHeight: CGFloat = 10
        static let marketBucketLabelWidth: CGFloat = 84
        static let marketBucketCountWidth: CGFloat = 32
        static let factorMatrixCellWidth: CGFloat = 112
        static let factorMatrixCellMinHeight: CGFloat = 112
        static let hairline: CGFloat = 1
    }
}

private struct StockMonitorPaletteKey: EnvironmentKey {
    static let defaultValue = StockMonitorPalette.dusk
}

extension EnvironmentValues {
    var stockMonitorPalette: StockMonitorPalette {
        get { self[StockMonitorPaletteKey.self] }
        set { self[StockMonitorPaletteKey.self] = newValue }
    }
}

extension View {
    func stockMonitorAppearance(_ appearance: StockMonitorAppearance) -> some View {
        environment(\.stockMonitorPalette, appearance.palette)
            .preferredColorScheme(appearance.colorScheme)
    }
}

private extension Color {
    init(rgbHex: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgbHex >> 16) & 0xFF) / 255,
            green: Double((rgbHex >> 8) & 0xFF) / 255,
            blue: Double(rgbHex & 0xFF) / 255,
            opacity: 1)
    }
}
