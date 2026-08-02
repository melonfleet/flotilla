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
    // SwiftTerm (MIT) — a VT100/xterm emulator for AppKit. Backs the detail view's Terminal
    // tab, which needs a real PTY and something that understands the escape sequences coming
    // back from it; SwiftUI has no terminal view and hand-rolling an emulator is not sensible.
    //
    // Depended on by the **Flotilla** target only. `FlotillaCore` stays Foundation-only so it
    // keeps building and testing on Linux, and `Package@swift-6.1.swift` — which omits the
    // SwiftUI target entirely — is deliberately left untouched.
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.15.0"),
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
        .executableTarget(name: "Flotilla",
                          dependencies: ["FlotillaCore",
                                         .product(name: "SwiftTerm", package: "SwiftTerm")]),

        // Decoding tests run against real captured JSON in Fixtures/ — no `container`
        // install needed to run `swift test`.
        .testTarget(
            name: "FlotillaCoreTests",
            dependencies: ["FlotillaCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
