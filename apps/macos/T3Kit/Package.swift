// swift-tools-version: 6.2
import PackageDescription

// Shared Swift modules for the native macOS client. The app target lives in
// apps/macos/T3Code.xcodeproj and links these libraries.
let package = Package(
  name: "T3Kit",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "T3Contracts", targets: ["T3Contracts"]),
    .library(name: "T3Protocol", targets: ["T3Protocol"]),
    .library(name: "T3ClientRuntime", targets: ["T3ClientRuntime"]),
    .library(name: "T3Markdown", targets: ["T3Markdown"]),
    .library(name: "T3Composer", targets: ["T3Composer"]),
    .library(name: "T3Timeline", targets: ["T3Timeline"]),
  ],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
  ],
  targets: [
    // Generated from packages/contracts. Do not edit Generated/*.swift by hand.
    .target(name: "T3Contracts"),
    // Effect RPC over WebSocket, environment HTTP, auth and credential storage.
    .target(name: "T3Protocol", dependencies: ["T3Contracts"]),
    // Connection supervisor, sync engine, reducers and derived state.
    .target(name: "T3ClientRuntime", dependencies: ["T3Contracts", "T3Protocol"]),
    .target(
      name: "T3Markdown",
      dependencies: [.product(name: "Markdown", package: "swift-markdown")]
    ),
    .target(name: "T3Composer", dependencies: ["T3Contracts", "T3Timeline", "T3Markdown"]),
    // Pure timeline derivation: messages, work log, tool presentation, plans.
    .target(name: "T3Timeline", dependencies: ["T3Contracts"]),
    .testTarget(name: "T3ContractsTests", dependencies: ["T3Contracts"], resources: [.copy("Fixtures")]),
    .testTarget(name: "T3ProtocolTests", dependencies: ["T3Protocol"]),
    .testTarget(name: "T3ClientRuntimeTests", dependencies: ["T3ClientRuntime"], resources: [.copy("Fixtures")]),
    .testTarget(name: "T3MarkdownTests", dependencies: ["T3Markdown"]),
    .testTarget(name: "T3ComposerTests", dependencies: ["T3Composer", "T3Timeline", "T3Markdown"]),
    .testTarget(name: "T3TimelineTests", dependencies: ["T3Timeline"], resources: [.copy("Fixtures")]),
  ],
  swiftLanguageModes: [.v6]
)
