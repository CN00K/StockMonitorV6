// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StockMonitorV6",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "StockMonitorCore", targets: ["StockMonitorCore"])
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite3"])]
        ),
        .target(
            name: "StockMonitorCore",
            dependencies: ["CSQLite"],
            path: "Sources/StockMonitorCore"
        ),
        .testTarget(
            name: "StockMonitorCoreTests",
            dependencies: ["StockMonitorCore", "CSQLite"],
            path: "Tests/StockMonitorCoreTests"
        )
    ]
)
