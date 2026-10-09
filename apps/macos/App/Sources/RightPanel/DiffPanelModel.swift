import Foundation
import Observation
import T3Contracts
import T3Diff
import T3Timeline

/// What to ask the server for.
struct DiffRequest: Equatable, Sendable {
  enum Source: Equatable, Sendable {
    case workingTree
    case branch
    /// One checkpoint turn: `getTurnDiff(count - 1, count)`.
    case turn(count: Int)
    /// Everything up to this checkpoint: `getFullThreadDiff`.
    case allTurns(upTo: Int)
  }

  var source: Source
  var ignoreWhitespace: Bool
}

struct DiffFetchResult: Sendable {
  var patch: String
  /// The server cut the patch (git preview sources only).
  var truncated: Bool
}

typealias DiffFetcher = @Sendable (DiffRequest) async throws -> DiffFetchResult

struct DiffTreeRow: Identifiable {
  var id: String
  var depth: Int
  var name: String
  var path: String
  var isDirectory: Bool
  var additions: Int
  var deletions: Int
}

/// State behind the diff tab: the fetched patch, its parsed files and rows, collapse and selection state, and
/// the view preferences. The patch is parsed off the main actor; rows are rebuilt (cheap) when layout or
/// collapse state changes.
@MainActor
@Observable
final class DiffPanelModel {
  enum Phase: Equatable { case loading, ready, failed(String) }

  private(set) var phase: Phase = .loading
  private(set) var files: [DiffFile] = []
  private(set) var rows: [DiffRow] = []
  private(set) var revision = 0
  private(set) var truncated = false
  private(set) var tree: [DiffTreeRow] = []
  private(set) var reveal: DiffReveal?
  private(set) var sectionId = ""
  private(set) var sectionTitle = ""
  var selection: DiffSelection?
  var commentText = ""

  // Layout, wrap, whitespace and the default file state are client settings (Settings › General); the toolbar toggles write
  // them back, and a change made in Settings reaches an open panel through `follow`.
  var layout: DiffLayoutMode { didSet { settings.update { $0.diffLayout = .init(rawValue: layout.rawValue) }; rebuild() } }
  var wordWrap: Bool { didSet { settings.update { $0.wordWrap = wordWrap }; rebuild() } }
  var ignoreWhitespace: Bool { didSet { settings.update { $0.diffIgnoreWhitespace = ignoreWhitespace } } }
  var filesCollapsedByDefault: Bool { didSet { settings.update { $0.diffFilesCollapsed = filesCollapsedByDefault } } }
  var showTree: Bool { didSet { store(showTree, "fileTree") } }

  @ObservationIgnored private var collapsedPaths: Set<String> = []
  @ObservationIgnored private var loadedScopeKey: String?
  @ObservationIgnored private var appliedRevealToken = 0
  @ObservationIgnored private var nextRevealToken = 0
  @ObservationIgnored private let fetch: DiffFetcher
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let settings: ClientSettingsStore
  @ObservationIgnored private var follow: Task<Void, Never>?

  private static func key(_ name: String) -> String { "diff.\(name)" }

  init(fetch: @escaping DiffFetcher, defaults: UserDefaults = .standard, settings: ClientSettingsStore = .shared) {
    self.fetch = fetch
    self.defaults = defaults
    self.settings = settings
    let client = settings.client
    layout = DiffLayoutMode(rawValue: client.diffLayout.rawValue) ?? .stacked
    wordWrap = client.wordWrap
    ignoreWhitespace = client.diffIgnoreWhitespace
    filesCollapsedByDefault = client.diffFilesCollapsed
    showTree = defaults.object(forKey: Self.key("fileTree")) as? Bool ?? true
    follow = Task { [weak self] in
      for await client in Observations({ settings.client }) { self?.adopt(client) }
    }
  }

  deinit { follow?.cancel() }

  private func adopt(_ client: ClientSettingsSchema) {
    if let next = DiffLayoutMode(rawValue: client.diffLayout.rawValue), next != layout { layout = next }
    if client.wordWrap != wordWrap { wordWrap = client.wordWrap }
    if client.diffIgnoreWhitespace != ignoreWhitespace { ignoreWhitespace = client.diffIgnoreWhitespace }
    if client.diffFilesCollapsed != filesCollapsedByDefault { filesCollapsedByDefault = client.diffFilesCollapsed }
  }

  private func store(_ value: Any, _ name: String) { defaults.set(value, forKey: Self.key(name)) }

  // MARK: Loading

