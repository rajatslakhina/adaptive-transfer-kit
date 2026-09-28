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
            // Depends on the UI module too, even though everything in it is
            // behind `#if canImport(SwiftUI)` and compiles to nothing on Linux.
            // The first cut of this package shipped its only real defect in
            // that module precisely because nothing referenced it.
            dependencies: ["AdaptiveTransfer", "AdaptiveTransferUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
