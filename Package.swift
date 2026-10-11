// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Oneshot",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "Oneshot",
            path: "Sources/Oneshot"
        )
    ]
)
