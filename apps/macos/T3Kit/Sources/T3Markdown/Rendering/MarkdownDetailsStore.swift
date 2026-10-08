import Foundation

/// Which `<details>` sections the reader has toggled. Sections start collapsed (or open when
/// authored `<details open>`), so only the reader's explicit choices are stored, keyed by
/// (chunk content, ordinal in chunk). Rows are recycled by the timeline; this is what keeps a
/// section open when its row scrolls away and back. Part of the rendered-segment and
/// layout-cache keys, so every toggle state caches its own text and height.
final class MarkdownDetailsStore: @unchecked Sendable {
  static let shared = MarkdownDetailsStore()
  private let lock = NSLock()
  private var states: [UInt64: Bool] = [:]
  private var _version = 0

  /// Bumps on every change; hosts that cache a render compare it.
  var version: Int {
    lock.lock()
    defer { lock.unlock() }
    return _version
  }

  static func key(chunk: UInt64, ordinal: Int) -> UInt64 { FNV.combine(chunk, UInt64(ordinal)) }

  func state(for key: UInt64) -> Bool? {
    lock.lock()
    defer { lock.unlock() }
    return states[key]
  }

  func set(_ key: UInt64, open: Bool) {
    lock.lock()
    defer { lock.unlock() }
    states[key] = open
    _version += 1
  }

  /// Hash of the stored states of a chunk's sections: 0 when none was toggled.
  func stateHash(chunk: UInt64, count: Int) -> UInt64 {
    guard count > 0 else { return 0 }
    lock.lock()
    defer { lock.unlock() }
    var h = FNV.offset
    var toggled = false
    for ordinal in 0..<count {
      guard let open = states[Self.key(chunk: chunk, ordinal: ordinal)] else { continue }
      h = FNV.combine(FNV.combine(h, UInt64(ordinal) + 1), open ? 1 : 2)
      toggled = true
    }
    return toggled ? h | 1 : 0
  }
}
