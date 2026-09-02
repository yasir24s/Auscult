// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Auscult",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AuscultKit", targets: ["AuscultKit"]),
        .library(name: "AuscultProtocol", targets: ["AuscultProtocol"]),
        .executable(name: "auscult", targets: ["AuscultCLI"]),
        .executable(name: "AuscultApp", targets: ["AuscultApp"]),
    ],
    targets: [
        // Shared with the iOS agent. Lives outside Sources/ because the Xcode
        // agent project compiles the same files directly.
        .target(
            name: "AuscultProtocol",
            path: "Shared/AuscultProtocol",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "AuscultKit",
            dependencies: ["AuscultProtocol"],
            resources: [.process("Knowledge")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AuscultCLI",
            dependencies: ["AuscultKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AuscultApp",
            dependencies: ["AuscultKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
