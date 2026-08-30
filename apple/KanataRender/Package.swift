// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KanataRender",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17)
    ],
    products: [
        .library(name: "KanataRender", targets: ["KanataRender"])
    ],
    dependencies: [
        .package(path: "../KanataCore")
    ],
    targets: [
        .target(
            name: "KanataRender",
            dependencies: [.product(name: "KanataCore", package: "KanataCore")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
