// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PomodoroBlocker",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PomodoroBlocker", targets: ["PomodoroBlocker"])],
    targets: [
        .executableTarget(name: "PomodoroBlocker"),
        .testTarget(name: "PomodoroBlockerTests", dependencies: ["PomodoroBlocker"]),
    ]
)
