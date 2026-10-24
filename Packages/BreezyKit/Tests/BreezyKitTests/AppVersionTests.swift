import Testing
@testable import BreezyKit

@Suite struct AppVersionTests {
    @Test func versionAndBuild() {
        let info = ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "42"]
        #expect(AppVersion.description(info: info) == "Breezy 1.0.0 (build 42)")
    }

    @Test func missingValues() {
        #expect(AppVersion.description(info: nil) == "Breezy")
        #expect(AppVersion.description(info: ["CFBundleVersion": "7"]) == "Breezy (build 7)")
    }
}
