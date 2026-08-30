// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KanataCore",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "KanataCore", targets: ["KanataCore"])
    ],
    targets: [
        .target(
            name: "KanataCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
