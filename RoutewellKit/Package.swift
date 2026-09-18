// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RoutewellKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "RoutewellKit", targets: ["RoutewellKit"]),
        .library(name: "RoutewellMock", targets: ["RoutewellMock"]),
    ],
    targets: [
        .target(name: "RoutewellKit"),
        .target(name: "RoutewellMock", dependencies: ["RoutewellKit"]),
        .testTarget(name: "RoutewellKitTests", dependencies: ["RoutewellKit", "RoutewellMock"]),
    ],
    swiftLanguageModes: [.v6]
)
