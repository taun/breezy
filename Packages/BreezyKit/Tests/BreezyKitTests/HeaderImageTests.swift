import Foundation
import Testing
@testable import BreezyKit
import BreezyKitTestSupport

@Suite struct HeaderEditingTests {
    private func node(_ front: String) throws -> NodeFile { try NodeFile(slug: "n", text: "---\n\(front)\n---\nbody\n") }

    @Test func addsAHeaderToANodeWithout() throws {
        var n = try node("title: N\ntype: post\ntags: []")
        try n.setHeader(image: "/assets/images/n-header.jpg", teaser: "/assets/images/n-teaser.jpg")
        #expect(n.header == NodeHeader(image: "/assets/images/n-header.jpg", teaser: "/assets/images/n-teaser.jpg"))
        #expect(n.frontMatter.lines.suffix(3) == ["header:", "  image: /assets/images/n-header.jpg", "  teaser: /assets/images/n-teaser.jpg"])
    }

    @Test func keepsTheDescriptionCommentsAndOtherKeys() throws {
        var n = try node("title: N\nheader:\n  image: /assets/images/old.png\n  # why\n  image_description: \"A cover\"\n  extra: 1\ntags: []")
        try n.setHeader(image: "/assets/images/new.jpg", teaser: "/assets/images/new-small.jpg")
        #expect(n.frontMatter.lines == ["title: N", "header:", "  image: /assets/images/new.jpg", "  # why", "  image_description: \"A cover\"", "  extra: 1",
                                        "  teaser: /assets/images/new-small.jpg", "tags: []"])
        #expect(n.header.imageDescription == "A cover")
    }

    @Test func removingBothDropsAnEmptyHeaderButNotOtherKeys() throws {
        var a = try node("title: N\nheader:\n  image: /a.png\n  teaser: /b.png\ntags: []")
        try a.setHeader(image: nil, teaser: nil)
        #expect(a.frontMatter.lines == ["title: N", "tags: []"] && a.header == NodeHeader())
        var b = try node("title: N\nheader:\n  image: /a.png\n  image_description: d")
        try b.setHeader(image: nil, teaser: nil)
        #expect(b.frontMatter.lines == ["title: N", "header:", "  image_description: d"])
    }

    @Test func aFlowStyleHeaderBecomesABlockWithItsValues() throws {
        var n = try node("title: N\nheader: {image: /a.png, image_description: d}")
        try n.setHeader(image: "/b.png", teaser: nil)
        #expect(n.header == NodeHeader(image: "/b.png", teaser: nil, imageDescription: "d"))
        #expect(n.frontMatter.lines.first == "title: N" && !n.frontMatter.lines.contains { $0.contains("{") })
    }

    @Test func aFlowStyleHeaderKeepsItsOrderAndValuesAsWritten() throws {
        var n = try node("title: N\nheader: {teaser: /t.png, show: true, image_description: 'A, b', alt: \"c\"} # credit: Bob")
        try n.setHeader(image: "/b.png", teaser: "/t.png")
        #expect(n.frontMatter.lines == ["title: N", "header: # credit: Bob", "  teaser: /t.png", "  show: true", "  image_description: 'A, b'",
                                        "  alt: \"c\"", "  image: /b.png"])
    }

    @Test func aCommentAfterAOneLineHeaderIsKeptAndGoesWithIt() throws {
        var n = try node("title: N\nheader: {image: /a.jpg} # see {credits}")
        try n.setHeader(image: "/b.jpg", teaser: nil)
        #expect(n.frontMatter.lines == ["title: N", "header: # see {credits}", "  image: /b.jpg"])
        try n.setHeader(image: nil, teaser: nil)
        #expect(n.frontMatter.lines == ["title: N"])
        var empty = try node("title: N\nheader: null # later")
        try empty.setHeader(image: "/b.jpg", teaser: nil)
        #expect(empty.frontMatter.lines == ["title: N", "header: # later", "  image: /b.jpg"])
        #expect(FrontMatterText.splitComment("{a: 'x # y'} # z") == ("{a: 'x # y'}", "# z"))
        #expect(FrontMatterText.splitComment("{a: x#y}") == ("{a: x#y}", ""))
    }

    @Test func aHeaderBreezyCannotRewriteIsLeftAlone() throws {
        for front in ["header: {image: /a.png, alt: [x, y]}", "header: just-text"] {
            var n = try node("title: N\n\(front)")
            let before = n.frontMatter
            #expect(throws: NodeFileError.self) { try n.setHeader(image: "/b.png", teaser: "/c.png") }
            #expect(n.frontMatter == before)
        }
    }

    @Test func aBlankLineAtTheTopOfTheHeaderKeepsTheIndent() throws {
        var n = try node("title: N\nheader:\n\n  image_description: d\ntags: []")
        try n.setHeader(image: "/b.png", teaser: nil)
        #expect(n.header == NodeHeader(image: "/b.png", teaser: nil, imageDescription: "d"))
    }
}

