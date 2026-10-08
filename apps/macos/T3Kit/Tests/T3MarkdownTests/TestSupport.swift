import Testing

@testable import T3Markdown

/// `Issue.record` returns a value; `return bail(...)` keeps guard-else bodies on one line.
func bail(_ message: String) { Issue.record(Comment(rawValue: message)) }

/// Inlines of a paragraph block, else nil.
func inlines(_ block: MarkdownBlock?) -> [MarkdownInline]? {
  if case .paragraph(let i, _)? = block { return i }
  return nil
}