  /// Fetches and applies a patch. `scopeKey` identifies what is compared: a new scope resets collapse state to
  /// the default, a refresh of the same scope keeps it. `revealPath` scrolls to a file once per `revealToken`.
  func load(_ request: DiffRequest, scopeKey: String, sectionId: String, sectionTitle: String, revealPath: String?, revealToken: Int) async {
    if loadedScopeKey != scopeKey { phase = .loading }
    do {
      let result = try await fetch(request)
      let parsed = await Task.detached(priority: .userInitiated) { UnifiedDiffParser.parse(result.patch) }.value
      guard !Task.isCancelled else { return }
      self.sectionId = sectionId
      self.sectionTitle = sectionTitle
      if loadedScopeKey != scopeKey {
        loadedScopeKey = scopeKey
        collapsedPaths = filesCollapsedByDefault ? Set(parsed.map(\.path)) : []
        commentText = ""
      } else {
        let known = Set(files.map(\.path))
        // A file that appears in a refresh follows the default; the others keep what the user chose.
        collapsedPaths = collapsedPaths.intersection(parsed.map(\.path))
        if filesCollapsedByDefault { collapsedPaths.formUnion(parsed.map(\.path).filter { !known.contains($0) }) }
      }
      // A selection indexes the old lines; a new patch invalidates it.
      selection = nil
      files = parsed
      truncated = result.truncated
      tree = Self.treeRows(parsed)
      phase = .ready
      if let revealPath, revealToken != appliedRevealToken {
        appliedRevealToken = revealToken
        revealFile(path: revealPath, rebuildRows: false)
      }
      rebuild()
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled else { return }
      phase = .failed(Self.message(error))
    }
  }

  private static func message(_ error: any Error) -> String {
    if let described = (error as? any LocalizedError)?.errorDescription { return described }
    let text = String(describing: error)
    return text.count > 300 ? String(text.prefix(300)) + "\u{2026}" : text
  }

  // MARK: Rows and collapse

  private var collapsedIds: Set<String> { Set(files.filter { collapsedPaths.contains($0.path) }.map(\.id)) }

  private func rebuild() {
    rows = DiffRows.build(files: files, collapsed: collapsedIds, layout: layout)
    revision += 1
  }

  func toggleCollapse(fileId: String) {
    guard let file = files.first(where: { $0.id == fileId }) else { return }
    if collapsedPaths.contains(file.path) { collapsedPaths.remove(file.path) } else { collapsedPaths.insert(file.path) }
    if selection?.fileId == fileId, collapsedPaths.contains(file.path) { selection = nil }
    rebuild()
  }

  var allCollapsed: Bool { !files.isEmpty && files.allSatisfy { collapsedPaths.contains($0.path) } }

  func toggleAllCollapsed() {
    collapsedPaths = allCollapsed ? [] : Set(files.map(\.path))
    selection = nil
    rebuild()
  }

  /// Expands the file and scrolls to it. A path may be repository- or workspace-relative.
  func revealFile(path: String, rebuildRows: Bool = true) {
    guard let file = files.first(where: { $0.path == path }) ?? files.first(where: { $0.path.hasSuffix("/" + path) || path.hasSuffix("/" + $0.path) })
    else { return }
    collapsedPaths.remove(file.path)
    nextRevealToken += 1
    reveal = DiffReveal(fileId: file.id, token: nextRevealToken)
    if rebuildRows { rebuild() }
  }

  // MARK: Comments

  /// Markers for comments already in the composer draft, as line ranges of the files they belong to.
  func markers(for comments: [(filePath: String, startIndex: Int, endIndex: Int)]) -> [String: [ClosedRange<Int>]] {
    var result: [String: [ClosedRange<Int>]] = [:]
    for comment in comments {
      guard let file = files.first(where: { $0.path == comment.filePath }),
        let range = ReviewComment.lineRange(in: file, startIndex: comment.startIndex, endIndex: comment.endIndex)
      else { continue }
      result[file.id, default: []].append(range)
    }
    return result
  }

  func pendingComment() -> ReviewCommentDraft? {
    guard let selection, let file = files.first(where: { $0.id == selection.fileId }) else { return nil }
    return ReviewComment.build(
      id: "diff-\(UUID().uuidString.lowercased())", sectionId: sectionId, sectionTitle: sectionTitle, file: file, lo: selection.lo, hi: selection.hi, text: commentText)
  }

  func clearSelection() {
    selection = nil
    commentText = ""
  }

  func file(id: String) -> DiffFile? { files.first { $0.id == id } }

  // MARK: Tree

  private static func treeRows(_ files: [DiffFile]) -> [DiffTreeRow] {
    let checkpoint = files.map { OrchestrationCheckpointFile(path: $0.path, kind: $0.changeType.rawValue, additions: $0.additions, deletions: $0.deletions) }
    var rows: [DiffTreeRow] = []
    func walk(_ nodes: [TurnDiffTreeNode], depth: Int) {
      for node in nodes {
        switch node {
        case .directory(let name, let path, let stat, let children):
          rows.append(DiffTreeRow(id: "d:" + path, depth: depth, name: name, path: path, isDirectory: true, additions: stat.additions, deletions: stat.deletions))
          walk(children, depth: depth + 1)
        case .file(let name, let path, let stat):
          rows.append(DiffTreeRow(id: "f:" + path, depth: depth, name: name, path: path, isDirectory: false, additions: stat?.additions ?? 0, deletions: stat?.deletions ?? 0))
        }
      }
    }
    walk(buildTurnDiffTree(checkpoint), depth: 0)
    return rows
  }

  var totalAdditions: Int { files.reduce(0) { $0 + $1.additions } }
  var totalDeletions: Int { files.reduce(0) { $0 + $1.deletions } }
}
