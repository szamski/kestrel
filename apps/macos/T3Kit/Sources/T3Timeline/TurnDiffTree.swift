import Foundation
import T3Contracts

// Port of apps/web/src/lib/turnDiffTree.ts: the changed-files card under an assistant message,
// as data. Totals come from a checkpoint's files; the tree groups them by directory.

public struct TurnDiffStat: Sendable, Hashable {
  public var additions: Int
  public var deletions: Int
}

public indirect enum TurnDiffTreeNode: Sendable, Hashable {
  case directory(name: String, path: String, stat: TurnDiffStat, children: [TurnDiffTreeNode])
  case file(name: String, path: String, stat: TurnDiffStat?)

  public var name: String {
    switch self {
    case .directory(let name, _, _, _), .file(let name, _, _): name
    }
  }
}

public func summarizeTurnDiffStats(_ files: [V1.OrchestrationCheckpointFile]) -> TurnDiffStat {
  TurnDiffStat(additions: files.reduce(0) { $0 + $1.additions }, deletions: files.reduce(0) { $0 + $1.deletions })
}

/// `localeCompare(b, undefined, { numeric: true, sensitivity: "base" })`: runs of digits compare
/// by value, everything else case-insensitively in ICU root order.
func compareNumericBase(_ left: String, _ right: String) -> Int {
  func tokens(_ value: String) -> [(isNumber: Bool, text: String)] {
    var out: [(Bool, String)] = []
    for character in value {
      let isDigit = character.isASCII && character.isNumber
      if let last = out.last, last.0 == isDigit { out[out.count - 1].1.append(character) } else { out.append((isDigit, String(character))) }
    }
    return out
  }
  let l = tokens(left)
  let r = tokens(right)
  for (a, b) in zip(l, r) {
    if a.isNumber && b.isNumber {
      let x = a.text.drop { $0 == "0" }
      let y = b.text.drop { $0 == "0" }
      if x.count != y.count { return x.count < y.count ? -1 : 1 }
      if x != y { return x < y ? -1 : 1 }
    } else if a.isNumber != b.isNumber {
      // Digits sort before letters and after punctuation.
      return jsLocaleCompare(String(a.text.prefix(1)), String(b.text.prefix(1)))
    } else {
      let c = jsLocaleCompare(a.text.lowercased(), b.text.lowercased())
      if c != 0 { return c }
    }
  }
  return l.count == r.count ? 0 : l.count < r.count ? -1 : 1
}

private final class DirectoryBuilder {
  let name: String
  let path: String
  var stat = TurnDiffStat(additions: 0, deletions: 0)
  var directories: [(name: String, node: DirectoryBuilder)] = []
  var files: [TurnDiffTreeNode] = []

  init(name: String, path: String) {
    self.name = name
    self.path = path
  }

  func child(named segment: String) -> DirectoryBuilder {
    if let existing = directories.first(where: { $0.name == segment }) { return existing.node }
    let created = DirectoryBuilder(name: segment, path: path.isEmpty ? segment : "\(path)/\(segment)")
    directories.append((segment, created))
    return created
  }
}

private func compactDirectory(_ node: TurnDiffTreeNode) -> TurnDiffTreeNode {
  guard case .directory(var name, var path, var stat, let children) = node else { return node }
  var current = children.map(compactDirectory)
  while current.count == 1, case .directory(let childName, let childPath, let childStat, let grandChildren) = current[0] {
    name = "\(name)/\(childName)"
    path = childPath
    stat = childStat
    current = grandChildren
  }
  return .directory(name: name, path: path, stat: stat, children: current)
}

private func treeNodes(_ directory: DirectoryBuilder) -> [TurnDiffTreeNode] {
  let subdirectories = directory.directories.map(\.node)
    .stableSorted { compareNumericBase($0.name, $1.name) }
    .map { sub in
      compactDirectory(.directory(name: sub.name, path: sub.path, stat: sub.stat, children: treeNodes(sub)))
    }
  let files = directory.files.stableSorted { compareNumericBase($0.name, $1.name) }
  return subdirectories + files
}

public func buildTurnDiffTree(_ files: [V1.OrchestrationCheckpointFile]) -> [TurnDiffTreeNode] {
  let root = DirectoryBuilder(name: "", path: "")
  for file in files {
    let segments = file.path.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard let fileName = segments.last else { continue }
    let stat = TurnDiffStat(additions: file.additions, deletions: file.deletions)
    var ancestors = [root]
    var current = root
    for segment in segments.dropLast() {
      current = current.child(named: segment)
      ancestors.append(current)
    }
    current.files.append(.file(name: fileName, path: segments.joined(separator: "/"), stat: stat))
    for ancestor in ancestors {
      ancestor.stat.additions += stat.additions
      ancestor.stat.deletions += stat.deletions
    }
  }
  return treeNodes(root)
}

extension TurnDiffStat {
  var projection: JSONValue { .object(["additions": .int(additions), "deletions": .int(deletions)]) }
}

extension TurnDiffTreeNode {
  public var projection: JSONValue {
    switch self {
    case .directory(let name, let path, let stat, let children):
      .object(["kind": .string("directory"), "name": .string(name), "path": .string(path), "stat": stat.projection, "children": .array(children.map(\.projection))])
    case .file(let name, let path, let stat):
      .object(["kind": .string("file"), "name": .string(name), "path": .string(path), "stat": stat?.projection ?? .null])
    }
  }
}
