import AppKit
import Observation
import SwiftUI
import T3ClientRuntime
import T3Contracts

/// The workspace tree of one thread: folders list lazily (`projects.listEntries`, one level per expansion) and the
/// filter box switches to a flat `projects.searchEntries` result list.
@MainActor
@Observable
final class FilesTreeModel {
  final class Node: NSObject {
    let path: String
    let isDirectory: Bool
    let ignored: Bool
    /// nil until the folder was listed.
    var children: [Node]?
    var isLoading = false
    var name: String { FileLogic.basename(path) }

    init(_ entry: ProjectEntry) {
      path = entry.path
      isDirectory = entry.kind == .directory
      ignored = entry.ignored ?? false
    }
  }

  enum Phase: Equatable { case loading, ready, failed(String) }

  let key: ScopedThreadKey
  private(set) var phase = Phase.loading
  private(set) var roots: [Node] = []
  private(set) var results: [Node] = []
  private(set) var note: String?
  /// Bumped when the root list or the filter results changed; folder loads call `didLoad` instead.
  private(set) var revision = 0
  var filter = ""
  var isFiltering: Bool { !filter.trimmingCharacters(in: .whitespaces).isEmpty }
  /// Set by the outline view: a folder's children arrived.
  @ObservationIgnored var didLoad: (Node) -> Void = { _ in }
  @ObservationIgnored private weak var app: AppModel?

  init(app: AppModel, key: ScopedThreadKey) {
    self.app = app
    self.key = key
  }

  func loadRoot() async {
    guard let service = await app?.fileService(for: key) else {
      phase = .failed("The environment is not connected.")
      return
    }
    do throws(FileService.Failure) {
      let listing = try await service.list(nil)
      roots = listing.entries.map(Node.init)
      note = listing.truncated ? "Large workspace: the list is truncated. Use the filter to find files." : nil
      phase = .ready
    } catch {
      phase = .failed(error.localizedDescription)
    }
    revision += 1
  }

  func loadChildren(of node: Node) async {
    guard node.isDirectory, node.children == nil, !node.isLoading, let service = await app?.fileService(for: key) else { return }
    node.isLoading = true
    defer { node.isLoading = false }
    do throws(FileService.Failure) {
      node.children = try await service.list(node.path).entries.map(Node.init)
    } catch {
      node.children = []
      note = error.localizedDescription
    }
    didLoad(node)
  }

  /// Debounced by the caller's `.task(id:)`; an empty filter shows the tree again.
  func runFilter() async {
    guard isFiltering else {
      results = []
      revision += 1
      return
    }
    try? await Task.sleep(for: .milliseconds(120))
    guard !Task.isCancelled, let service = await app?.fileService(for: key) else { return }
    do throws(FileService.Failure) {
      results = try await service.searchEntries(filter.trimmingCharacters(in: .whitespaces), limit: 200).map(Node.init)
    } catch {
      results = []
      note = error.localizedDescription
    }
    if !Task.isCancelled { revision += 1 }
  }
}

struct FileRowActions {
  var open: (String) -> Void
  var openInEditor: (String) -> Void
  var reveal: (String) -> Void
  var copyPath: (String) -> Void
  var copyRelativePath: (String) -> Void
  var addToMessage: (String) -> Void
  var canReveal: Bool
}

/// The Files tab: filter field and the tree.
struct FilesPanelView: View {
  let app: AppModel
  let key: ScopedThreadKey
  let store: RightPanelStore
  @State private var tree: FilesTreeModel

