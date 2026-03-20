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
        .executableTarget(
            name: "BlogComposer",
            path: "Sources"
        )
    ]
)
