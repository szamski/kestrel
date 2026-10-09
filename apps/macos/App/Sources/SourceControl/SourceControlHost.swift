import AppKit
import SwiftUI
import T3ClientRuntime
import T3Contracts

/// The reading window's source control surfaces that are not a control of their own: the toast, the dialogs
/// and the key bindings (`composer.branch`, `script.<id>.run` ...).
struct SourceControlHost: ViewModifier {
  @Environment(AppModel.self) private var app
  @Environment(CommandCenter.self) private var commands

  func body(content: Content) -> some View {
    let store = app.sourceControl
    let scriptIDs = store.activeInfo.map { store.scripts(for: $0.project).map(\.id) } ?? []
    content
      .overlay(alignment: .topTrailing) {
        if let hud = store.hud {
          SourceControlHUDView(store: store, hud: hud)
            .padding(16)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
      }
      .animation(.snappy(duration: 0.2), value: store.hud?.id)
      .sheet(
        item: Binding(get: { store.dialog }, set: { store.dialog = $0 })
      ) { dialog in
        switch dialog {
        case .commit(let context): CommitSheet(store: store, context: context)
        case .publish(let context): PublishSheet(store: store, context: context)
        case .defaultBranch(let pending): DefaultBranchSheet(store: store, pending: pending)
        case .script(let request): ScriptEditorSheet(store: store, request: request)
        }
      }
      .task { registerStripCommands(store) }
      #if DEBUG
      .task { await SourceControlDebug.run(store) }
      #endif
      .onChange(of: scriptIDs, initial: true) { registerScriptCommands(store, scriptIDs) }
  }

  private func registerStripCommands(_ store: SourceControlStore) {
    let available: () -> Bool = { store.visibleStrips > 0 }
    commands.register(.composerBranch, isAvailable: available) { store.branchPickerRequest += 1 }
    commands.register(.composerWorkspace, isAvailable: available) { store.workspaceMenuRequest += 1 }
    commands.register(.composerHost, isAvailable: available) { store.environmentMenuRequest += 1 }
    commands.register(.composerPreviousWorktree, isAvailable: available) { store.previousWorktreeRequest += 1 }
  }

  /// A handler stays registered after its script goes away and is then simply unavailable.
  private func registerScriptCommands(_ store: SourceControlStore, _ ids: [String]) {
    for id in ids {
      guard let command = ProjectScriptsLogic.command(forScriptID: id) else { continue }
      commands.register(
        command,
        isAvailable: { store.activeScript(id) != nil },
        perform: {
          if let (info, script) = store.activeScript(id) { store.run(script, in: info) }
        })
    }
  }
}

extension SourceControlStore {
  /// The thread or draft in view.
  var activeInfo: WorkspaceInfo? {
    guard let app else { return nil }
    if let key = app.selection { return info(for: key, draft: nil) }
    if let draft = app.draft { return info(for: draft.key, draft: draft) }
    return nil
  }

  func activeScript(_ id: String) -> (WorkspaceInfo, ProjectScript)? {
    guard let info = activeInfo, let script = scripts(for: info.project).first(where: { $0.id == id }) else { return nil }
    return (info, script)
  }
}

/// The header's source control controls: actions, then git.
struct SourceControlToolbarItems: View {
  @Environment(AppModel.self) private var app
  let key: ScopedThreadKey
  var draft: DraftThread?

  var body: some View {
    if let info = app.sourceControl.info(for: key, draft: draft) {
      ProjectScriptsMenu(app: app, store: app.sourceControl, info: info)
      GitActionsMenu(store: app.sourceControl, info: info)
    }
  }
}

struct SourceControlHUDView: View {
  let store: SourceControlStore
  let hud: SourceControlHUD

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      icon.frame(width: 18, height: 18)
      VStack(alignment: .leading, spacing: 3) {
        Text(hud.title).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
        if let detail = hud.detail {
          Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(4).fixedSize(horizontal: false, vertical: true)
        }
        if let cta = hud.cta { Button(label(cta)) { perform(cta) }.buttonStyle(.link).font(.callout) }
      }
      if hud.kind != .loading {
        Button { store.dismissHUD() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("Dismiss")
      }
    }
    .padding(12)
    .frame(width: 320, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border))
    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
  }

  @ViewBuilder private var icon: some View {
    switch hud.kind {
    case .loading: ProgressView().controlSize(.small)
    case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case .error: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
    case .info: Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
    }
  }

  private func label(_ cta: SourceControlHUD.Cta) -> String {
    switch cta {
    case .open(let label, _), .run(let label, _, _): label
    }
  }

  private func perform(_ cta: SourceControlHUD.Cta) {
    store.dismissHUD()
    switch cta {
    case .open(_, let url): NSWorkspace.shared.open(url)
    case .run(_, let action, let context): store.runAction(context, action)
    }
  }
}
