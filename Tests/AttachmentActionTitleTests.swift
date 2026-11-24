import Foundation
import Testing
@testable import SerialManager

/// SM-07: the failure alert of the attachment section names the action that failed, in English and
/// in Italian, instead of calling every failure an open error.
struct AttachmentActionTitleTests {
    private static let english: [AttachmentAction: String] = [
        .open: "Couldn't Open the Attachment",
        .saveCopy: "Couldn't Save a Copy of the Attachment",
        .remove: "Couldn't Remove the Attachment",
    ]
    private static let italian: [AttachmentAction: String] = [
        .open: "Impossibile aprire l'allegato",
        .saveCopy: "Impossibile salvare una copia dell'allegato",
        .remove: "Impossibile rimuovere l'allegato",
    ]

    /// The Italian value of `key` as the catalog stores it.
    private func catalogItalian(_ key: String) throws -> String? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        let strings = try #require((json as? [String: Any])?["strings"] as? [String: Any])
        let localizations = (strings[key] as? [String: Any])?["localizations"] as? [String: Any]
        let unit = (localizations?["it"] as? [String: Any])?["stringUnit"] as? [String: Any]
        return unit?["value"] as? String
    }

    @Test("Each attachment action has its own title")
    func titlesDiffer() {
        let titles = AttachmentAction.allCases.map(\.failureTitle)
        #expect(Set(titles).count == AttachmentAction.allCases.count)
        #expect(titles.allSatisfy { !$0.isEmpty })
    }

    @Test("Every title resolves to its English or Italian text, never to another action's")
    func titlesResolveToTheirOwnText() throws {
        for action in AttachmentAction.allCases {
            let english = try #require(Self.english[action])
            let italian = try #require(Self.italian[action])
            // The test host runs in whatever language the machine uses.
            #expect([english, italian].contains(action.failureTitle))
            #expect(try catalogItalian(english) == italian)
        }
    }
}
