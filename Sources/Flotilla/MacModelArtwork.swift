import AppKit
import FlotillaCore
import SwiftUI
import UniformTypeIdentifiers

/// The system's own artwork for a Mac model — what About This Mac draws. Local and offline: the
/// type tag is resolved by CoreTypes, the icon by `NSWorkspace`.
///
/// Measured on a macOS 27 VM: `Macmini9,1` and `Mac14,13` resolve to declared types with real
/// icons; an unknown identifier and `VirtualMac2,1` resolve to *dynamic* types, whose icon is a
/// blank document. So a dynamic type is "unknown", never drawn.
@MainActor
enum MacModelArtwork {
    struct Artwork {
        let image: NSImage
        /// "Mac mini", "Virtual Mac" — for the tooltip.
        let name: String
    }

    /// CoreTypes' generic display, the closest thing the system has to a virtual Mac. It has no
    /// declared type, so it is read from the bundle; if a future macOS moves it, the `display`
    /// symbol takes over rather than a blank.
    private static let displayIconPath = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/public.generic-lcd.icns"

    private static let cache = ModelIconCache<Artwork> { identifier in
        MainActor.assumeIsolated { lookup(identifier) }
    }

    /// `nil` means "draw today's symbol".
    static func artwork(for identifier: String?) -> Artwork? {
        switch MacModelKind(identifier) {
        case .unknown:
            return nil
        case .virtual:
            return cache.value(for: "VirtualMac")
        case .hardware(let model):
            return cache.value(for: model)
        }
    }

    private static func lookup(_ key: String) -> Artwork? {
        if key == "VirtualMac" {
            guard let image = NSImage(contentsOfFile: displayIconPath) else { return nil }
            return Artwork(image: image, name: "Virtual Mac")
        }
        let type = UTType(tag: key, tagClass: UTTagClass(rawValue: "com.apple.device-model-code"), conformingTo: nil)
        guard let type, !type.isDynamic, type.isDeclared else { return nil }
        return Artwork(image: NSWorkspace.shared.icon(for: type), name: type.localizedDescription ?? "Mac")
    }
}