  init(app: AppModel, key: ScopedThreadKey, store: RightPanelStore) {
    self.app = app
    self.key = key
    self.store = store
    _tree = State(initialValue: FileSurfaces.shared.tree(in: key, app: app))
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
        TextField("Filter files", text: Bindable(tree).filter)
          .textFieldStyle(.plain)
          .accessibilityLabel("Filter files")
        if tree.isFiltering {
          Button { tree.filter = "" } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.borderless).foregroundStyle(Palette.muted).accessibilityLabel("Clear filter")
        }
        Button { Task { await tree.loadRoot() } } label: { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.borderless).help("Reload files").accessibilityLabel("Reload files")
      }
      .padding(.horizontal, 12)
      .frame(height: 34)
      Divider()
      content
      if let note = tree.note {
        Divider()
        Text(note).font(.caption).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .leading).padding(8)
      }
    }
    .task { if tree.phase != .ready { await tree.loadRoot() } }
    .task(id: tree.filter) { await tree.runFilter() }
  }

  @ViewBuilder private var content: some View {
    switch tree.phase {
    case .loading:
      ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let message):
      ContentUnavailableView {
        Label("Could not load files", systemImage: "exclamationmark.triangle")
      } description: {
        Text(message)
      } actions: {
        Button("Try Again") { Task { await tree.loadRoot() } }
      }
    case .ready where tree.roots.isEmpty:
      ContentUnavailableView("No files", systemImage: "folder", description: Text("This workspace is empty."))
    case .ready where tree.isFiltering && tree.results.isEmpty && tree.revision > 0:
      ContentUnavailableView.search(text: tree.filter)
    case .ready:
      FilesOutline(model: tree, revision: tree.revision, actions: actions)
    }
  }

  private var actions: FileRowActions {
    FileRowActions(
      open: { store.openFile($0, in: key) },
      openInEditor: { app.openInEditor($0, in: key) },
      reveal: { app.revealInFinder($0, in: key) },
      copyPath: { app.copyToPasteboard(app.absoluteFilePath($0, in: key)) },
      copyRelativePath: { app.copyToPasteboard($0) },
      addToMessage: { app.addFileToComposer($0, in: key) },
      canReveal: app.isLocalEnvironment(key))
  }
}

// MARK: Outline

final class FilesOutlineView: NSOutlineView {
  var menuProvider: ((FilesTreeModel.Node) -> NSMenu?)?

  override func menu(for event: NSEvent) -> NSMenu? {
    let row = row(at: convert(event.locationInWindow, from: nil))
    guard row >= 0, let node = item(atRow: row) as? FilesTreeModel.Node else { return nil }
    selectRowIndexes([row], byExtendingSelection: false)
    return menuProvider?(node)
  }
}

private struct FilesOutline: NSViewRepresentable {
  let model: FilesTreeModel
  let revision: Int
  let actions: FileRowActions

  func makeCoordinator() -> Coordinator { Coordinator(model: model) }

  func makeNSView(context: Context) -> NSScrollView {
    let outline = FilesOutlineView()
    outline.headerView = nil
    outline.style = .sourceList
    outline.rowSizeStyle = .default
    outline.floatsGroupRows = false
    outline.indentationPerLevel = 14
    let column = NSTableColumn(identifier: .init("name"))
    column.resizingMask = .autoresizingMask
    outline.addTableColumn(column)
    outline.outlineTableColumn = column
    outline.dataSource = context.coordinator
    outline.delegate = context.coordinator
    outline.target = context.coordinator
    outline.action = #selector(Coordinator.clicked)
    outline.setAccessibilityLabel("Workspace files")
    // Expansion survives reloads (filter on and off) by path.
    outline.autosaveName = "files.tree.\(model.key.description)"
    outline.autosaveExpandedItems = true
    context.coordinator.outline = outline
    model.didLoad = { [weak coordinator = context.coordinator] node in
      coordinator?.outline?.reloadItem(node, reloadChildren: true)
    }
    let scroll = NSScrollView()
    scroll.documentView = outline
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    outline.backgroundColor = .clear
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    let coordinator = context.coordinator
    coordinator.actions = actions
    if coordinator.revision != revision {
      coordinator.revision = revision
      coordinator.outline?.reloadData()
    }
  }

  @MainActor
  final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let model: FilesTreeModel
    weak var outline: FilesOutlineView? {
      didSet { outline?.menuProvider = { [weak self] node in self?.menu(for: node) } }
    }
    var actions: FileRowActions?
    var revision = -1

    init(model: FilesTreeModel) { self.model = model }

    private func children(of item: Any?) -> [FilesTreeModel.Node] {
      if let node = item as? FilesTreeModel.Node { return node.children ?? [] }
      return model.isFiltering ? model.results : model.roots
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(of: item).count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { children(of: item)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FilesTreeModel.Node)?.isDirectory == true && !model.isFiltering }

