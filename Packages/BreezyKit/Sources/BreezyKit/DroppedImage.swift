import Foundation
import UniformTypeIdentifiers

/// A picture dragged onto Breezy, from any app on the Mac, iPad or iPhone: its bytes (a picture file, Photos, a
/// picture dragged out of a web page) or, for a link dragged from a browser, the web address to copy it from.
public enum DroppedImage: Equatable, Sendable {
    case data(Data)
    case address(String)

    /// What a drop target accepts. A file URL is a URL; a picture file also offers its own image type. Any web link
    /// is taken: an address of a picture often has no extension, so only the download tells.
    public static let types: [UTType] = [.image, .url]

    /// The largest picture file read from a drop or the clipboard. Larger than a download's limit
    /// (`ImageSource.maxBytes`): a camera's raw file can be tens of megabytes.
    public static let maxFileBytes = 100_000_000

    public enum LoadError: Error, Equatable, LocalizedError {
        /// The drop holds a picture that could not be read (a photo still in iCloud, a file no longer there).
        case unreadable
        case tooLarge

        public var errorDescription: String? {
            switch self {
            case .unreadable: "The picture could not be read. If it is stored in iCloud, open it once so it downloads, then try again."
            case .tooLarge: "That picture is too large (over \(DroppedImage.maxFileBytes / 1_000_000) MB)."
            }
        }
    }

    /// Starts reading a drop (or a paste) at once, while the drop is still being performed: the system may stop
    /// handing over its items once it is over. `Pending.value()` then gives the picture. Of several pictures only the
    /// first is read (a node has one banner); every address is asked for, which costs little.
    /// An item that is a file (Finder) is read only as the file: the picture bytes it also offers can be its icon.
    public static func start(_ providers: [NSItemProvider]) -> Pending {
        Pending(
            image: providers.first {
                $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) && !$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            }.map(loadImage),
            urls: providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }.map(loadURL))
    }

    /// A drop being read.
    public struct Pending: Sendable {
        let image: AsyncStream<Loaded>?
        let urls: [AsyncStream<URL?>]

        /// The picture in the drop, or nil when it holds none: the first picture file that can be read (anything else,
        /// a movie or an archive, is not read just to be refused), then picture bytes (a picture dragged from a web
        /// page also carries its address, and the bytes need no connection), then a web address. Throws when there was
        /// a picture but none could be read, or it was too large.
        public func value() async throws -> DroppedImage? {
            var found: [URL] = []
            for stream in urls { if case let url?? = await first(stream) { found.append(url) } }
            var failure: LoadError?
            for file in found where file.isFileURL {
                switch await readInBackground(file) {
                case let .data(data)?: return .data(data)
                case let .failed(error)?: failure = failure ?? error
                case .notAPicture?: continue
                case nil: return nil // cancelled
                }
            }
            if let image {
                switch await first(image) {
                case let .data(data): return .data(data)
                case let .failed(error): failure = failure ?? error
                case .notAPicture, nil: failure = failure ?? .unreadable
                }
            }
            if let web = found.first(where: { !$0.isFileURL }) { return .address(web.absoluteString) }
            if let failure { throw failure }
            return nil
        }

        /// Off the main actor. Cancelling stops the wait (nil), not the read, which is bounded by `maxFileBytes`.
        private func readInBackground(_ file: URL) async -> Loaded? {
            let (stream, continuation) = AsyncStream<Loaded>.makeStream()
            Task.detached(priority: .userInitiated) {
                continuation.yield(read(file, onlyPicture: true))
                continuation.finish()
            }
            return await first(stream)
        }

        /// The stream's value, or nil once the task is cancelled (an AsyncStream stops waiting then).
        private func first<T: Sendable>(_ stream: AsyncStream<T>) async -> T? {
            for await value in stream { return value }
            return nil
        }
    }

    enum Loaded: Sendable {
        case data(Data)
        case failed(LoadError)
        case notAPicture
    }

    /// As a file: a picture handed over as data is written to one, and a promised file (Photos on the Mac) arrives
    /// as one. Read in the callback, off the main thread, while the file is still there.
    private static func loadImage(_ provider: NSItemProvider) -> AsyncStream<Loaded> {
        let (stream, continuation) = AsyncStream<Loaded>.makeStream()
        let progress = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
            continuation.yield(url.map { read($0, onlyPicture: false) } ?? .failed(.unreadable))
            continuation.finish()
        }
        // Cancelled, or no longer wanted: stop an iCloud download or a copy still going.
        continuation.onTermination = { _ in progress.cancel() }
        return stream
    }

    private static func loadURL(_ provider: NSItemProvider) -> AsyncStream<URL?> {
        let (stream, continuation) = AsyncStream<URL?>.makeStream()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            continuation.yield(url)
            continuation.finish()
        }
        return stream
    }

    /// A file's bytes, if it is not too large: never more than the limit is read, even when the size is not known in
    /// advance. With `onlyPicture`, only a picture file, by what the file system says it is or else by its name's
    /// extension. Files from another app (Files on iOS) are reachable only while access is claimed.
    static func read(_ url: URL, onlyPicture: Bool) -> Loaded {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        if onlyPicture, (values?.contentType ?? UTType(filenameExtension: url.pathExtension))?.conforms(to: .image) != true {
            return .notAPicture
        }
        if let size = values?.fileSize, size > maxFileBytes { return .failed(.tooLarge) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .failed(.unreadable) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxFileBytes + 1) else { return .failed(.unreadable) }
        return data.count > maxFileBytes ? .failed(.tooLarge) : .data(data)
    }
}
