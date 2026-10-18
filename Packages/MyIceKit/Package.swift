// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyIceKit",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "MyIceKit", targets: ["MyIceKit"])],
    targets: [
        .target(name: "MyIceKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MyIceKitTests", dependencies: ["MyIceKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