@MainActor @Suite struct AssetCommitTests {
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4])

    private func blobs(_ m: MockTransport) {
        m.on("POST /git/blobs", status: 201, ["sha": GitBlob.sha(of: png)])
    }

    @Test func aNewImageIsCommittedWithTheNodeThatUsesIt() async throws {
        let store = tempStore()
        let m = MockTransport.site()
        let ws = try await SiteWorkspace.download("main", client: client(m), store: store)
        let path = "/assets/images/a-header.png"
        try ws.addAsset(png, at: path)
        try ws.update("a") { try $0.setHeader(image: path, teaser: nil) }
        // Offline: the preview has the bytes, the picker lists the image, and a relaunch keeps it all.
        #expect(ws.imageData(path) == png && ws.assetPaths.contains(path) && ws.hasAsset(path))
        #expect(store.hasLocalChanges("main"))
        try ws.commit(message: "Add header")
        #expect(ws.queue.first?.changes.map(\.path) == ["src/nodes/a.md", "src/assets/images/a-header.png"])
        let reopened = try #require(try SiteWorkspace.open("main", store: store))
        #expect(reopened.imageData(path) == png && reopened.queue.count == 1)

        blobs(m)
        m.acceptCommits()
        #expect(try await ws.sync(client: client(m)) == .synced(pushed: 1))
        let upload = try #require(m.bodies("POST /git/blobs").first)
        #expect(upload["encoding"] as? String == "base64" && upload["content"] as? String == png.base64EncodedString())
        let tree = try #require(m.bodies("POST /git/trees").first?["tree"] as? [[String: Any]])
        let entry = try #require(tree.first { $0["path"] as? String == "src/assets/images/a-header.png" })
        #expect(entry["sha"] as? String == GitBlob.sha(of: png) && entry["content"] == nil)
        #expect(ws.state.base.assetSHAs?[path] == GitBlob.sha(of: png) && ws.assetPaths.contains(path))
        #expect(ws.imageData(path) == png && ws.queue.isEmpty)
    }

    @Test func anImageNoChangedNodeUsesIsLeftOutOfTheCommit() async throws {
        let store = tempStore()
        let ws = try await SiteWorkspace.download("main", client: client(.site()), store: store)
        try ws.addAsset(png, at: "/assets/images/unused.png")
        try ws.update("a") { try $0.setTitle("A2") }
        try ws.commit(message: "Edit")
        #expect(ws.queue.first?.changes.map(\.path) == ["src/nodes/a.md"])
        #expect(ws.state.pendingAssets == nil)
    }

    @Test func imagesGoOutsideAssetsNowhere() async throws {
        let ws = try await SiteWorkspace.download("main", client: client(.site()), store: tempStore())
        #expect(throws: WorkspaceError.self) { try ws.addAsset(png, at: "/src/nodes/x.md") }
        #expect(throws: WorkspaceError.self) { try ws.addAsset(png, at: "/assets/../x.png") }
    }

    @Test func aBlobGitHubStoresUnderAnotherSHAStopsThePush() async throws {
        let m = MockTransport.site()
        let ws = try await SiteWorkspace.download("main", client: client(m), store: tempStore())
        try ws.addAsset(png, at: "/assets/images/a-header.png")
        try ws.update("a") { try $0.setHeader(image: "/assets/images/a-header.png", teaser: nil) }
        try ws.commit(message: "Add header")
        m.on("POST /git/blobs", status: 201, ["sha": "other"])
        m.acceptCommits()
        await #expect(throws: GitHubError.invalidResponse) { try await ws.sync(client: client(m)) }
        #expect(ws.queue.count == 1 && m.bodies("POST /git/trees").isEmpty)
    }

    /// An older copy has no asset shas until a sync fills them all in; a pushed picture must not stand in for them.
    @Test func aPushedImageLeavesMissingAssetSHAsMissing() {
        var base = Snapshot(commit: "c", files: [:], assets: [])
        base.applyAsset("src/assets/images/a.png", sha: "s")
        #expect(base.assets == ["/assets/images/a.png"] && base.assetSHAs == nil)
        base.assetSHAs = [:]
        base.applyAsset("src/assets/images/a.png", sha: "s")
        #expect(base.assetSHAs == ["/assets/images/a.png": "s"])
    }

    @Test func usingGitHubsVersionOfANodeDropsItsQueuedPicture() async throws {
        let m = MockTransport.site()
        let ws = try await SiteWorkspace.download("main", client: client(m), store: tempStore())
        try ws.setHeaderImage(slug: "a", from: testImage(width: 800, height: 600), makeThumbnail: false)
        try ws.commit(message: "Picture")
        m.remoteMoves(to: "c9", changing: ["src/nodes/a.md": "---\ntitle: \"Theirs A\"\ntype: person\nlinks: []\n---\n"])
        #expect(try await ws.sync(client: client(m)) == .conflicts(1))
        try ws.resolve("src/nodes/a.md", with: .theirs)
        #expect(ws.queue.isEmpty && !ws.assetPaths.contains("/assets/images/a-header.jpg"))
    }

    /// GitHub's version of the node has the same picture path: the picture replaced here goes with the rest of mine.
    @Test func usingGitHubsVersionDropsAReplacedPictureAtTheSamePath() async throws {
        let m = MockTransport.site()
        let ws = try await SiteWorkspace.download("main", client: client(m), store: tempStore())
        try ws.setHeaderImage(slug: "a", from: testImage(width: 800, height: 600), makeThumbnail: false)
        let theirs = try #require(ws.nodes["a"]?.rendered()).replacingOccurrences(of: "title: \"A\"", with: "title: \"Theirs A\"")
        try ws.update("a") { try $0.setSummary("Mine") }
        m.remoteMoves(to: "c9", changing: ["src/nodes/a.md": theirs])
        // Uncommitted here: the conflict is between the working edit and GitHub's.
        #expect(try await ws.sync(client: client(m)) == .conflicts(1))
        try ws.resolve("src/nodes/a.md", with: .theirs)
        #expect(ws.nodes["a"]?.header.image == "/assets/images/a-header.jpg" && ws.state.pendingAssets == nil && !ws.hasChanges)
    }

    @Test func aQueuedPictureAnotherNodeNowUsesStaysWhenItsNodeTakesGitHubsVersion() async throws {
        let m = MockTransport.site()
        let ws = try await SiteWorkspace.download("main", client: client(m), store: tempStore())
        try ws.setHeaderImage(slug: "a", from: testImage(width: 800, height: 600), makeThumbnail: false)
        try ws.commit(message: "Picture")
        try ws.update("b") { try $0.setHeader(image: "/assets/images/a-header.jpg", teaser: nil) }
        m.remoteMoves(to: "c9", changing: ["src/nodes/a.md": "---\ntitle: \"Theirs A\"\ntype: person\nlinks: []\n---\n"])
        #expect(try await ws.sync(client: client(m)) == .conflicts(1))
        try ws.resolve("src/nodes/a.md", with: .theirs)
        #expect(ws.queue.flatMap(\.changes).map(\.path) == ["src/assets/images/a-header.jpg"])
    }

    /// The queued versions count: the picture stays for another node's queued commit, and goes when only the
    /// dropped version of this node used it (here the node shows another banner since).
    @Test func queuedVersionsDecideWhetherAQueuedPictureStays() async throws {
        let m = MockTransport.site()
        let ws = try await SiteWorkspace.download("main", client: client(m), store: tempStore())
        try ws.setHeaderImage(slug: "a", from: testImage(width: 800, height: 600), makeThumbnail: false)
        try ws.commit(message: "Picture for a")
        try ws.update("b") { try $0.setHeader(image: "/assets/images/a-header.jpg", teaser: nil) }
        try ws.commit(message: "b uses it")
        try ws.update("b") { try $0.setHeader(image: nil, teaser: nil) }
        try ws.update("a") { try $0.setHeader(image: "/assets/images/other.png", teaser: nil) }
        m.remoteMoves(to: "c9", changing: ["src/nodes/a.md": "---\ntitle: \"Theirs A\"\ntype: person\nlinks: []\n---\n"])
        #expect(try await ws.sync(client: client(m)) == .conflicts(1))
        try ws.resolve("src/nodes/a.md", with: .theirs)
        #expect(ws.queue.flatMap(\.changes).map(\.path).contains("src/assets/images/a-header.jpg")) // b's queued commit needs it
    }

    @Test func oldQueueFilesWithoutBlobsStillDecode() throws {
        let change = try JSONDecoder().decode(FileChange.self, from: Data(#"{"path":"src/nodes/a.md","content":"x"}"#.utf8))
        #expect(change.blobSHA == nil && change.content == "x")
    }
}

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A solid-color test image; `alpha` below 255 makes a transparent PNG.
func testImage(width: Int, height: Int, alpha: UInt8 = 255, type: UTType = .png) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(srgbRed: Double(alpha) / 255 * 0.8, green: 0.2 * Double(alpha) / 255, blue: 0.1 * Double(alpha) / 255, alpha: Double(alpha) / 255))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return out as Data
}

