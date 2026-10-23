// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BreezyKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "BreezyKit", targets: ["BreezyKit"])],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0")],
    targets: [
        .target(name: "BreezyKit", dependencies: ["Yams"]),
        .testTarget(name: "BreezyKitTests", dependencies: ["BreezyKit"]),
    ]
)
