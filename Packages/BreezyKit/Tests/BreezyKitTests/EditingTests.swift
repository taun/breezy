import Foundation
import Testing
@testable import BreezyKit

@Suite struct EditingTests {
    let sample = """
    ---
    title: "Dan"
    type: person
    # kept comment
    date: 1983-01-01
    datePrecision: year
    custom: [a, b]
    links:
      - creo
      - to: ken
        rel: worked-at
    tags: [x]
    ---

    Body text.

    """

    @Test func newNodesStartAsDraftsAndGoingLiveStaysOutOfTheFeed() throws {
        var n = try NodeFile.new(slug: "post", title: "P", type: "post")
        #expect(n.draft)
        #expect(n.published == nil)
        try n.setDraft(false)
        #expect(!n.draft)
        #expect(n.published == nil)
    }

    @Test func goingBackToDraftLeavesTheFeed() throws {
        var n = try NodeFile(slug: "post", text: "---\ntitle: \"P\"\npublished: 2026-11-09\n---\n")
        #expect(n.published == "2026-11-09")
        try n.setDraft(true)
        #expect(n.published == nil)
        try n.setDraft(false)
        #expect(n.published == nil) // off again until the author switches it on
    }

    @Test func anInvalidPublishedIsReportedAndLeavesTheNodeOutOfTheFeed() throws {
        for bad in ["2026", "2026-02-30", "2026-11-08T23:30:00-08:00", "soon"] {
            let n = try NodeFile(slug: "post", text: "---\ntitle: \"P\"\npublished: \(bad)\n---\n")
            #expect(n.published == nil, "\(bad)")
            #expect(Validator.validate(n, allSlugs: ["post"]).contains { $0.message.contains("invalid published date") }, "\(bad)")
        }
        let leapDay = try NodeFile(slug: "post", text: "---\ntitle: \"P\"\npublished: 2028-02-29\n---\n")
        #expect(leapDay.published == "2028-02-29")
        #expect(leapDay.publishedWarning == nil)
        let empty = try NodeFile(slug: "post", text: "---\ntitle: \"P\"\npublished:\n---\n")
        #expect(empty.publishedWarning == nil)
    }

    @Test func newNodesAndSummariesKeepOnlyAllowedText() throws {
        var n = try NodeFile.new(slug: "p", title: "Ti\u{0C}tle", type: "po\u{07}st")
        #expect(n.title == "Ti tle")
        #expect(n.type == "post")
        #expect(n.characterProblems.isEmpty)
        try n.setSummary("Two\nlines")
        #expect(n.summary == "Two\nlines") // the site shows the break as a space
    }

    @Test func settingTheCurrentValueLeavesTheFileAsWritten() throws {
        let text = "---\ntitle: \"Bad\\fTitle\"\ntags: [\"a\\ab\"]\nlinks: []\n---\n\nBody\u{0C}\n"
        var n = try NodeFile(slug: "p", text: text)
        try n.setTitle(n.title)
        try n.setTags(n.tags)
        try n.setLinks(n.links)
        try n.setSummary(n.summary)
        n.setBody(n.body)
        #expect(n.rendered() == text)
        #expect(n.characterProblems.count == 3)
    }

    @Test func aFuturePublishedDateIsWarnedAbout() throws {
        let n = try NodeFile(slug: "p", text: "---\ntitle: \"P\"\ntype: post\npublished: 2026-11-12\n---\n")
        let nov9 = Date(timeIntervalSince1970: 1_794_225_600) // 2026-11-09 12:00 UTC
        #expect(Validator.validate(n, allSlugs: ["p"], now: nov9).contains { $0.message.contains("in the future") })
        let nov11 = nov9.addingTimeInterval(2 * 86_400) // the site takes up to tomorrow
        #expect(!Validator.validate(n, allSlugs: ["p"], now: nov11).contains { $0.message.contains("in the future") })
    }

    @Test func settingPublishedChangesOnlyItsLine() throws {
        var n = try NodeFile(slug: "dan", text: sample)
        let before = n.rendered()
        try n.setPublished("2026-11-09")
        #expect(n.published == "2026-11-09")
        #expect(n.date?.iso == "1983-01-01")
        try n.setPublished(nil)
        #expect(n.rendered() == before)
    }

