import AppKit
import Foundation
import Testing

@testable import T3Markdown

private let artifacts = "/private/tmp/claude-artifacts/99447fb1-85c0-47e1-86f6-4fcf55a2dd78/stageD-markdown"

@MainActor
@Suite("Rendering")
struct RenderingTests {
  @Test func writesDemoScreenshots() async throws {
    _ = NSApplication.shared
    let light = try #require(await MarkdownDemo.png(width: 680, theme: .light))
    try light.write(to: URL(fileURLWithPath: "\(artifacts)/markdown-light.png"))
    let dark = try #require(await MarkdownDemo.png(width: 680, theme: .dark))
    try dark.write(to: URL(fileURLWithPath: "\(artifacts)/markdown-dark.png"))
    #expect(light.count > 10_000)
  }
}
