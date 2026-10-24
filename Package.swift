// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "QuotaPulse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "QuotaPulse", targets: ["QuotaPulse"]),
        .library(name: "QuotaCore", targets: ["QuotaCore"]),
    ],
    targets: [
        .target(name: "QuotaCore"),
        .executableTarget(name: "QuotaPulse", dependencies: ["QuotaCore"]),
        .testTarget(
            name: "QuotaCoreTests",
            dependencies: ["QuotaCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
