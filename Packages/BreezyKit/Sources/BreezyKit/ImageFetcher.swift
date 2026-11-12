import Foundation

/// Downloads a picture from the web. A seam like `HTTPTransport`: tests use a fake.
public protocol ImageFetching: Sendable {
    func fetch(_ url: URL) async throws -> Data
}

public enum ImageFetchError: Error, Equatable, LocalizedError {
    case invalidURL
    case insecure
    case http(Int)
    case tooLarge
    case offline

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "That is not a web address."
        case .insecure: "Only https addresses can be used. Try the address with https://."
        case let .http(status): "The website answered with an error (\(status))."
        case .tooLarge: "That image is too large (over \(ImageSource.maxBytes / 1_000_000) MB)."
        case .offline: "Fetching an image needs a connection. Try again when you are online."
        }
    }
}

public enum ImageSource {
    /// The most bytes taken from a web address.
    public static let maxBytes = 25_000_000

    /// A dragged link, which cannot be edited before it is fetched: an http one is tried as https.
    public static func secured(_ link: String) -> String {
        link.replacingOccurrences(of: "^http://", with: "https://", options: [.regularExpression, .caseInsensitive])
    }

    /// The address typed or pasted, with https:// added when there is no scheme. Only https is accepted.
    public static func url(from text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { throw ImageFetchError.invalidURL }
        let hasScheme = trimmed.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil
        let full = hasScheme ? trimmed : "https://" + trimmed
        guard let url = URL(string: full), let scheme = url.scheme?.lowercased() else { throw ImageFetchError.invalidURL }
        guard scheme == "https" else { throw ImageFetchError.insecure }
        guard url.host?.isEmpty == false else { throw ImageFetchError.invalidURL }
        return url
    }
}

/// The real fetcher: https only, a size limit, and the connection errors reported as `offline`.
public struct URLSessionImageFetcher: ImageFetching {
    public init() {}

    public func fetch(_ url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw ImageFetchError.insecure }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw ImageFetchError.http(http.statusCode) }
            if response.expectedContentLength > Int64(ImageSource.maxBytes) { throw ImageFetchError.tooLarge }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > ImageSource.maxBytes { throw ImageFetchError.tooLarge }
            }
            return data
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(error.code) {
            throw ImageFetchError.offline
        }
    }
}
