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
  ],
  targets: [
    // Generated from packages/contracts. Do not edit Generated/*.swift by hand.
    .target(name: "T3Contracts"),
    // Effect RPC over WebSocket, environment HTTP, auth and credential storage.
    .target(name: "T3Protocol", dependencies: ["T3Contracts"]),
    .testTarget(name: "T3ContractsTests", dependencies: ["T3Contracts"], resources: [.copy("Fixtures")]),
    .testTarget(name: "T3ProtocolTests", dependencies: ["T3Protocol"]),
  ],
  swiftLanguageModes: [.v6]
)
