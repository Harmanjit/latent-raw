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
        .executable(name: "latent-cli", targets: ["latent-cli"]),
        .executable(name: "latent-app", targets: ["latent-app"]),
        .executable(name: "latent-rawdecoder", targets: ["latent-rawdecoder"]),
    ],
    dependencies: [
        // Exact, not "from": a fresh resolve must never pull in a version
        // nobody tested. Bump deliberately.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "6.29.3"),
        // LibRaw and Lensfun are vendored as XCFrameworks under vendor/ rather than
        // pulled as SwiftPM dependencies — see vendor/README.md for why and how.
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
        .testTarget(
            name: "MLKitTests",
            dependencies: ["MLKit", "PixelEngine", "RawCore"],
            path: "Tests/MLKitTests"
        ),
        .executableTarget(
            name: "latent-rawdecoder",
            dependencies: ["RawCore"],
            path: "Sources/latent-rawdecoder"
        ),
        .executableTarget(
            name: "latent-cli",
            dependencies: ["RawCore", "PixelEngine", "Catalog", "ColorKit"],
            path: "Sources/latent-cli"
        ),
        .testTarget(
            name: "PixelEngineTests",
            dependencies: ["PixelEngine", "RawCore", "Catalog"],
            path: "Tests/PixelEngineTests",
            // Reference PNGs, read by path from the test source.
            exclude: ["Golden"]
        ),
        .testTarget(
            name: "CatalogTests",
            dependencies: ["Catalog", "RawCore"],
            path: "Tests/CatalogTests"
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
            dependencies: ["RawCore", "PixelEngine", "ColorKit", "Catalog", "LensKit", "MLKit"],
            path: "Sources/latent-app"
        ),
    ]
)
