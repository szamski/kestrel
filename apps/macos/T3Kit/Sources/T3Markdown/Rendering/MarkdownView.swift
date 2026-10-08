import AppKit
import SwiftUI

/// One chat message rendered as selectable native text.
///
///     MarkdownView(message.text, options: .init(baseDirectory: cwd)) { link in route(link) }
///
/// Feed it the full text every time it grows: unchanged leading blocks are reused and only the
/// tail is re-parsed and re-laid out. Heights come from `MarkdownLayout`'s cache, so a
/// `LazyVStack` row sizes itself without laying the text out twice.
public struct MarkdownView: View {
  private let text: String
  private let options: MarkdownOptions
  private let theme: MarkdownTheme?
  private let onLink: ((MarkdownLink) -> Void)?
  private let imageLoader: MarkdownImageLoader?
  @State private var layoutVersion = 0
  @Environment(\.colorScheme) private var colorScheme

  public init(
    _ text: String, options: MarkdownOptions = MarkdownOptions(), theme: MarkdownTheme? = nil,
    imageLoader: MarkdownImageLoader? = nil, onLink: ((MarkdownLink) -> Void)? = nil
  ) {
    self.text = text
    self.options = options
    self.theme = theme
    self.imageLoader = imageLoader
    self.onLink = onLink
  }

  public var body: some View {
    MarkdownRepresentable(
      text: text, options: options, theme: theme ?? (colorScheme == .dark ? .dark : .light), onLink: onLink,
      imageLoader: imageLoader, layoutVersion: layoutVersion,
      invalidate: { layoutVersion += 1 })
  }
}

struct MarkdownRepresentable: NSViewRepresentable {
  let text: String
  let options: MarkdownOptions
  let theme: MarkdownTheme
  let onLink: ((MarkdownLink) -> Void)?
  let imageLoader: MarkdownImageLoader?
  let layoutVersion: Int
  let invalidate: () -> Void

  @MainActor
  final class Coordinator {
    var stream: MarkdownStream?
    var lastText: String?
    var lastOptions: MarkdownOptions?
    var lastTheme: MarkdownTheme?
    var rendered: RenderedMarkdown?
    var highlightTask: Task<Void, Never>?
    var highlightingKey: UInt64?

    func render(text: String, options: MarkdownOptions, theme: MarkdownTheme) -> RenderedMarkdown {
      if let rendered, lastText == text, lastOptions == options, lastTheme == theme { return rendered }
      if stream == nil || lastOptions != options { stream = MarkdownStream(options: options) }
      let document = stream!.update(text)
      let result = MarkdownRenderer.shared.render(document, theme: theme)
      lastText = text
      lastOptions = options
      lastTheme = theme
      rendered = result
      return result
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> MarkdownTextView { MarkdownTextView() }

  func updateNSView(_ view: MarkdownTextView, context: Context) {
    let coordinator = context.coordinator
    view.onLink = onLink
    view.imageLoader = imageLoader
    view.onContentSizeInvalidated = invalidate
    let rendered = coordinator.render(text: text, options: options, theme: theme)
    view.setContent(rendered)
    scheduleHighlighting(rendered, view: view, coordinator: coordinator)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownTextView, context: Context) -> CGSize? {
    let width = proposal.width ?? 480
    guard width.isFinite else { return nil }
    let rendered = context.coordinator.render(text: text, options: options, theme: theme)
    return CGSize(width: width, height: MarkdownLayout.height(of: rendered, width: width))
  }

  /// Code blocks render plain first; highlight.js runs off the main thread and the view is
  /// restyled in place when it finishes.
  @MainActor
  private func scheduleHighlighting(_ rendered: RenderedMarkdown, view: MarkdownTextView, coordinator: Coordinator) {
    guard !rendered.pendingHighlights.isEmpty, coordinator.highlightingKey != rendered.contentID else { return }
    coordinator.highlightingKey = rendered.contentID
    coordinator.highlightTask?.cancel()
    let text = text, options = options, theme = theme
    coordinator.highlightTask = Task { @MainActor [weak view, weak coordinator] in
      await MarkdownRenderer.shared.resolveHighlights(of: rendered)
      guard !Task.isCancelled, let view, let coordinator else { return }
      coordinator.highlightingKey = nil
      // Only restyle if the text is still the one that was highlighted.
      guard coordinator.lastText == text, coordinator.lastOptions == options else { return }
      coordinator.lastText = nil  // force a re-render now that highlights are cached
      let updated = coordinator.render(text: text, options: options, theme: theme)
      view.setContent(updated)
    }
  }
}
