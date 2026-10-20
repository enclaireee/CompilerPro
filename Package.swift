// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Proof",
    platforms: [
        .macOS("15.0")
    ],
    products: [
        .library(name: "ProofCore", targets: ["ProofCore"]),
        .executable(name: "Proof", targets: ["Proof"])
    ],
    targets: [
        .target(
            name: "ProofCore",
            path: "Sources/ProofCore"
        ),
        .executableTarget(
            name: "Proof",
            dependencies: ["ProofCore"],
            path: "Sources/Proof",
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "ProofTests",
            dependencies: ["ProofCore"],
            path: "Tests/ProofTests"
        )
    ]
)
