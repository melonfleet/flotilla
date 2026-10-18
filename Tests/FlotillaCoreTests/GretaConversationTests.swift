import Foundation
import Testing
@testable import FlotillaCore

@Suite struct GretaConversationTests {
    @Test func oldChatFileDecodesWithoutMetadata() throws {
        // The pre-metadata array format, including an original message and draft.
        let oldFile = Data("""
        [{"id":"00000000-0000-0000-0000-000000000001","started":100,
          "title":"Draft Postgres","messages":[
            {"id":"00000000-0000-0000-0000-000000000002","date":101,
             "role":"greta","text":"Here is a draft","isProblem":false,
             "draft":{"image":"postgres:17","name":"db","ports":[],"env":[],"volumes":[]}}
          ]}]
        """.utf8)
        let chat = try #require(JSONDecoder().decode([GretaConversation].self, from: oldFile).first)
        #expect(!chat.isPinned)
        #expect(!chat.isArchived)
        #expect(chat.title == "Draft Postgres")
        #expect(chat.messages.first?.draft?.image == "postgres:17")
        #expect(chat.lastActivity == Date(timeIntervalSinceReferenceDate: 101))
    }

    @Test func metadataSurvivesTheSameArrayFileFormat() throws {
        let chat = GretaConversation(title: "My renamed chat", isPinned: true, isArchived: true)
        let data = try JSONEncoder().encode([chat])
        #expect(try JSONDecoder().decode([GretaConversation].self, from: data) == [chat])
    }

    @Test func pinsPrecedeNewerUnpinnedConversations() {
        let pinnedOld = GretaConversation(started: Date(timeIntervalSinceReferenceDate: 10), title: "Old pin", isPinned: true)
        let pinnedNew = GretaConversation(started: Date(timeIntervalSinceReferenceDate: 20), title: "New pin", isPinned: true)
        let recent = GretaConversation(started: Date(timeIntervalSinceReferenceDate: 30), title: "Recent")
        let older = GretaConversation(started: Date(timeIntervalSinceReferenceDate: 5), title: "Older")
        #expect(GretaConversation.ordered([recent, pinnedOld, older, pinnedNew]).map(\.title)
                == ["New pin", "Old pin", "Recent", "Older"])
        var unpinned = pinnedOld
        unpinned.isPinned = false
        #expect(GretaConversation.ordered([unpinned, recent]).map(\.title) == ["Recent", "Old pin"])
    }

    @Test func messageActivityDeterminesOrderWithinPins() {
        var message = GretaMessage(role: .user, text: "Follow up")
        message.date = Date(timeIntervalSinceReferenceDate: 50)
        let active = GretaConversation(started: Date(timeIntervalSinceReferenceDate: 1), title: "Active", messages: [message], isPinned: true)
        let newer = GretaConversation(started: Date(timeIntervalSinceReferenceDate: 30), title: "Newer", isPinned: true)
        #expect(GretaConversation.ordered([newer, active]).map(\.title) == ["Active", "Newer"])
    }
}
