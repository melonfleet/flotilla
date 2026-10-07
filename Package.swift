// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Flotilla",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "FlotillaCore", targets: ["FlotillaCore"]),
        .executable(name: "flotilla-probe", targets: ["flotilla-probe"]),
        .executable(name: "Flotilla", targets: ["Flotilla"]),
        .executable(name: "FlotillaDNSHelper", targets: ["FlotillaDNSHelper"]),
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
        // Apple's X.509 library (with swift-asn1 and swift-crypto), for each Mac's self-signed TLS
        // certificate in host mode — macOS has no API that creates one (the owner, 7 October).
        // FlotillaTrust only; FlotillaCore stays dependency-free and Linux-clean.
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.0.0"),
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
                          dependencies: ["FlotillaCore", "FlotillaPrivileged", "FlotillaTrust",
                                         .product(name: "SwiftTerm", package: "SwiftTerm")]),

        // The DNS helper (decision 19, amended 7 October): a root SMAppService daemon that runs
        // `system dns create|delete` for the signed app and nothing else. Its interface lives in
        // FlotillaPrivileged, shared with the app. Both are macOS-only (Security, XPC), so both are
        // absent from Package@swift-6.1.swift for the same reason the app is.
        .target(name: "FlotillaPrivileged"),

        // Host mode's identity (PLAN.md Phase B, B2b): each Mac's key and certificate in the
        // Keychain, its fingerprint, and the real cryptography behind FlotillaCore's pairing rules.
        // macOS-only (Security, CryptoKit), so absent from Package@swift-6.1.swift.
        .target(name: "FlotillaTrust",
                dependencies: ["FlotillaCore",
                               .product(name: "X509", package: "swift-certificates"),
                               .product(name: "SwiftASN1", package: "swift-asn1")]),
        .testTarget(name: "FlotillaTrustTests", dependencies: ["FlotillaTrust", "FlotillaCore"]),
        .executableTarget(name: "FlotillaDNSHelper",
                          dependencies: ["FlotillaCore", "FlotillaPrivileged"]),

        // Decoding tests run against real captured JSON in Fixtures/ — no `container`
        // install needed to run `swift test`.
        .testTarget(
            name: "FlotillaCoreTests",
            dependencies: ["FlotillaCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
