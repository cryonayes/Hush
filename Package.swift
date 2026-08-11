// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hush",
    platforms: [.macOS("14.2")],   // process taps land here
    targets: [
        .executableTarget(
            name: "Hush",
            // ponytail: v5 mode — CoreAudio IOProc blocks aren't Sendable-clean and never will be
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
