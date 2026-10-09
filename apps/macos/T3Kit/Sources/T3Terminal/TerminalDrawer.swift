import Observation
import T3Contracts
import SwiftUI

/// Terminals of one thread: layout (tabs and splits), one session per terminal, and the metadata
/// feed. Mirrors ThreadTerminalDrawer's behavior; the app supplies how a terminal starts.
@MainActor @Observable
public final class TerminalDrawerModel {
  public let threadId: String
  public private(set) var layout = TerminalLayout()
  public let metadata: TerminalMetadataModel
  /// Terminal awaiting close confirmation because a subprocess is still running.
  public var pendingClose: String?
  /// Bumped when the host (a command, opening the drawer) wants keyboard focus in the active terminal.
  public private(set) var focusRequest = 0
  /// The last terminal was closed; the host should hide the drawer.
  @ObservationIgnored public var onDrawerEmpty: (() -> Void)?

  @ObservationIgnored private let transport: any TerminalTransport
  @ObservationIgnored private let makeTarget: (_ terminalId: String) -> TerminalTarget
  @ObservationIgnored private var sessions: [String: TerminalSession] = [:]
  /// Closed ids hidden from stale metadata until reopened.
  @ObservationIgnored private var suppressed: Set<String> = []

  public init(threadId: String, transport: any TerminalTransport, metadata: TerminalMetadataModel? = nil, makeTarget: @escaping (String) -> TerminalTarget) {
    self.threadId = threadId
    self.transport = transport
    self.metadata = metadata ?? TerminalMetadataModel(transport: transport)
    self.makeTarget = makeTarget
  }

  public func start() { metadata.start() }

  public func requestFocus() { focusRequest += 1 }

  public func stop() {
    metadata.stop()
    sessions.values.forEach { $0.stop() }
  }

  public func session(for terminalId: String) -> TerminalSession {
    if let existing = sessions[terminalId] { return existing }
    let session = TerminalSession(target: makeTarget(terminalId), transport: transport)
    session.onSessionExited = { [weak self] in self?.close(terminalId) }
    sessions[terminalId] = session
    return session
  }

  public func summary(for terminalId: String) -> TerminalSummary? {
    metadata.terminals(for: threadId).first { $0.terminalId == terminalId }
  }

  public func title(for terminalId: String) -> String { summary(for: terminalId)?.label ?? terminalId }

  public func newTerminal() {
    let id = TerminalLayout.nextTerminalId(existing: layout.terminalIds)
    suppressed.remove(id)
    layout.newTerminal(id)
    requestFocus()
  }

  public func split(vertical: Bool) {
    guard !layout.hasReachedSplitLimit else { return }
    let id = TerminalLayout.nextTerminalId(existing: layout.terminalIds)
    suppressed.remove(id)
    layout.split(id, vertical: vertical)
    requestFocus()
  }

  public func activate(_ terminalId: String) { layout.activate(terminalId) }

  /// Close button: asks first when a subprocess is running (as the web drawer does).
  public func requestClose(_ terminalId: String) {
    if summary(for: terminalId)?.hasRunningSubprocess == true { pendingClose = terminalId } else { close(terminalId) }
  }

  public func close(_ terminalId: String) {
    pendingClose = nil
    guard layout.terminalIds.contains(terminalId) else { return }
    let session = sessions.removeValue(forKey: terminalId) ?? self.session(for: terminalId)
    sessions[terminalId] = nil
    suppressed.insert(terminalId)
    let wasLast = layout.terminalIds == [terminalId]
    layout.close(terminalId)
    Task { try? await session.close(deleteHistory: true) }
    if wasLast { onDrawerEmpty?() }
  }

  /// Call when metadata changes.
  public func reconcileWithServer() {
    layout.reconcile(serverTerminalIds: metadata.terminals(for: threadId).map(\.terminalId), suppressed: suppressed)
  }
}

/// Tabs (one per group) over split panes, with split / split vertical / new / close.
public struct TerminalDrawerView: View {
  @Bindable var model: TerminalDrawerModel
  let theme: TerminalTheme
  let font: TerminalFont
  var onOpenLink: ((TerminalLinkTarget) -> Void)?
  @State private var focusRequest = 0

  public init(model: TerminalDrawerModel, theme: TerminalTheme = .dark, font: TerminalFont = TerminalFont(), onOpenLink: ((TerminalLinkTarget) -> Void)? = nil) {
    self.model = model
    self.theme = theme
    self.font = font
    self.onOpenLink = onOpenLink
  }

  public var body: some View {
    VStack(spacing: 0) {
      header
      if let group = model.layout.activeGroup {
        let panes = group.terminalIds.map { pane($0) }
        Group {
          if group.isVertical { VStack(spacing: 1) { ForEach(Array(panes.enumerated()), id: \.offset) { $0.element } } }
          else { HStack(spacing: 1) { ForEach(Array(panes.enumerated()), id: \.offset) { $0.element } } }
        }
      }
    }
    .task { model.start() }
    .onChange(of: model.metadata.terminals) { model.reconcileWithServer() }
    .confirmationDialog("Close terminal?", isPresented: Binding(get: { model.pendingClose != nil }, set: { if !$0 { model.pendingClose = nil } })) {
      Button("Close Terminal", role: .destructive) { if let id = model.pendingClose { model.close(id) } }
    } message: { Text("A process is still running in this terminal.") }
  }

  private func pane(_ terminalId: String) -> some View {
    TerminalView(session: model.session(for: terminalId), theme: theme, font: font, focusRequest: terminalId == model.layout.activeTerminalId ? focusRequest + model.focusRequest : 0, onOpenLink: onOpenLink)
      .id(terminalId)
      .overlay(alignment: .topTrailing) {
        if (model.layout.activeGroup?.terminalIds.count ?? 0) > 1 {
          Button { model.requestClose(terminalId) } label: { Image(systemName: "xmark") }
            .buttonStyle(.plain).padding(6).accessibilityLabel("Close terminal")
        }
      }
      .simultaneousGesture(TapGesture().onEnded { model.activate(terminalId) })
  }

  private var header: some View {
    HStack(spacing: 4) {
      ForEach(model.layout.groups) { group in
        let id = group.terminalIds.first ?? ""
        Button { model.activate(group.terminalIds.contains(model.layout.activeTerminalId) ? model.layout.activeTerminalId : id); focusRequest += 1 } label: {
          Text(group.terminalIds.map(model.title(for:)).joined(separator: " | ")).lineLimit(1)
        }
        .buttonStyle(.bordered).controlSize(.small)
        .tint(group.id == model.layout.activeGroupId ? .accentColor : nil)
        .accessibilityAddTraits(group.id == model.layout.activeGroupId ? .isSelected : [])
      }
      Spacer()
      Button { model.split(vertical: false); focusRequest += 1 } label: { Image(systemName: "square.split.2x1") }
        .disabled(model.layout.hasReachedSplitLimit).help("Split terminal").accessibilityLabel("Split terminal")
      Button { model.split(vertical: true); focusRequest += 1 } label: { Image(systemName: "square.split.1x2") }
        .disabled(model.layout.hasReachedSplitLimit).help("Split terminal vertically").accessibilityLabel("Split terminal vertically")
      Button { model.newTerminal(); focusRequest += 1 } label: { Image(systemName: "plus") }
        .help("New terminal").accessibilityLabel("New terminal")
      Button { model.requestClose(model.layout.activeTerminalId) } label: { Image(systemName: "xmark") }
        .help("Close terminal").accessibilityLabel("Close terminal")
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 8).padding(.vertical, 4)
  }
}
