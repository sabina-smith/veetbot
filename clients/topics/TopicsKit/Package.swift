// swift-tools-version: 6.0

import PackageDescription

// The Topics app's model layer: topics, the shared schedule and its
// redaction rules, the per-topic workspace (files, git, SQLite), and the
// parser and applier for the changes a topic agent proposes. No UI and no
// Veetbot dependency, so `swift test` runs it without signing.
let package = Package(
    name: "TopicsKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "TopicsKit", targets: ["TopicsKit"])
    ],
    targets: [
        .target(name: "TopicsKit"),
        .testTarget(name: "TopicsKitTests", dependencies: ["TopicsKit"]),
    ],
    swiftLanguageModes: [.v5]
)
