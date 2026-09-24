// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mosaic",
    platforms: [.macOS(.v13)],
    targets: [
        // Thin C shim over the private MultitouchSupport framework (raw trackpad touches, loaded
        // via dlopen at runtime — no build-time framework dependency). Isolates the fragile MTTouch
        // struct layout so Swift only ever sees a clean (xs, ys, count) callback.
        .target(name: "CMultitouch", path: "Sources/CMultitouch"),
        .executableTarget(
            name: "Mosaic",
            dependencies: ["CMultitouch"],
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
