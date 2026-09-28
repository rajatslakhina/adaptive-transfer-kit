// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "adaptive-transfer-kit",
    // Only the platforms CI actually builds are declared here. Linux has no
    // platform clause in SwiftPM and is covered by the `swift build` job.
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "AdaptiveTransfer", targets: ["AdaptiveTransfer"]),
        .library(name: "AdaptiveTransferUI", targets: ["AdaptiveTransferUI"])
    ],
    targets: [
        .target(
            name: "AdaptiveTransfer",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AdaptiveTransferUI",
            dependencies: ["AdaptiveTransfer"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AdaptiveTransferTests",
            dependencies: ["AdaptiveTransfer"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
