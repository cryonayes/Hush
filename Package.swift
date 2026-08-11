// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hush",
    platforms: [.macOS("15.0")],   // 15 for Synchronization.Atomic; taps need 14.2
    targets: [
        .executableTarget(
            name: "Hush",
            // ponytail: v5 mode — CoreAudio IOProc blocks aren't Sendable-clean and never will be
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
