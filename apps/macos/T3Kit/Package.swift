// swift-tools-version: 6.2
import PackageDescription

// Shared Swift modules for the native macOS client. The app target lives in
// apps/macos/T3Code.xcodeproj and links these libraries.
let package = Package(
  name: "T3Kit",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "T3Contracts", targets: ["T3Contracts"]),
  ],
  targets: [
    // Generated from packages/contracts. Do not edit Generated/*.swift by hand.
    .target(name: "T3Contracts"),
    .testTarget(name: "T3ContractsTests", dependencies: ["T3Contracts"], resources: [.copy("Fixtures")]),
  ],
  swiftLanguageModes: [.v6]
)
