// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Serverlife",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "serverlife-cli", targets: ["ServerlifeCLI"]),
        .library(name: "ServerlifeCore", targets: ["ServerlifeCore"]),
    ],
    targets: [
        .target(
            name: "ServerlifeCore",
            path: "Sources/ServerlifeCore"
        ),
        .executableTarget(
            name: "ServerlifeCLI",
            dependencies: ["ServerlifeCore"],
            path: "Sources/ServerlifeCLI"
        ),
        .executableTarget(
            name: "Serverlife",
            dependencies: ["ServerlifeCore"],
            path: "Sources/Serverlife",
            resources: [.copy("Resources/Fonts")]
        ),
        .testTarget(
            name: "ServerlifeCoreTests",
            dependencies: ["ServerlifeCore"],
            path: "Tests/ServerlifeCoreTests"
        ),
    ]
)
