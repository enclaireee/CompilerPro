// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CompilerPro",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CompilerProCore", targets: ["CompilerProCore"]),
        .executable(name: "CompilerPro", targets: ["CompilerPro"])
    ],
    targets: [
        .target(
            name: "CompilerProCore",
            path: "Sources/CompilerProCore"
        ),
        .executableTarget(
            name: "CompilerPro",
            dependencies: ["CompilerProCore"],
            path: "Sources/CompilerPro",
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "CompilerProTests",
            dependencies: ["CompilerProCore"],
            path: "Tests/CompilerProTests"
        )
    ]
)
