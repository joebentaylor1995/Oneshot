// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Reel",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "Reel",
            path: "Sources/Reel"
        )
    ]
)
