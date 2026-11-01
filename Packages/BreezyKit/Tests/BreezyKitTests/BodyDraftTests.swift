import Testing
@testable import BreezyKit

struct BodyDraftTests {
    @Test func keysAreSeparatePerBranchAndNode() {
        #expect(BodyDraft.key(branch: "main", slug: "a") != BodyDraft.key(branch: "main", slug: "b"))
        #expect(BodyDraft.key(branch: "main", slug: "a") != BodyDraft.key(branch: "work", slug: "a"))
    }

    @Test func emptyIsNoDraft() {
        #expect(!BodyDraft.isStarted(""))
        #expect(BodyDraft.isStarted("x"))
        #expect(BodyDraft.bodyWhenUsed("new\ntext") == "new\ntext")
    }
}