@Suite struct ImageResizerTests {
    @Test func fitKeepsProportionsAndNeverEnlarges() {
        #expect(ImageFit.size(of: CGSize(width: 3000, height: 1000), in: ImageResizer.headerBox) == CGSize(width: 1344, height: 448))
        #expect(ImageFit.size(of: CGSize(width: 1000, height: 2000), in: ImageResizer.teaserBox) == CGSize(width: 160, height: 320))
        #expect(ImageFit.size(of: CGSize(width: 200, height: 100), in: ImageResizer.headerBox) == CGSize(width: 200, height: 100))
        #expect(ImageFit.size(of: .zero, in: ImageResizer.headerBox) == .zero)
    }

    @Test func aLargeOpaqueImageBecomesAJPEGInTheBox() throws {
        let out = try ImageResizer.resize(testImage(width: 3000, height: 1000), fitting: ImageResizer.headerBox)
        #expect(out.fileExtension == "jpg" && out.width == 1344 && out.height == 448)
        let source = try #require(CGImageSourceCreateWithData(out.data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 1344 && props[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test func aSmallImageIsNotEnlarged() throws {
        let out = try ImageResizer.resize(testImage(width: 300, height: 200), fitting: ImageResizer.headerBox)
        #expect(out.width == 300 && out.height == 200)
    }