    @Test func todayIsInTheAuthorsTimeZone() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let lateEvening = Date(timeIntervalSince1970: 1_794_279_600) // 2026-11-10 03:00 UTC
        #expect(NodeFile.todayISO(now: lateEvening, timeZone: newYork) == "2026-11-09")
    }

    @Test func otherScriptsDigitsAreAnInvalidPublishedDateNotACrash() throws {
        let n = try NodeFile(slug: "p", text: "---\ntitle: \"P\"\npublished: ٢٠٢٦-١١-٠٩\n---\n")
        #expect(n.published == nil)
        #expect(n.publishedWarning != nil)
    }

    @Test func settersStoreOnlyAllowedText() throws {
        var n = try NodeFile(slug: "p", text: "---\ntitle: \"P\"\nlinks: []\n---\n")
        try n.setTitle("A\u{07}B\u{0C}C")
        #expect(n.title == "AB C")
        try n.setSummary("S\u{07}")
        #expect(n.summary == "S")
        try n.setTags(["x\u{07}y", "\u{07}"])
        #expect(n.tags == ["xy"]) // a tag of nothing but refused characters is dropped
        try n.setString("video", "https://x\u{07}.org")
        #expect(n.strings["video"] == "https://x.org")
        try n.setLinks([NodeLink(to: "q", rel: "worked\u{07}-at"), NodeLink(to: "r", rel: "\u{07}")])
        #expect(n.links.map(\.rel) == ["worked-at", Relations.defaultRel])
        n.setBody("Body\u{0C}\n\ttab")
        #expect(n.body == "Body\n\n\ttab")
        #expect(n.characterProblems.isEmpty)
    }

    @Test func settingLinksChangesOnlyTheLinksBlock() throws {
        var n = try NodeFile(slug: "dan", text: sample)
        try n.setLinks([NodeLink(to: "creo"), NodeLink(to: "ken", rel: "founded")])
        let expected = sample.replacingOccurrences(
            of: "links:\n  - creo\n  - to: ken\n    rel: worked-at",
            with: "links: [creo, { to: ken, rel: founded }]")
        #expect(n.rendered() == expected)
        #expect(n.links == [NodeLink(to: "creo"), NodeLink(to: "ken", rel: "founded")])
    }

    @Test func unknownKeysAndCommentsSurvive() throws {
        var n = try NodeFile(slug: "dan", text: sample)
        try n.setType("company")
        try n.setSummary("One line")
        let out = n.rendered()
        #expect(out.contains("# kept comment\n"))
        #expect(out.contains("custom: [a, b]\n"))
        #expect(out.contains("type: company\n"))
        #expect(out.contains("summary: \"One line\"\n"))
        #expect(out.hasSuffix("Body text.\n"))
    }

    @Test func dateRoundTripsAsBareYearStyle() throws {
        var n = try NodeFile(slug: "x", text: "---\ntitle: \"x\"\n---\n")
        try n.setDate(NodeDate(iso: "2021-01-01", precision: .year))
        #expect(n.rendered().contains("date: 2021-01-01\ndatePrecision: year\n"))
        #expect(n.date == NodeDate(iso: "2021-01-01", precision: .year))
        try n.setDate(nil)
        #expect(n.date == nil)
        #expect(!n.rendered().contains("date"))
    }

    @Test func titlesWithQuotesAreEscaped() throws {
        var n = try NodeFile(slug: "x", text: "---\ntitle: \"x\"\n---\n")
        try n.setTitle("Say \"hi\": a\\b")
        #expect(n.title == "Say \"hi\": a\\b")
    }

    @Test func relationNormalizationAndValidation() throws {
        let n = try NodeFile(slug: "a", text: "---\ntitle: \"A\"\nlinks: [{ to: b, rel: Worked At }, b, gone, a]\n---\n")
        #expect(n.links == [NodeLink(to: "b", rel: "worked-at"), NodeLink(to: "b"), NodeLink(to: "gone")])
        let issues = Validator.validate(n, allSlugs: ["a", "b"])
        #expect(issues.contains { $0.message.contains("unknown node \"gone\"") })
        #expect(Validator.validateSlug("Bad Slug", existing: []).count == 1)
        #expect(Validator.validateSlug("a", existing: ["a"]).count == 1)
    }

    @Test func missingFrontMatterThrows() {
        #expect(throws: NodeFileError.noFrontMatter) { try NodeFile(slug: "x", text: "no front matter") }
    }
}
