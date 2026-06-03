// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WindowLens",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "WindowLens", targets: ["WindowLens"])
    ],
    targets: [
        .executableTarget(
            name: "WindowLens",
            path: "WindowLens/Sources",
            resources: [
                .process("../Resources")
            ]
        ),
        .testTarget(
            name: "WindowLensTests",
            dependencies: ["WindowLens"],
            path: "WindowLens/Tests"
        )
    ]
)
