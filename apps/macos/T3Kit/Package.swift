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
    .library(name: "T3Terminal", targets: ["T3Terminal"]),
    .library(name: "T3Diff", targets: ["T3Diff"]),
    .library(name: "T3Keybindings", targets: ["T3Keybindings"]),
    .library(name: "T3Theme", targets: ["T3Theme"]),
    .library(name: "T3Connect", targets: ["T3Connect"]),
  ],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.9.0"),
    // Cloud identity for T3 Connect. ClerkKit only (no ClerkKitUI): it has no dependencies of its own.
    .package(url: "https://github.com/clerk/clerk-ios.git", exact: "1.6.1"),
  ],
  targets: [
    // Generated from packages/contracts (Generated/) and the frozen protocol-1 schemas in
    // apps/macos/scripts/frozen-v1 (GeneratedV1/, namespace `V1`). Do not edit either by hand.
    .target(name: "T3Contracts"),
    // Effect RPC over WebSocket, environment HTTP, auth and credential storage.
    .target(name: "T3Protocol", dependencies: ["T3Contracts"]),
    // Connection supervisor, sync engine, reducers and derived state.
    .target(name: "T3ClientRuntime", dependencies: ["T3Contracts", "T3Protocol"]),
    .target(
      name: "T3Markdown",
      dependencies: [.product(name: "Markdown", package: "swift-markdown")]
    ),
    // Unified-diff parser, word diff, review-comment mapping and the virtualized diff table.
    .target(name: "T3Diff", dependencies: ["T3Contracts", "T3Markdown"]),
    // Keybinding matching, `when` evaluation and shortcut labels over the server-resolved rules.
    .target(name: "T3Keybindings", dependencies: ["T3Contracts"]),
    // Pure theming: theme file v1 codec, palette derivation, VS Code / Open VSX import. No UI, no contracts.
    .target(name: "T3Theme"),
    // T3 Connect: DPoP signer, relay client, managed environment authorization, local link, Clerk session.
    .target(
      name: "T3Connect",
      dependencies: ["T3Contracts", "T3Protocol", "T3ClientRuntime", .product(name: "ClerkKit", package: "clerk-ios")]
    ),
    .target(name: "T3Composer", dependencies: ["T3Contracts", "T3Timeline", "T3Markdown"]),
    // Pure timeline derivation: messages, work log, tool presentation, plans.
    .target(name: "T3Timeline", dependencies: ["T3Contracts"]),
    // Native terminal: Ghostty surface view, session model over the terminal RPCs, drawer.
    .target(
      name: "T3Terminal",
      dependencies: ["T3Contracts", "T3Protocol", "GhosttyKit"],
      // What libghostty's static archive needs beyond Swift's own imports (shader tooling is C++).
      linkerSettings: [
        .linkedLibrary("c++"),
        .linkedFramework("Carbon"), .linkedFramework("Metal"), .linkedFramework("MetalKit"),
        .linkedFramework("CoreText"), .linkedFramework("CoreGraphics"), .linkedFramework("CoreVideo"),
        .linkedFramework("IOSurface"), .linkedFramework("QuartzCore"), .linkedFramework("AppKit"),
      ]),
    .binaryTarget(name: "GhosttyKit", path: "../Vendor/GhosttyKit/GhosttyKit.xcframework"),
    .testTarget(name: "T3ContractsTests", dependencies: ["T3Contracts"], resources: [.copy("Fixtures")]),
    .testTarget(name: "T3ProtocolTests", dependencies: ["T3Protocol"]),
    .testTarget(name: "T3ClientRuntimeTests", dependencies: ["T3ClientRuntime"], resources: [.copy("Fixtures")]),
    .testTarget(name: "T3ConnectTests", dependencies: ["T3Connect", "T3ClientRuntime", "T3Protocol", "T3Contracts"]),
    .testTarget(name: "T3MarkdownTests", dependencies: ["T3Markdown"]),
    .testTarget(name: "T3ComposerTests", dependencies: ["T3Composer", "T3Timeline", "T3Markdown", "T3Keybindings"]),
    .testTarget(name: "T3DiffTests", dependencies: ["T3Diff"]),
    .testTarget(name: "T3KeybindingsTests", dependencies: ["T3Keybindings"]),
    .testTarget(name: "T3ThemeTests", dependencies: ["T3Theme"], resources: [.copy("Fixtures")]),
    .testTarget(name: "T3TerminalTests", dependencies: ["T3Terminal"]),
    .testTarget(name: "T3TimelineTests", dependencies: ["T3Timeline"], resources: [.copy("Fixtures")]),
  ],
  swiftLanguageModes: [.v6]
)
