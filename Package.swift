// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Flotilla",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "FlotillaCore", targets: ["FlotillaCore"]),
        .executable(name: "flotilla-probe", targets: ["flotilla-probe"]),
    ],
    targets: [
        // UI-free spine shared by client and host modes.
        .target(name: "FlotillaCore"),

        // Phase 1 helper: dumps real `container --format json` output and decodes it.
        .executableTarget(name: "flotilla-probe", dependencies: ["FlotillaCore"]),

        // Decoding tests run against real captured JSON in Fixtures/ — no `container`
        // install needed to run `swift test`.
        .testTarget(
            name: "FlotillaCoreTests",
            dependencies: ["FlotillaCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
