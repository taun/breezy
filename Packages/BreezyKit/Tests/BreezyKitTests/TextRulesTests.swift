import Foundation
import Testing
import Yams
@testable import BreezyKit

@Suite struct TextRulesTests {
    @Test func cleanTextPasses() {
        #expect(TextRules.check("Grit — “Passion” & 😀 café", .line, field: "Title") == nil)
        #expect(TextRules.check("Para one\n\n\tindented\r\nCRLF", .text, field: "Body") == nil)
    }

    @Test func controlCharactersAreRemovedWithAMessage() throws {
        let r = try #require(TextRules.check("Hot\u{0C}take\u{0B}AI\u{07}", .line, field: "Title"))
        #expect(r.text == "Hot take AI") // separators keep words apart; the bell just goes
        #expect(r.message == "Replaced a form feed (U+000C) and a vertical tab (U+000B) with a space. Removed a control character (U+0007). Title can't contain invisible control characters.")
        let body = try #require(TextRules.check("Page one\u{0C}Page two\u{85}End\u{1B}", .text, field: "The body"))
        #expect(body.text == "Page one\nPage two\nEnd")
        #expect(body.message == "Replaced a form feed (U+000C) and a next-line character (U+0085) with a line break. Removed an escape character (U+001B). The body can't contain invisible control characters.")
    }

    @Test func oneLineFieldsTurnBreaksAndTabsIntoSpaces() throws {
        let r = try #require(TextRules.check("Hot take\r\non\tAI\u{2028}tools", .line, field: "Summary"))
        #expect(r.text == "Hot take on AI tools")
        #expect(r.message == nil) // a break that became a space is in plain sight
    }

    @Test func aMergedFileKeepsItsBreaksButSeparatorsBecomeSpaces() throws {
        let r = try #require(TextRules.check("---\ntitle: Foo\u{0B}Bar\u{2028}Baz\r\n---\n\tBody\n", .file, field: "The merged version"))
        #expect(r.text == "---\ntitle: Foo Bar Baz\r\n---\n\tBody\n") // a break would have split the YAML value
    }

    @Test func noncharactersAreRemoved() throws {
        let r = try #require(TextRules.check("a\u{FFFE}b\u{10FFFF}", .line, field: "Title"))
        #expect(r.text == "ab")
    }

    @Test func filesWrittenElsewhereAreFlagged() throws {
        let n = try NodeFile(slug: "p", text: "---\ntitle: \"Bad\\fTitle\"\ntype: post\n---\n\nBody\u{0C}here\n")
        let messages = Validator.validate(n, allSlugs: ["p"]).map(\.message)
        #expect(messages.contains { $0.hasPrefix("Title contains a form feed (U+000C)") })
        #expect(messages.contains { $0.hasPrefix("The body contains a form feed (U+000C)") })
        let fine = try NodeFile(slug: "p", text: "---\ntitle: \"Fine\"\ntype: post\nsummary: \"Two\\nlines\\twith a tab\"\n---\n\nBody\n\twith a tab\n")
        #expect(Validator.validate(fine, allSlugs: ["p"]).isEmpty) // breaks and tabs are publishable
    }

    @Test func eachBadRelationIsItsOwnIssue() throws {
        let n = try NodeFile(slug: "p", text: "---\ntitle: \"P\"\ntype: post\nlinks: [{ to: a, rel: \"x\\ay\" }, { to: b, rel: \"x\\ay\" }]\n---\n")
        let messages = Validator.validate(n, allSlugs: ["p", "a", "b"]).map(\.message)
        #expect(Set(messages).count == messages.count)
        #expect(messages.contains { $0.hasPrefix("The relation of the link to a contains") })
    }

    /// Whatever YAMLFormat.quoted is given, the file stays valid YAML and reads back as written.
    @Test func everyCharacterRoundTripsThroughQuoting() throws {
        let awkward = (0..<0x20).map { String(UnicodeScalar($0)!) }.joined() + "\u{7F}\u{85}\u{9F}\u{2028}\u{2029}\u{FFFE}\u{FFFF}\u{10FFFF}\"\\ end"
        let quoted = YAMLFormat.quoted(awkward)
        #expect(!quoted.unicodeScalars.contains { !TextRules.isAllowed($0, .line) })
        let n = try NodeFile(slug: "p", text: "---\ntitle: \(quoted)\n---\n")
        #expect(n.title == awkward)
    }
}

@Suite struct CharacterCheckTests {
    @Test func textFromTheFileIsLeftAloneTypedTextIsCleaned() {
        var check = CharacterCheck()
        let fromFile = "Old\u{0C}title"
        #expect(check.review(fromFile, .line, field: "Title", sources: [fromFile]) == .forward) // as the file has it
        #expect(check.count == 0)
        #expect(check.review(fromFile + "!", .line, field: "Title", sources: [fromFile]) == .replace("Old title!"))
        #expect(check.count == 1)
        #expect(check.message == "Replaced a form feed (U+000C) with a space. Title can't contain invisible control characters.")
        #expect(check.review("Old title!", .line, field: "Title", sources: [fromFile]) == .forward)
    }

    @Test func aBreakThatBecameASpaceNeedsNoNote() {
        var check = CharacterCheck()
        #expect(check.review("Two\nlines", .line, field: "Summary", sources: []) == .replace("Two lines"))
        #expect(check.count == 0)
        #expect(check.message == nil)
    }
}
