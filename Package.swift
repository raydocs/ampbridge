// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AmpBridge",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "ampbridge",
            targets: ["AmpBridge"]
        )
    ],
    targets: [
        .executableTarget(
            name: "AmpBridge",
            path: "Sources"
        ),
        .testTarget(
            name: "AmpBridgeTests",
            dependencies: ["AmpBridge"],
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)
