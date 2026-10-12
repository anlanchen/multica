// swift-tools-version: 6.0
import PackageDescription

// MulticaCore is pure Foundation so it builds and tests on Linux CI as well as
// macOS. The SwiftUI/AppKit app target is only declared when the manifest is
// evaluated on macOS.
var products: [Product] = [
    .library(name: "MulticaCore", targets: ["MulticaCore"]),
    .executable(name: "multica-bench", targets: ["MulticaBench"]),
]

var targets: [Target] = [
    .target(name: "MulticaCore"),
    .executableTarget(name: "MulticaBench", dependencies: ["MulticaCore"]),
    .testTarget(name: "MulticaCoreTests", dependencies: ["MulticaCore"]),
]

#if os(macOS)
products.append(.executable(name: "MulticaApp", targets: ["MulticaApp"]))
targets.append(
    .executableTarget(
        name: "MulticaApp",
        dependencies: ["MulticaCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    )
)
#endif

let package = Package(
    name: "MulticaNative",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
