// swift-tools-version: 6.1
//
// Linux/6.1-toolchain manifest. SwiftPM prefers a version-specific manifest when the
// running toolchain matches, so this lets the *portable* part of Flotilla (FlotillaCore —
// pure Foundation) build and test on Linux, where employees verify their own work.
//
// Package.swift stays the source of truth for macOS (tools 6.2, .macOS(.v26), the app
// targets). Keep the target list here in sync with it for the portable targets only.
import PackageDescription

let package = Package(
    name: "Flotilla",
    products: [
        .library(name: "FlotillaCore", targets: ["FlotillaCore"]),
        .executable(name: "flotilla-probe", targets: ["flotilla-probe"]),
    ],
    targets: [
        .target(name: "FlotillaCore"),
        .executableTarget(name: "flotilla-probe", dependencies: ["FlotillaCore"]),
        .testTarget(
            name: "FlotillaCoreTests",
            dependencies: ["FlotillaCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
