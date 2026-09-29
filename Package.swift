// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "runski",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "runski", targets: ["runski"]),
        .library(name: "RunskiCore", targets: ["RunskiCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "runski",
            dependencies: [
                "RunskiCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "RunskiCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .testTarget(
            name: "RunskiCoreTests",
            dependencies: ["RunskiCore"]
        ),
    ]
)
