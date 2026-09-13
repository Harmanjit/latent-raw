// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "rawhead",
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
        .executable(name: "rawhead-cli", targets: ["rawhead-cli"]),
        .executable(name: "rawhead-app", targets: ["rawhead-app"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
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
            path: "Sources/MLKit"
        ),
        .testTarget(
            name: "MLKitTests",
            dependencies: ["MLKit", "PixelEngine", "RawCore"],
            path: "Tests/MLKitTests"
        ),
        .executableTarget(
            name: "rawhead-cli",
            dependencies: ["RawCore", "PixelEngine", "Catalog", "ColorKit"],
            path: "Sources/rawhead-cli"
        ),
        .testTarget(
            name: "PixelEngineTests",
            dependencies: ["PixelEngine", "RawCore", "Catalog"],
            path: "Tests/PixelEngineTests"
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
            name: "rawhead-app",
            dependencies: ["RawCore", "PixelEngine", "ColorKit", "Catalog", "LensKit", "MLKit"],
            path: "Sources/rawhead-app"
        ),
    ]
)
