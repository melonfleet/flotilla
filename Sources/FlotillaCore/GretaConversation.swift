import Foundation

/// One message in a chat with Greta.
public struct GretaMessage: Codable, Identifiable, Equatable {
    public enum Role: String, Codable { case user, greta }
    public var id = UUID()
    public var date = Date()
    public var role: Role
    public var text: String
    /// A container she drafted, for the Run form.
    public var draft: GretaDraftRecord?
    /// She couldn't answer; the text says why.
    public var isProblem = false
    /// Offers Suggestions, for something that needs a stack. Optional so older chats still load.
    public var opensStacks: Bool?

    public init(role: Role, text: String, draft: GretaDraftRecord? = nil,
                isProblem: Bool = false, opensStacks: Bool? = nil) {
        self.role = role; self.text = text; self.draft = draft
        self.isProblem = isProblem; self.opensStacks = opensStacks
    }
}

/// A draft as saved with its chat — `RunPrefill` itself isn't stored.
public struct GretaDraftRecord: Codable, Equatable {
    public var image: String
    public var name: String
    public var ports: [String]
    public var env: [String]
    public var volumes: [String]

    public init(image: String, name: String, ports: [String], env: [String], volumes: [String]) {
        self.image = image; self.name = name; self.ports = ports; self.env = env; self.volumes = volumes
    }
}

/// One conversation, titled by its first question.
public struct GretaConversation: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var started = Date()
    public var title: String
    public var messages: [GretaMessage] = []
    public var isPinned = false
    public var isArchived = false

    public init(id: UUID = UUID(), started: Date = Date(), title: String,
                messages: [GretaMessage] = [], isPinned: Bool = false, isArchived: Bool = false) {
        self.id = id; self.started = started; self.title = title; self.messages = messages
        self.isPinned = isPinned; self.isArchived = isArchived
    }

    private enum CodingKeys: String, CodingKey { case id, started, title, messages, isPinned, isArchived }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        started = try values.decode(Date.self, forKey: .started)
        title = try values.decode(String.self, forKey: .title)
        messages = try values.decode([GretaMessage].self, forKey: .messages)
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isArchived = try values.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }

    public var lastActivity: Date { messages.last?.date ?? started }

    /// Pins first, newest activity first within each group, with a stable tie break.
    public static func ordered(_ chats: [Self]) -> [Self] {
        chats.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.lastActivity != $1.lastActivity { return $0.lastActivity > $1.lastActivity }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
