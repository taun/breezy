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