    @Test func transparencyKeepsAPNG() throws {
        let out = try ImageResizer.resize(testImage(width: 400, height: 400, alpha: 100), fitting: ImageResizer.teaserBox)
        #expect(out.fileExtension == "png" && out.width == 320 && out.height == 320)
    }

    @Test func somethingThatIsNotAnImageThrows() {
        #expect(throws: ImageError.notAnImage) { try ImageResizer.resize(Data("hello".utf8), fitting: ImageResizer.headerBox) }
        #expect(throws: ImageError.notAnImage) { try ImageResizer.resize(Data(), fitting: ImageResizer.teaserBox) }
    }

    @Test func bothSizesAreMadeAndNamedAfterTheNode() throws {
        let picture = testImage(width: 2000, height: 1600)
        let header = try ImageResizer.resize(picture, fitting: ImageResizer.headerBox)
        let teaser = try ImageResizer.resize(picture, fitting: ImageResizer.teaserBox)
        #expect(header.height == 448 && header.width == 560)
        #expect(teaser.height == 320 && teaser.width == 400)
        #expect(HeaderImages.sitePath(slug: "grit", teaser: true, fileExtension: "jpg") == "/assets/images/grit-teaser.jpg")
    }
}

@MainActor @Suite struct SetHeaderImageTests {
    @Test func aPictureBecomesTheNodesBannerAndThumbnail() async throws {
        let store = tempStore()
        let ws = try await SiteWorkspace.download("main", client: client(.site()), store: store)
        try ws.setHeaderImage(slug: "a", from: testImage(width: 2000, height: 1600))
        let header = try #require(ws.nodes["a"]?.header)
        #expect(header.image == "/assets/images/a-header.jpg" && header.teaser == "/assets/images/a-teaser.jpg")
        #expect(ws.imageData("/assets/images/a-header.jpg") != nil && ws.imageData("/assets/images/a-teaser.jpg") != nil)
        try ws.commit(message: "Picture")
        #expect(ws.queue.first?.changes.map(\.path).sorted() == ["src/assets/images/a-header.jpg", "src/assets/images/a-teaser.jpg", "src/nodes/a.md"])
    }

