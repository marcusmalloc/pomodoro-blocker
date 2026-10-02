// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PomodoroBlocker",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PomodoroBlocker", targets: ["PomodoroBlocker"]),
        .executable(name: "PomodoroDomainHelper", targets: ["PomodoroDomainHelper"]),
    ],
    targets: [
        .target(name: "DomainBlocking"),
        .executableTarget(name: "PomodoroBlocker", dependencies: ["DomainBlocking"]),
        .executableTarget(name: "PomodoroDomainHelper", dependencies: ["DomainBlocking"]),
        .testTarget(name: "DomainBlockingTests", dependencies: ["DomainBlocking"]),
        .testTarget(name: "PomodoroBlockerTests", dependencies: ["PomodoroBlocker"]),
    ]
)
