import Foundation
import Observation
import T3ClientRuntime

/// What a right-panel tab shows. Mirrors `RightPanelKind` in `apps/web/src/rightPanelStore.ts`; `diff`, `files` and
/// `file` have native views so far, the rest render a placeholder until their wave lands.
enum RightPanelKind: String, Codable, CaseIterable, Sendable {
  case diff, files, file, preview, device, terminal
  case pullRequest = "pull-request"
  case pullRequests = "pull-requests"
  case agents

  var title: String {
    switch self {
    case .diff: "Diff"
    case .files: "Files"
    case .file: "File"
    case .preview: "Preview"
    case .device: "Device"
    case .terminal: "Terminal"
    case .pullRequest: "Pull request"
    case .pullRequests: "Pull requests"
    case .agents: "Agents"
    }
  }

  var symbol: String {
    switch self {
    case .diff: "plusminus"
    case .files: "folder"
    case .file: "doc.text"
    case .preview: "globe"
    case .device: "iphone"
    case .terminal: "terminal"
    case .pullRequest, .pullRequests: "arrow.triangle.pull"
    case .agents: "person.2"
    }
  }
}

struct RightPanelSurface: Codable, Hashable, Identifiable, Sendable {
  /// Singleton kinds use their kind as id (`diff`); resource tabs would use `kind:resource`.
  var id: String
  var kind: RightPanelKind

  static func singleton(_ kind: RightPanelKind) -> RightPanelSurface { RightPanelSurface(id: kind.rawValue, kind: kind) }

  private static let filePrefix = "file:"
  /// One tab per opened file, `file:<workspace-relative path>` like the web.
  static func file(_ path: String) -> RightPanelSurface { RightPanelSurface(id: filePrefix + path, kind: .file) }

  /// The path of a file tab.
  var filePath: String? { kind == .file && id.hasPrefix(Self.filePrefix) ? String(id.dropFirst(Self.filePrefix.count)) : nil }

  private static let pullRequestPrefix = "pull-request:"
  /// One tab per opened pull request, `pull-request:<PullRequestTarget.id>`.
  static func pullRequest(_ target: PullRequestTarget) -> RightPanelSurface { RightPanelSurface(id: pullRequestPrefix + target.id, kind: .pullRequest) }
  /// The pull request of a pull request tab.
  var pullRequestTarget: PullRequestTarget? {
    kind == .pullRequest && id.hasPrefix(Self.pullRequestPrefix) ? PullRequestTarget(id: String(id.dropFirst(Self.pullRequestPrefix.count))) : nil
  }

  var title: String { filePath.map { FileLogic.basename($0) } ?? pullRequestTarget.map { "PR \($0.label)" } ?? kind.title }
}

/// A dialog over the thread that shows the right panel's files: the file picker or the content search.
struct FileDialogRequest: Identifiable, Equatable {
  enum Kind { case goToFile, searchContents }
  let id = UUID()
  let thread: String
  let kind: Kind
}

/// Lines to scroll to and mark in an opened file; `token` makes a repeated request for the same lines act again.
struct FileReveal: Equatable {
  var start: Int
  var end: Int
  var token: Int
}

struct ThreadRightPanelState: Codable, Equatable, Sendable {
  var isOpen = false
  var activeSurfaceId: String?
  var surfaces: [RightPanelSurface] = []

  var active: RightPanelSurface? { surfaces.first { $0.id == activeSurfaceId } }
}

/// What the diff tab compares, per thread (`diffPanelStore.ts`, plus the whole-thread diff).
enum DiffScope: Codable, Hashable, Sendable {
  case workingTree
  case branch
  case turn(turnId: String, filePath: String?, revealRequestId: Int)
  case allTurns
}

/// Thread-scoped right-panel state: which tabs are open, which is active, and what the diff tab compares.
/// Persisted locally per thread (the web keeps the same in localStorage); the width is shared by all threads.
@MainActor
@Observable
final class RightPanelStore {
  private(set) var byThread: [String: ThreadRightPanelState]
  private(set) var scopes: [String: DiffScope]
  /// Session only: the thread whose panel covers the chat.
  private(set) var maximizedThread: String?
  var width: CGFloat { didSet { defaults.set(Double(width), forKey: Self.widthKey) } }

  /// The file picker or content search being shown (session only).
  var fileDialog: FileDialogRequest?
  /// Pending `#L` anchors by `thread|path`, until the preview applied them.
  private(set) var fileReveals: [String: FileReveal] = [:]

  /// The store the window shows. Link routing reaches the panel through it (`AppModel.open(_:in:)` has no view).
  nonisolated(unsafe) private(set) static weak var live: RightPanelStore?

