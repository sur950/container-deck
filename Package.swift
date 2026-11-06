// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ContainerDeck",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ContainerDeck", targets: ["ContainerDeck"]),
        .library(name: "DeckCore", targets: ["DeckCore"])
    ],
    dependencies: [
        // YAML parsing for compose files.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0")
    ],
    targets: [
        // Talks to Apple's container platform and other engines. No UI code here.
        .target(name: "DeckCore", dependencies: ["Yams"], exclude: ["API/README.md"]),
        // The SwiftUI app.
        .executableTarget(name: "ContainerDeck", dependencies: ["DeckCore"]),
        // `container compose` CLI plugin. Installed as <plugins>/compose/bin/compose.
        .executableTarget(name: "container-compose", dependencies: ["DeckCore"], path: "Sources/ContainerCompose"),
        .testTarget(name: "DeckCoreTests", dependencies: ["DeckCore"]),
        // App level tests (design system). Uses @testable import of the executable target.
        .testTarget(name: "ContainerDeckTests", dependencies: ["ContainerDeck"])
    ],
    // Swift 5 language mode for now. We move to Swift 6 strict concurrency later.
    swiftLanguageModes: [.v5]
)
