import SwiftUI
import FlotillaCore

/// The tags Flotilla gives a Mac itself (the owner, 9 October): **This Mac** on the one you are
/// using, and **Admin** and **Host** from the role set in Settings ▸ Host Mode. They sit in the
/// Tags column ahead of the owner's own tags, so the Name column holds only the name and stays one
/// line.
///
/// Not stored, not in the Tags menu, not removable: each is read from the Mac's state every time
/// it is drawn, so it cannot fall out of step with the role. A host reports its role in its facts;
/// a host that has not answered yet, or runs a build that does not say, is still a host — that is
/// how it is in this list.
enum BuiltInHostTag: String, CaseIterable, Identifiable {
    case thisMac, admin, host

    var id: Self { self }

    var name: String {
        switch self {
        case .thisMac: "This Mac"
        case .admin: "Admin"
        case .host: "Host"
        }
    }

    var symbol: String {
        switch self {
        case .thisMac: "location.fill"
        case .admin: "person.badge.key"
        case .host: "server.rack"
        }
    }

    var help: String {
        switch self {
        case .thisMac: "The Mac you're using. Set by flotilla — it can't be changed."
        case .admin: "Manages other Macs (Settings ▸ Host Mode). Set by flotilla from the Mac's role — it can't be changed here."
        case .host: "Runs containers for an admin Mac (Settings ▸ Host Mode). Set by flotilla from the Mac's role — it can't be changed here."
        }
    }

    /// A Mac's built-in tags, This Mac first. `role` is a `RunMode` raw value — This Mac's own
    /// mode, or the one a host reported; nil on a listed host means a host.
    static func tags(isThisMac: Bool, role: String?) -> [BuiltInHostTag] {
        let mode = role.flatMap(RunMode.init(rawValue:)) ?? (isThisMac ? .client : .host)
        var tags: [BuiltInHostTag] = isThisMac ? [.thisMac] : []
        if mode != .host { tags.append(.admin) }
        if mode != .client { tags.append(.host) }
        return tags
    }
}

/// A built-in tag, drawn beside the owner's tags but plainly not one of them: a symbol where a
/// coloured tag has its dot, and a neutral capsule, so it reads as a fact about the Mac rather than
/// a label someone chose.
struct BuiltInTagPill: View {
    let tag: BuiltInHostTag
    var compact = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: tag.symbol)
                .font(.system(size: compact ? 8 : 9, weight: .semibold))
            Text(tag.name)
                .font(.system(size: compact ? 10 : 11, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, compact ? 5 : 6)
        .padding(.vertical, compact ? 1 : 2)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.3)))
        .foregroundStyle(.secondary)
        .help(tag.help)
        .fixedSize()
        .accessibilityLabel("\(tag.name), built in")
    }
}
