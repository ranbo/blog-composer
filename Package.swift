// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BlogComposer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "BlogComposer",
            targets: ["BlogComposer"]
        )
    ],
    targets: [
        .target(
            name: "BlogComposerCore",
            path: "Sources/BlogComposerCore"
        ),
        .executableTarget(
            name: "BlogComposer",
            dependencies: ["BlogComposerCore"],
            path: "Sources/BlogComposerApp"
        ),
        .testTarget(
            name: "BlogComposerTests",
            dependencies: ["BlogComposerCore"],
            path: "Tests/BlogComposerTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
