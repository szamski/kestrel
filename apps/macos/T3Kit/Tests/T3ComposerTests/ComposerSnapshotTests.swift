import AppKit
import SwiftUI
import T3Contracts
import Testing

@testable import T3Composer

private let renderDirectory = ProcessInfo.processInfo.environment["T3_COMPOSER_RENDER_DIR"]

/// Offscreen renders of the composer for visual review. They run only when `T3_COMPOSER_RENDER_DIR`
/// names a directory, and write `<scenario>-<light|dark>.png` there.
@MainActor
@Suite("Composer renders", .serialized) struct ComposerSnapshotTests {
  @Test(.enabled(if: renderDirectory != nil)) func renderScenarios() async throws {
    let directory = URL(fileURLWithPath: try #require(renderDirectory), isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)

    for dark in [false, true] {
      let suffix = dark ? "dark" : "light"
      try await scenario("1-empty", directory, suffix, dark, height: 180) { _ in }
      try await scenario("2-chips-attachments", directory, suffix, dark, height: 330) { fixture in
        let images = try Self.sampleImages(in: fixture.directory)
        for image in images { _ = await fixture.model.addFiles(urls: [image]) }
        let note = fixture.directory.appendingPathComponent("notes.txt")
        try "release notes".write(to: note, atomically: true, encoding: .utf8)
        _ = await fixture.model.addFiles(urls: [note])
        let terminalId = ComposerContextReferences.toKindScopedContextId(kind: "terminal", producerId: "t1")
        let terminal: ComposerContextRecord = decodeJSON(
          #"{"version":1,"kind":"terminal","contextId":"\#(terminalId)","label":"Terminal 1 lines 3-5","terminalId":"t1","terminalLabel":"Terminal 1","lineStart":3,"lineEnd":5,"text":"bun run lint\nerror"}"#)
        _ = fixture.model.insertContext([terminal])
        fixture.type(fixture.model.draft.prompt + " Please **review** [main.ts](src/main.ts) and [lib](src/lib) with $frontend-design then fix `parseDraft`.\n- [ ] add tests\n- [x] update docs")
        fixture.model.reloadEditor(markdown: fixture.model.draft.prompt, cursor: Int.max, undoable: false)
        await fixture.settle(timeout: .seconds(1)) { fixture.services.uploads.values.allSatisfy { if case .ready = $0 { true } else { false } } }
      }
      try await scenario("3-at-menu", directory, suffix, dark, height: 360) { fixture in
        fixture.type("Look at @src")
        fixture.model.reloadEditor(markdown: "Look at @src", cursor: Int.max, undoable: false)
        await fixture.settle { !fixture.model.menuItems.isEmpty }
      }
      try await scenario("4-model-picker", directory, suffix, dark, height: 520, picker: true) { _ in }
      try await scenario("5-approval", directory, suffix, dark, height: 260, thread: pendingApprovalSnapshot(detail: "bun run lint && bun run typecheck")) { _ in }
      try await scenario("6-user-input", directory, suffix, dark, height: 380, thread: pendingQuestionSnapshot(questions: 2)) { fixture in
        fixture.model.selectUserInputOption(questionId: "q1", value: "beta")
        fixture.model.questionAutoAdvance?.cancel()
        await fixture.settle(timeout: .milliseconds(100)) { false }
        fixture.model.previousUserInputQuestion()
      }
      try await scenario("7-queued", directory, suffix, dark, height: 300, thread: ComposerThreadSnapshot(phase: .running)) { fixture in
        fixture.type("Also update the changelog")
        await fixture.model.submit()
        fixture.type("Then run the tests and report [main.ts](src/main.ts) failures")
        await fixture.model.submit()
        fixture.type("Follow-up question")
        fixture.model.reloadEditor(markdown: "Follow-up question", cursor: Int.max, undoable: false)
      }
    }
  }

  private func scenario(
    _ name: String, _ directory: URL, _ suffix: String, _ dark: Bool, height: CGFloat, thread: ComposerThreadSnapshot? = nil, picker: Bool = false,
    prepare: (ModelFixture) async throws -> Void
  ) async throws {
    let fixture = try await ModelFixture.make(thread: thread)
    defer { fixture.cleanup() }
    if let thread {
      await fixture.settle { fixture.model.thread.phase == thread.phase && fixture.model.thread.pending == thread.pending }
    }
    try await prepare(fixture)
    let model = fixture.model
    let content = VStack(spacing: 10) {
      Spacer(minLength: 0)
      if picker { ModelPickerPanel(model: model).frame(maxWidth: .infinity, alignment: .leading) }
      ComposerView(model: model)
    }
    .padding(20)
    .frame(width: 760, height: height)
    .background(Color(nsColor: .windowBackgroundColor))
    try await Self.render(content, size: CGSize(width: 760, height: height), dark: dark, to: directory.appendingPathComponent("\(name)-\(suffix).png"))
  }

  static func render<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) async throws {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let hosting = NSHostingView(rootView: view)
    hosting.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = appearance
    window.contentView = hosting
    window.orderBack(nil)
    for _ in 0..<6 {
      hosting.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(120))
    }
    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw RenderError.noBitmap }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { throw RenderError.noPNG }
    try png.write(to: url)
    window.orderOut(nil)
  }

  enum RenderError: Error { case noBitmap, noPNG }

  static func sampleImages(in directory: URL) throws -> [URL] {
    try [(NSColor.systemTeal, "diagram.png"), (NSColor.systemOrange, "screenshot.png")].map { color, name in
      let image = NSImage(size: NSSize(width: 240, height: 160), flipped: false) { rect in
        NSGradient(starting: color, ending: color.blended(withFraction: 0.5, of: .black) ?? color)?.draw(in: rect, angle: 35)
        return true
      }
      let url = directory.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      guard let tiff = image.tiffRepresentation, let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { throw RenderError.noPNG }
      try data.write(to: url)
      return url
    }
  }
}
