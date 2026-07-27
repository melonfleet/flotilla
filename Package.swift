// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Flotilla",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "FlotillaCore", targets: ["FlotillaCore"]),
        .executable(name: "flotilla-probe", targets: ["flotilla-probe"]),
        .executable(name: "Flotilla", targets: ["Flotilla"]),
    ],
    targets: [
        // UI-free spine shared by client and host modes.
        .target(name: "FlotillaCore"),

        // Phase 1 helper: dumps real `container --format json` output and decodes it.
        .executableTarget(name: "flotilla-probe", dependencies: ["FlotillaCore"]),

        // The SwiftUI app shell (MenuBarExtra + main window). macOS-only, and therefore
        // deliberately ABSENT from Package@swift-6.1.swift: that manifest exists so the
        // Foundation-only core still builds and tests on Linux, which is what lets the
        // data/backend agents verify their own work. Adding this target there would break
        // that. Moves to an Xcode project when the app bundle, LSUIElement and signing
        // start to matter (see CLAUDE.md).
        .executableTarget(name: "Flotilla", dependencies: ["FlotillaCore"]),

        // Decoding tests run against real captured JSON in Fixtures/ — no `container`
        // install needed to run `swift test`.
        .testTarget(
            name: "FlotillaCoreTests",
            dependencies: ["FlotillaCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