    func outlineView(_ outlineView: NSOutlineView, persistentObjectForItem item: Any?) -> Any? { (item as? FilesTreeModel.Node)?.path }
    func outlineView(_ outlineView: NSOutlineView, itemForPersistentObject object: Any) -> Any? {
      guard let path = object as? String else { return nil }
      return model.isFiltering ? nil : find(path, in: model.roots)
    }

    private func find(_ path: String, in nodes: [FilesTreeModel.Node]) -> FilesTreeModel.Node? {
      for node in nodes {
        if node.path == path { return node }
        if node.isDirectory, path.hasPrefix(node.path + "/"), let children = node.children, let hit = find(path, in: children) { return hit }
      }
      return nil
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
      guard let node = notification.userInfo?["NSObject"] as? FilesTreeModel.Node, node.children == nil else { return }
      Task { await model.loadChildren(of: node) }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
      guard let node = item as? FilesTreeModel.Node else { return nil }
      let identifier = NSUserInterfaceItemIdentifier("fileCell")
      let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? makeCell(identifier)
      cell.imageView?.image = NSImage(systemSymbolName: FileLogic.symbol(for: node.path, isDirectory: node.isDirectory), accessibilityDescription: nil)
      cell.imageView?.contentTintColor = node.isDirectory ? .controlAccentColor : .secondaryLabelColor
      let text = NSMutableAttributedString(string: node.name, attributes: [.foregroundColor: node.ignored ? NSColor.tertiaryLabelColor : NSColor.labelColor])
      if model.isFiltering, case let parent = FileLogic.directory(node.path), !parent.isEmpty {
        text.append(NSAttributedString(string: "  \(parent)", attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: NSFont.systemFont(ofSize: 11)]))
      }
      cell.textField?.attributedStringValue = text
      cell.setAccessibilityLabel(node.isDirectory ? "Folder \(node.name)" : "\(node.name)")
      return cell
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
      let cell = NSTableCellView()
      cell.identifier = identifier
      let image = NSImageView()
      image.translatesAutoresizingMaskIntoConstraints = false
      let label = NSTextField(labelWithString: "")
      label.translatesAutoresizingMaskIntoConstraints = false
      label.lineBreakMode = .byTruncatingMiddle
      cell.addSubview(image)
      cell.addSubview(label)
      cell.imageView = image
      cell.textField = label
      NSLayoutConstraint.activate([
        image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
        image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        image.widthAnchor.constraint(equalToConstant: 16),
        label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
        label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
        label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      ])
      return cell
    }

    @objc func clicked(_ sender: NSOutlineView) {
      guard sender.clickedRow >= 0, let node = sender.item(atRow: sender.clickedRow) as? FilesTreeModel.Node else { return }
      if node.isDirectory {
        if sender.isItemExpanded(node) { sender.collapseItem(node) } else if !model.isFiltering { sender.expandItem(node) }
      } else {
        actions?.open(node.path)
      }
    }

    private func menu(for node: FilesTreeModel.Node) -> NSMenu? {
      guard let actions else { return nil }
      let menu = NSMenu()
      func add(_ title: String, _ action: @escaping (String) -> Void) {
        let item = ClosureMenuItem(title: title) { action(node.path) }
        menu.addItem(item)
      }
      if !node.isDirectory { add("Open Preview", actions.open) }
      add("Open in Editor", actions.openInEditor)
      if actions.canReveal { add("Reveal in Finder", actions.reveal) }
      menu.addItem(.separator())
      add("Copy Path", actions.copyPath)
      add("Copy Relative Path", actions.copyRelativePath)
      menu.addItem(.separator())
      add(node.isDirectory ? "Add Folder to Message" : "Add to Message", actions.addToMessage)
      return menu
    }
  }
}

/// An `NSMenuItem` that runs a closure (menus here are built per click).
final class ClosureMenuItem: NSMenuItem {
  private let handler: () -> Void

  init(title: String, handler: @escaping () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(run), keyEquivalent: "")
    target = self
  }

  required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  @objc private func run() { handler() }
}
