import Foundation

/// The "Breezy 1.0.0 (build 12)" line shown in Settings.
public enum AppVersion {
    public static func description(info: [String: Any]?) -> String {
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        var text = "Breezy"
        if let version, !version.isEmpty { text += " \(version)" }
        if let build, !build.isEmpty { text += " (build \(build))" }
        return text
    }

    public static var current: String { description(info: Bundle.main.infoDictionary) }
}
