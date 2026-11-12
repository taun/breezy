import Foundation
import Testing
import UniformTypeIdentifiers
@testable import BreezyKit

@MainActor @Suite struct DroppedImageTests {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!

    private func imageProvider() -> NSItemProvider { NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier) }

    private func tempFile(_ name: String, _ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test func pictureBytesAreTaken() async throws {
        #expect(try await DroppedImage.start([imageProvider()]).value() == .data(png))
    }

    /// A picture dragged out of a web page carries its address too: the bytes win, so no connection is needed.
    @Test func pictureBytesComeBeforeAnAddress() async throws {
        let link = NSItemProvider(object: URL(string: "https://example.com/a.png")! as NSURL)
        #expect(try await DroppedImage.start([link, imageProvider()]).value() == .data(png))
    }

    @Test func aWebAddressIsCopiedFrom() async throws {
        let link = NSItemProvider(object: URL(string: "https://example.com/a.png")! as NSURL)
        #expect(try await DroppedImage.start([link]).value() == .address("https://example.com/a.png"))
    }

    @Test func aPictureFileIsRead() async throws {
        let url = try tempFile("cover.png", png)
        #expect(try await DroppedImage.start([try #require(NSItemProvider(contentsOf: url))]).value() == .data(png))
    }

    /// A file dragged only as its address is read when its name says it is a picture.
    @Test func aPictureFileAddressIsRead() async throws {
        let url = try tempFile("cover.png", png)
        #expect(try await DroppedImage.start([NSItemProvider(object: url as NSURL)]).value() == .data(png))
    }

    /// Finder offers a file's icon as picture bytes beside the file: the file is the picture.
    @Test func aPictureFileComesBeforePictureBytes() async throws {
        let other = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEklEQVR4nGP4z8DwHwyBNBgAAEDzB/kYOTaVAAAAAElFTkSuQmCC")!
        let url = try tempFile("photo.png", other)
        #expect(try await DroppedImage.start([imageProvider(), NSItemProvider(object: url as NSURL)]).value() == .data(other))
    }

    /// A file dragged from Finder: its address beside picture bytes that may be only its icon.
    private func finderProvider(_ url: URL, icon: Data) -> NSItemProvider {
        let provider = NSItemProvider(object: url as NSURL)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(icon, nil)
            return nil
        }
        return provider
    }

    @Test func aFinderPictureIsTheFileNotItsIcon() async throws {
        let url = try tempFile("photo.png", png)
        #expect(try await DroppedImage.start([finderProvider(url, icon: Data("icon".utf8))]).value() == .data(png))
    }

    /// A Finder file that is no picture is not one because its icon is.
    @Test func aFinderFileThatIsNoPictureIsNotItsIcon() async throws {
        let url = try tempFile("report.txt", Data("hello".utf8))
        #expect(try await DroppedImage.start([finderProvider(url, icon: png)]).value() == nil)
    }

    @Test func aHugeFinderPictureIsRefusedNotReplacedByItsIcon() async throws {
        let url = try tempFile("huge.png", Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(DroppedImage.maxFileBytes + 1))
        try handle.close()
        await #expect(throws: DroppedImage.LoadError.tooLarge) { try await DroppedImage.start([finderProvider(url, icon: png)]).value() }
    }

    /// A Finder picture that cannot be read says so; its icon does not stand in.
    @Test func anUnreadableFinderPictureIsNotReplacedByItsIcon() async throws {
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        await #expect(throws: DroppedImage.LoadError.unreadable) { try await DroppedImage.start([finderProvider(gone, icon: png)]).value() }
    }

    /// Of several files, the first picture that can be read: one too large does not block it.
    @Test func theFirstReadablePictureFileOfSeveral() async throws {
        let huge = try tempFile("huge.png", Data())
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(DroppedImage.maxFileBytes + 1))
        try handle.close()
        let small = try tempFile("small.png", png)
        #expect(try await DroppedImage.start([NSItemProvider(object: huge as NSURL), NSItemProvider(object: small as NSURL)]).value() == .data(png))
    }

    /// Any other file is not read at all (a movie could be gigabytes).
    @Test func otherFilesAreNotRead() async throws {
        let url = try tempFile("notes.txt", Data("hello".utf8))
        #expect(try await DroppedImage.start([NSItemProvider(object: url as NSURL)]).value() == nil)
    }

    /// A picture that cannot be read is reported as such, not as "no picture".
    @Test func anUnreadablePictureFileSaysSo() async throws {
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        await #expect(throws: DroppedImage.LoadError.unreadable) { try await DroppedImage.start([NSItemProvider(object: gone as NSURL)]).value() }
    }

    /// A picture that cannot be read still leaves a dragged web address to copy from.
    @Test func anAddressStandsInForAnUnreadablePicture() async throws {
        let broken = NSItemProvider()
        broken.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(nil, CocoaError(.fileReadUnknown))
            return nil
        }
        let link = NSItemProvider(object: URL(string: "https://example.com/a.png")! as NSURL)
        #expect(try await DroppedImage.start([broken, link]).value() == .address("https://example.com/a.png"))
    }

    /// A huge picture file is refused before it is read (sparse here, so the test writes nothing).
    @Test func aHugePictureFileIsRefused() async throws {
        let url = try tempFile("huge.png", Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(DroppedImage.maxFileBytes + 1))
        try handle.close()
        await #expect(throws: DroppedImage.LoadError.tooLarge) { try await DroppedImage.start([NSItemProvider(object: url as NSURL)]).value() }
    }

    @Test func textIsNoPicture() async throws {
        #expect(try await DroppedImage.start([NSItemProvider(object: "hello" as NSString)]).value() == nil)
        #expect(try await DroppedImage.start([]).value() == nil)
    }
}
