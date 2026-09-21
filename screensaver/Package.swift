// swift-tools-version:5.9
import PackageDescription

// TASK-017.03: the fourth sibling build graph (docs/build-layout.md's "Build
// systems" section), consumed by build.sh via `swift build`/`swift test`
// from this directory. FireworksKit links core/zig-out/lib/libjumpnbump.a
// (built by `task core:build-abi` -- see taskfiles/screensaver.yml's `deps`)
// through CJumpnbump's module map onto ../../include/jumpnbump.h, the same
// frozen header extension/'s GDExtension shim consumes.
let package = Package(
    name: "FireworksScreensaver",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FireworksKit", type: .static, targets: ["FireworksKit"])
    ],
    targets: [
        .systemLibrary(name: "CJumpnbump"),
        .target(
            name: "FireworksKit",
            dependencies: ["CJumpnbump"],
            linkerSettings: [
                .unsafeFlags(["-L../core/zig-out/lib", "-ljumpnbump"])
            ]
        ),
        .testTarget(
            name: "FireworksKitTests",
            dependencies: ["FireworksKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