    @Test func withoutAThumbnailTheExistingOneStaysAndABadFileChangesNothing() async throws {
        let ws = try await SiteWorkspace.download("main", client: client(.site()), store: tempStore())
        try ws.update("a") { try $0.setHeader(image: nil, teaser: "/assets/images/old-small.png") }
        try ws.setHeaderImage(slug: "a", from: testImage(width: 800, height: 800), makeThumbnail: false)
        #expect(ws.nodes["a"]?.header == NodeHeader(image: "/assets/images/a-header.jpg", teaser: "/assets/images/old-small.png"))
        let before = ws.nodes["a"]?.rendered()
        #expect(throws: ImageError.notAnImage) { try ws.setHeaderImage(slug: "a", from: Data("nope".utf8)) }
        #expect(ws.nodes["a"]?.rendered() == before)
        try ws.removeHeaderImage(slug: "a")
        #expect(ws.nodes["a"]?.header == NodeHeader())
        #expect(ws.state.pendingAssets == nil && !ws.hasChanges) // nothing uses the new banner any more
    }

    /// A new picture for a node that has one keeps its path, so the node's text does not change: the picture alone
    /// is the change, committed like any other, and Revert takes it back.
    @Test func replacingAPictureIsAChangeOfItsOwn() async throws {
        let ws = try await SiteWorkspace.download("main", client: client(.site()), store: tempStore())
        try ws.setHeaderImage(slug: "a", from: testImage(width: 800, height: 600))
        try ws.commit(message: "Picture")
        let first = try #require(ws.assetSHA("/assets/images/a-header.jpg"))

        try ws.setHeaderImage(slug: "a", from: testImage(width: 900, height: 600))
        #expect(ws.changes.isEmpty) // the text is the same
        #expect(ws.hasChanges && ws.isModified("a") && ws.changedNodes == [.init(slug: "a", file: .edited)])
        try ws.revert("a")
        #expect(!ws.hasChanges && ws.assetSHA("/assets/images/a-header.jpg") == first)

        try ws.setHeaderImage(slug: "a", from: testImage(width: 900, height: 600))
        try ws.commit(message: "New picture")
        #expect(ws.queue.count == 2 && ws.queue[1].changes.map(\.path) == ["src/assets/images/a-header.jpg", "src/assets/images/a-teaser.jpg"])
        #expect(ws.assetSHA("/assets/images/a-header.jpg") != first && !ws.hasChanges)
    }

