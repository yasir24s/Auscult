// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Auscult",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AuscultKit", targets: ["AuscultKit"]),
        .executable(name: "auscult", targets: ["AuscultCLI"]),
        .executable(name: "AuscultApp", targets: ["AuscultApp"]),
    ],
    targets: [
        .target(
            name: "AuscultKit",
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
