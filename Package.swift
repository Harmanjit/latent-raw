// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "latent",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "RawCore", targets: ["RawCore"]),
        .library(name: "PixelEngine", targets: ["PixelEngine"]),
        .library(name: "ColorKit", targets: ["ColorKit"]),
        .library(name: "LensKit", targets: ["LensKit"]),
        .library(name: "Catalog", targets: ["Catalog"]),
        .library(name: "MLKit", targets: ["MLKit"]),
        .library(name: "HelpKit", targets: ["HelpKit"]),
        .library(name: "MergeKit", targets: ["MergeKit"]),
        .executable(name: "latent-cli", targets: ["latent-cli"]),
        .executable(name: "latent-app", targets: ["latent-app"]),
        .executable(name: "latent-rawdecoder", targets: ["latent-rawdecoder"]),
    ],
    dependencies: [
        // Exact, not "from": a fresh resolve must never pull in a version
        // nobody tested. Bump deliberately.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "6.29.3"),
        // LibRaw is built as an XCFramework under vendor/ by scripts/build_libraw.sh
        // rather than pulled as a SwiftPM dependency — see vendor/README.md for why
        // and how. Lensfun contributes only its XML database, bundled in LensKit.
    ],
    targets: [
        // C shim exposing a small, deliberately narrow slice of LibRaw's C++ API
        // as a plain C interface Swift can import directly.
        .target(
            name: "RawCore",
            dependencies: ["CLibRaw"],
            path: "Sources/RawCore",
            exclude: ["CLibRaw"]
        ),
        .target(
            name: "ColorKit",
            path: "Sources/ColorKit"
        ),
        .target(
            name: "LensKit",
            dependencies: ["RawCore"],
            path: "Sources/LensKit",
            resources: [.copy("Resources/lensfun-db")]
        ),
        .testTarget(
            name: "LensKitTests",
            dependencies: ["LensKit", "RawCore"],
            path: "Tests/LensKitTests"
        ),
        .target(
            name: "PixelEngine",
            dependencies: ["RawCore", "ColorKit", "LensKit"],
            path: "Sources/PixelEngine",
            resources: [.process("Shaders")]
        ),
        .target(
            name: "Catalog",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift"), "RawCore"],
            path: "Sources/Catalog"
        ),
        .target(
            name: "MLKit",
            dependencies: ["PixelEngine"],
            path: "Sources/MLKit",
            resources: [.copy("Resources/Models")]
        ),
        // MergeKit for the linear DNG the touch-up export tests write
        // from the portrait JPEG (docs/Retouch.md §11).
        .testTarget(
            name: "MLKitTests",
            dependencies: ["MLKit", "PixelEngine", "RawCore", "MergeKit"],
            path: "Tests/MLKitTests"
        ),
        // Photo Merge: HDR and panorama merging, and the float DNG writer
        // their results are saved with (docs/PhotoMerge.md).
        .target(
            name: "MergeKit",
            dependencies: ["PixelEngine", "RawCore", "ColorKit"],
            path: "Sources/MergeKit"
        ),
        .testTarget(
            name: "MergeKitTests",
            dependencies: ["MergeKit", "PixelEngine", "RawCore"],
            path: "Tests/MergeKitTests"
        ),
        // Help > Latent Help: the wiki's Markdown as blocks, and search.
        // No resources: scripts/make_app.sh copies docs/wiki into the app.
        .target(
            name: "HelpKit",
            path: "Sources/HelpKit"
        ),
        .testTarget(
            name: "HelpKitTests",
            dependencies: ["HelpKit"],
            path: "Tests/HelpKitTests"
        ),
        .executableTarget(
            name: "latent-rawdecoder",
            dependencies: ["RawCore"],
            path: "Sources/latent-rawdecoder"
        ),
        .executableTarget(
            name: "latent-cli",
            dependencies: ["RawCore", "PixelEngine", "Catalog", "ColorKit", "MergeKit"],
            path: "Sources/latent-cli"
        ),
        .testTarget(
            name: "PixelEngineTests",
            dependencies: ["PixelEngine", "RawCore", "Catalog"],
            path: "Tests/PixelEngineTests",
            // Reference PNGs, read by path from the test source.
            exclude: ["Golden", "Fixtures"]
        ),
        .testTarget(
            name: "CatalogTests",
            dependencies: ["Catalog", "RawCore"],
            path: "Tests/CatalogTests"
        ),
        // Tests the app's own logic (key and menu tables, the generated
        // shortcuts page) through @testable import latent_app; SwiftPM links
        // an executable target into tests on macOS.
        .testTarget(
            name: "LatentAppTests",
            dependencies: ["latent-app", "Catalog", "MergeKit"],
            path: "Tests/LatentAppTests"
        ),
        .binaryTarget(
            name: "CLibRawBinary",
            path: "vendor/LibRaw.xcframework"
        ),
        .target(
            name: "CLibRaw",
            dependencies: ["CLibRawBinary"],
            path: "Sources/RawCore/CLibRaw",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("z")
            ]
        ),
        .executableTarget(
            name: "latent-app",
            dependencies: ["RawCore", "PixelEngine", "ColorKit", "Catalog", "LensKit", "MLKit", "HelpKit", "MergeKit"],
            path: "Sources/latent-app"
        ),
    ]
)
