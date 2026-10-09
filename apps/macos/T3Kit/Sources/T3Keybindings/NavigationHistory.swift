/// Back/forward over the places the user has been (`navigation.back` / `navigation.forward`).
/// Recording the entry already shown is a no-op, so navigating through the history can record
/// the selection it causes without growing the stack.
public struct NavigationHistory<Entry: Equatable & Sendable>: Sendable {
  public private(set) var entries: [Entry] = []
  private var index = -1
  private let limit: Int

  public init(limit: Int = 50) { self.limit = limit }

  public var current: Entry? { entries.indices.contains(index) ? entries[index] : nil }
  public var canGoBack: Bool { index > 0 }
  public var canGoForward: Bool { index >= 0 && index < entries.count - 1 }

  public mutating func record(_ entry: Entry) {
    guard entry != current else { return }
    entries.removeSubrange((index + 1)...)
    entries.append(entry)
    if entries.count > limit { entries.removeFirst(entries.count - limit) }
    index = entries.count - 1
  }

  /// Steps back to the nearest entry `isValid` accepts (a deleted thread is skipped); nil when there is none.
  public mutating func back(where isValid: (Entry) -> Bool = { _ in true }) -> Entry? { step(-1, isValid) }
  public mutating func forward(where isValid: (Entry) -> Bool = { _ in true }) -> Entry? { step(1, isValid) }

  private mutating func step(_ delta: Int, _ isValid: (Entry) -> Bool) -> Entry? {
    var next = index + delta
    while entries.indices.contains(next) {
      if isValid(entries[next]) {
        index = next
        return entries[next]
      }
      next += delta
    }
    return nil
  }
}
