// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BreezyKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "BreezyKit", targets: ["BreezyKit"]),
        // Test helpers (a fake GitHub) shared by BreezyKit's tests and the app's tests. Not used by the app itself.
        .library(name: "BreezyKitTestSupport", targets: ["BreezyKitTestSupport"]),
    ],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0")],
    targets: [
        .target(name: "BreezyKit", dependencies: ["Yams"]),
        .target(name: "BreezyKitTestSupport", dependencies: ["BreezyKit"]),
        .testTarget(name: "BreezyKitTests", dependencies: ["BreezyKit", "BreezyKitTestSupport"]),
    ]
)