  @ObservationIgnored private let defaults: UserDefaults
  private static let stateKey = "rightPanel.state.v1"
  private static let scopesKey = "rightPanel.diffScope.v1"
  private static let widthKey = "rightPanel.width"
  static let defaultWidth: CGFloat = 520
  static let minimumWidth: CGFloat = 340

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    byThread = defaults.data(forKey: Self.stateKey).flatMap { try? JSONDecoder().decode([String: ThreadRightPanelState].self, from: $0) } ?? [:]
    scopes = defaults.data(forKey: Self.scopesKey).flatMap { try? JSONDecoder().decode([String: DiffScope].self, from: $0) } ?? [:]
    let stored = defaults.double(forKey: Self.widthKey)
    width = stored > 0 ? CGFloat(stored) : Self.defaultWidth
    Self.live = self
  }

  func state(_ key: ScopedThreadKey) -> ThreadRightPanelState { byThread[key.description] ?? ThreadRightPanelState() }
  func scope(_ key: ScopedThreadKey) -> DiffScope { scopes[key.description] ?? .workingTree }
  func isMaximized(_ key: ScopedThreadKey) -> Bool { maximizedThread == key.description && state(key).isOpen }

  // MARK: Tabs

  /// Opens (or activates) the singleton tab of `kind` and shows the panel.
  func open(_ kind: RightPanelKind, in key: ScopedThreadKey) {
    update(key) { state in
      let surface = RightPanelSurface.singleton(kind)
      if !state.surfaces.contains(surface) { state.surfaces.append(surface) }
      state.isOpen = true
      state.activeSurfaceId = surface.id
    }
  }

  /// Opens (or activates) a resource tab (a pull request) and shows the panel.
  func openSurface(_ surface: RightPanelSurface, in key: ScopedThreadKey) {
    update(key) { state in
      if !state.surfaces.contains(surface) { state.surfaces.append(surface) }
      state.isOpen = true
      state.activeSurfaceId = surface.id
    }
  }

  /// Closes the panel when `kind` is already the visible tab, else opens it there.
  func toggle(_ kind: RightPanelKind, in key: ScopedThreadKey) {
    let current = state(key)
    if current.isOpen, current.active?.kind == kind { close(key) } else { open(kind, in: key) }
  }

  func toggleVisibility(_ key: ScopedThreadKey) {
    if state(key).isOpen { close(key) } else if state(key).surfaces.isEmpty { open(.diff, in: key) } else { update(key) { $0.isOpen = true } }
  }

  func close(_ key: ScopedThreadKey) {
    if maximizedThread == key.description { maximizedThread = nil }
    update(key) { $0.isOpen = false }
  }

  func activate(_ surfaceId: String, in key: ScopedThreadKey) {
    update(key) { state in
      guard state.surfaces.contains(where: { $0.id == surfaceId }) else { return }
      state.activeSurfaceId = surfaceId
      state.isOpen = true
    }
  }

  func closeSurface(_ surfaceId: String, in key: ScopedThreadKey) {
    update(key) { state in
      guard let index = state.surfaces.firstIndex(where: { $0.id == surfaceId }) else { return }
      state.surfaces.remove(at: index)
      if state.activeSurfaceId == surfaceId {
        state.activeSurfaceId = state.surfaces.isEmpty ? nil : state.surfaces[min(index, state.surfaces.count - 1)].id
      }
      if state.surfaces.isEmpty { state.isOpen = false }
    }
    if state(key).isOpen == false, maximizedThread == key.description { maximizedThread = nil }
  }

  // MARK: Files

  /// Entry points for menus, commands and keybindings (`files.toggle`, `filePicker.toggle`, `projectSearch.toggle`).
  func openFiles(in key: ScopedThreadKey) { open(.files, in: key) }
  func goToFile(in key: ScopedThreadKey) { toggleDialog(.goToFile, in: key) }
  func searchContents(in key: ScopedThreadKey) { toggleDialog(.searchContents, in: key) }

  private func toggleDialog(_ kind: FileDialogRequest.Kind, in key: ScopedThreadKey) {
    fileDialog = fileDialog?.kind == kind && fileDialog?.thread == key.description ? nil : FileDialogRequest(thread: key.description, kind: kind)
  }

  /// Opens (or activates) the preview tab of a workspace file, scrolled to `line` when given.
  func openFile(_ path: String, line: Int? = nil, endLine: Int? = nil, in key: ScopedThreadKey) {
    let surface = RightPanelSurface.file(path)
    update(key) { state in
      if !state.surfaces.contains(surface) { state.surfaces.append(surface) }
      state.isOpen = true
      state.activeSurfaceId = surface.id
    }
    if let line {
      let id = revealKey(key, path)
      fileReveals[id] = FileReveal(start: line, end: max(line, endLine ?? line), token: (fileReveals[id]?.token ?? 0) + 1)
    }
  }

  func reveal(_ path: String, in key: ScopedThreadKey) -> FileReveal? { fileReveals[revealKey(key, path)] }
  func clearReveal(_ path: String, in key: ScopedThreadKey) { fileReveals[revealKey(key, path)] = nil }
  private func revealKey(_ key: ScopedThreadKey, _ path: String) -> String { "\(key.description)|\(path)" }

  func toggleMaximized(_ key: ScopedThreadKey) { maximizedThread = maximizedThread == key.description ? nil : key.description }

  // MARK: Diff scope

  func selectScope(_ scope: DiffScope, in key: ScopedThreadKey) {
    scopes[key.description] = scope
    persistScopes()
  }

  /// "Changed files" in the timeline: the panel opens on that turn, scrolled to the file.
  func revealDiff(turnId: String, filePath: String?, in key: ScopedThreadKey) {
    var next = 1
    if case .turn(_, _, let previous) = scope(key) { next = previous + 1 }
    selectScope(.turn(turnId: turnId, filePath: filePath, revealRequestId: next), in: key)
    open(.diff, in: key)
  }

  // MARK: Persistence

  private func update(_ key: ScopedThreadKey, _ change: (inout ThreadRightPanelState) -> Void) {
    var state = byThread[key.description] ?? ThreadRightPanelState()
    let before = state
    change(&state)
    guard state != before else { return }
    byThread[key.description] = state
    if let data = try? JSONEncoder().encode(byThread) { defaults.set(data, forKey: Self.stateKey) }
  }

  private func persistScopes() {
    if let data = try? JSONEncoder().encode(scopes) { defaults.set(data, forKey: Self.scopesKey) }
  }
}
