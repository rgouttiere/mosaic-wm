// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mosaic",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Mosaic",
            path: "Sources/Mosaic",
            swiftSettings: [
                // AppKit / Accessibility code is main-thread-bound; v5 mode keeps
                // strict-concurrency noise out of the way for this foundation.
                .swiftLanguageMode(.v5)
            ]
        ),
        // M0 spike (throwaway): off-screen park/unpark de-risking. See docs/V2.
        .executableTarget(
            name: "MosaicSpike",
            path: "Sources/MosaicSpike",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