    @Test func thePictureAlreadyThereIsNoChange() async throws {
        let ws = try await SiteWorkspace.download("main", client: client(.site()), store: tempStore())
        let picture = testImage(width: 800, height: 600)
        try ws.setHeaderImage(slug: "a", from: picture)
        try ws.commit(message: "Picture")
        try ws.setHeaderImage(slug: "a", from: picture)
        #expect(!ws.hasChanges && ws.state.pendingAssets == nil)
    }

    @Test func aBannerTheNodeNoLongerUsesIsDropped() async throws {
        let ws = try await SiteWorkspace.download("main", client: client(.site()), store: tempStore())
        try ws.setHeaderImage(slug: "a", from: testImage(width: 800, height: 600), makeThumbnail: false)
        try ws.setHeaderImage(slug: "a", from: testImage(width: 800, height: 600, alpha: 100), makeThumbnail: false)
        #expect(ws.state.pendingAssets.map { Array($0.keys) } == ["/assets/images/a-header.png"])
    }

    /// Any edit that stops using a new picture forgets it, or the branch would count as changed with nothing to commit.
    @Test func choosingAnotherFileForgetsTheNewPicture() async throws {
        let store = tempStore()
        let ws = try await SiteWorkspace.download("main", client: client(.site()), store: store)
        let committed = try #require(ws.nodes["a"]?.rendered())
        try ws.setHeaderImage(slug: "a", from: testImage(width: 800, height: 600))
        try ws.update("a") { try $0.setHeader(image: nil, teaser: nil) }
        #expect(ws.nodes["a"]?.rendered() == committed)
        #expect(ws.state.pendingAssets == nil && !ws.hasChanges && !store.hasLocalChanges("main"))
    }

    @Test func aHeaderBreezyCannotRewriteKeepsNoPicture() async throws {
        let ws = try await SiteWorkspace.download("main", client: client(.site()), store: tempStore())
        try ws.update("a") { $0 = try NodeFile(slug: "a", text: $0.rendered().replacingOccurrences(of: "type:", with: "header: {alt: [x]}\ntype:")) }
        #expect(throws: NodeFileError.self) { try ws.setHeaderImage(slug: "a", from: testImage(width: 800, height: 600)) }
        #expect(ws.state.pendingAssets == nil)
    }
}

@Suite struct ImageSourceTests {
    @Test func addressesGetHTTPSAndOnlyHTTPSIsAccepted() throws {
        #expect(try ImageSource.url(from: " example.com/a.png ").absoluteString == "https://example.com/a.png")
        #expect(try ImageSource.url(from: "https://example.com/a b".replacingOccurrences(of: " ", with: "%20")).host == "example.com")
        #expect(throws: ImageFetchError.insecure) { try ImageSource.url(from: "http://example.com/a.png") }
        #expect(ImageSource.secured("HTTP://example.com/a.png") == "https://example.com/a.png")
        #expect(ImageSource.secured("https://example.com/http://a.png") == "https://example.com/http://a.png")
        #expect(throws: ImageFetchError.insecure) { try ImageSource.url(from: "file:///etc/hosts") }
        #expect(throws: ImageFetchError.invalidURL) { try ImageSource.url(from: "") }
        #expect(throws: ImageFetchError.invalidURL) { try ImageSource.url(from: "not a url") }
        #expect(try ImageSource.url(from: "img.example.com/f?src=https://cdn.x/y.jpg").absoluteString == "https://img.example.com/f?src=https://cdn.x/y.jpg")
    }
}
