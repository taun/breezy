import CryptoKit
import Foundation

/// Git's blob object ID for a file's contents, computed locally: SHA-1 of "blob <byte count>\0" + bytes.
/// It equals the `sha` GitHub reports for the same file, so local and remote versions compare without the network.
public enum GitBlob {
    public static func sha(of text: String) -> String {
        let data = Data(text.utf8)
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\0".utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
