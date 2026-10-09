import AppKit
import SwiftUI
import T3ClientRuntime
import T3Composer
import T3Contracts

/// The strip under the composer: where the thread runs (environment, checkout or worktree) and its branch.
/// It shows for git repositories, like the web client's context strip.
struct SourceControlStrip: View {
  @Environment(AppModel.self) private var app
  let key: ScopedThreadKey
  var draft: DraftThread?

  var body: some View {
    Group {
      if let info = app.sourceControl.info(for: key, draft: draft) {
        StripBody(app: app, store: app.sourceControl, info: info)
      } else {
        Color.clear.frame(height: 12)
      }
    }
    .frame(maxWidth: timelineColumnWidth + 2 * timelineHorizontalInset)
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 20)
  }
}

private struct StripBody: View {
  let app: AppModel
  let store: SourceControlStore
  let info: WorkspaceInfo
  @State private var environmentOpen = false
  @State private var workspaceOpen = false
  @State private var branchOpen = false

  private var model: VcsStatusModel { store.statusModel(info.key.environmentId, cwd: info.cwd) }

  /// The same logical project in every environment that has it.
  private var members: [EnvironmentProject] {
    let ref = ScopedProjectRef(environmentId: info.key.environmentId, projectId: info.project.projectId)
    return app.runtime.projectGroups.first { $0.memberProjectRefs.contains(ref) }?.members.map(\.project) ?? [info.project]
  }

  var body: some View {
    let status = model.status
    let isRepo = status?.isRepo == true
    let showEnvironment = members.count > 1 || !store.isLocal(info.key.environmentId)
    HStack(spacing: 2) {
      if showEnvironment { environmentChip }
      if isRepo { workspaceChip }
      Spacer(minLength: 8)
      if isRepo {
        if let pr = status?.pr { PullRequestChip(pr: pr) }
        branchChip(status)
      }
    }
    .font(.system(size: 12))
    .foregroundStyle(Palette.muted)
    .frame(height: 26)
    .padding(.bottom, 6)
    .modifier(FollowsStatus(model: model))
    .onAppear { store.visibleStrips += 1 }
    .onDisappear { store.visibleStrips -= 1 }
    .onChange(of: store.branchPickerRequest) { if isRepo { branchOpen = true } }
    .onChange(of: store.workspaceMenuRequest) { if isRepo, info.isDraft { workspaceOpen = true } }
    .onChange(of: store.environmentMenuRequest) { if members.count > 1, info.isDraft { environmentOpen = true } }
    .onChange(of: store.previousWorktreeRequest) {
      if isRepo, let seed = store.previousWorktree(info) {
        store.usePreviousWorktree(info, seed)
        focusComposer()
      }
    }
    // A worktree starts from a base branch: the project's default, else the checked-out one.
    .task(id: DefaultBase(wanted: info.isDraft && info.envMode == .worktree && info.worktreePath == nil && info.workspace.branch == nil && isRepo, cwd: info.cwd)) {
      guard info.isDraft, info.envMode == .worktree, info.worktreePath == nil, info.workspace.branch == nil, isRepo else { return }
      let refs = try? await store.listRefs(info.key.environmentId, cwd: info.cwd, query: "", cursor: nil)
      let base = refs?.refs.first(where: \.isDefault)?.name ?? status?.refName
      if let base, info.workspace.branch == nil { store.updateWorkspace(info) { $0.branch = base } }
    }
    // A draft follows the checkout it is in.
    .onChange(of: status) {
      guard info.isDraft, !(info.envMode == .worktree && info.worktreePath == nil), !store.isRunning(info.context),
        let branch = BranchToolbarLogic.resolveLiveDraftBranchUpdate(draftBranch: info.workspace.branch, status: status)
      else { return }
      store.setBranch(info.context, branch)
    }
  }

  private struct DefaultBase: Equatable {
    var wanted: Bool
    var cwd: String
  }

  private func focusComposer() {
    LiveComposers.shared.model(for: info.key.description)?.requestFocus()
  }

  // MARK: Environment

  private var environmentChip: some View {
    let label = store.environmentLabel(info.key.environmentId)
    let icon = store.isLocal(info.key.environmentId) ? "desktopcomputer" : "server.rack"
    return Group {
      if info.isDraft && members.count > 1 {
        Button { environmentOpen.toggle() } label: { StripLabel(icon: icon, title: label, chevron: true) }
          .buttonStyle(.plain)
          .popover(isPresented: $environmentOpen, arrowEdge: .bottom) {
            PopoverList {
              ForEach(members, id: \.id) { member in
                PopoverRow(
                  title: store.environmentLabel(member.environmentId), icon: store.isLocal(member.environmentId) ? "desktopcomputer" : "server.rack",
                  selected: member.environmentId == info.key.environmentId
                ) {
                  environmentOpen = false
                  if member.environmentId != info.key.environmentId { app.startNewThread(in: member, label: info.project.project.title) }
                }
              }
            }
          }
          .help("Run on")
      } else {
        StripLabel(icon: icon, title: label, chevron: false).help("Runs on \(label)")
      }
    }
  }

  // MARK: Workspace

  private var workspaceChip: some View {
    let mode = info.envMode
    let worktree = info.worktreePath
    let icon = mode == .worktree ? "arrow.triangle.branch" : worktree != nil ? "folder.badge.gearshape" : "folder"
    return Group {
      if info.isDraft {
        let seed = store.previousWorktree(info)
        let title = mode == .worktree ? "New worktree" : (worktree != nil ? "Current worktree" : "Current checkout")
        Button { workspaceOpen.toggle() } label: { StripLabel(icon: icon, title: title, chevron: true) }
          .buttonStyle(.plain)
          .popover(isPresented: $workspaceOpen, arrowEdge: .bottom) {
            PopoverList {
              PopoverRow(title: worktree != nil ? "Current worktree" : "Current checkout", icon: "folder", selected: mode == .local) {
                workspaceOpen = false
                store.setEnvMode(info, .local)
                focusComposer()
              }
              PopoverRow(title: "New worktree", icon: "arrow.triangle.branch", selected: mode == .worktree) {
                workspaceOpen = false
                store.setEnvMode(info, .worktree)
                focusComposer()
              }
              if let seed {
                Divider().padding(.vertical, 4)
                PopoverRow(title: BranchToolbarLogic.previousWorktreeLabel(seed), icon: "arrow.uturn.backward", selected: false) {
                  workspaceOpen = false
                  store.usePreviousWorktree(info, seed)
                  focusComposer()
                }
              }
            }
          }
          .help("Where this thread runs")
      } else {
        // A started thread's workspace is fixed.
        let title = worktree != nil ? "Worktree" : mode == .worktree ? "New worktree" : "Local checkout"
        StripLabel(icon: icon, title: title, chevron: false).help(worktree ?? info.project.project.workspaceRoot)
      }
    }
  }

  // MARK: Branch

  private func branchChip(_ status: VcsStatus?) -> some View {
    let mode = info.envMode
    let active = BranchToolbarLogic.resolveBranchToolbarValue(
      envMode: mode, activeWorktreePath: info.worktreePath, activeThreadBranch: info.threadBranch, currentGitBranch: status?.refName)
    let title = BranchToolbarLogic.resolveBranchTriggerLabel(
      activeWorktreePath: info.worktreePath, envMode: mode, activeBranch: active, activeBranchIsRemote: active.map { $0.hasPrefix("origin/") },
      startFromOrigin: info.workspace.startFromOrigin)
    return Button { branchOpen.toggle() } label: { StripLabel(icon: "arrow.triangle.branch", title: title, chevron: true) }
      .buttonStyle(.plain)
      .popover(isPresented: $branchOpen, arrowEdge: .bottom) {
        BranchPicker(store: store, info: info, activeBranch: active) {
          branchOpen = false
          focusComposer()
        }
      }
      .help("Switch ref")
  }
}

/// Icon, title and an optional chevron; a hover highlight when it opens something.
struct StripLabel: View {
  var icon: String
  var title: String
  var chevron: Bool
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: icon).font(.system(size: 11))
      Text(title).lineLimit(1).truncationMode(.middle)
      if chevron { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
    }
    .padding(.horizontal, 7)
    .frame(height: 24)
    .background(hovering && chevron ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
  }
}

private struct PullRequestChip: View {
  let pr: VcsStatusRemoteResultPr

  var body: some View {
    Button {
      if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
    } label: {
      StripLabel(icon: "arrow.triangle.pull", title: "#\(pr.number)", chevron: true).foregroundStyle(tint)
    }
    .buttonStyle(.plain)
    .help("\(pr.title) (\(pr.state.rawValue))")
  }

  private var tint: Color {
    switch pr.state {
    case .open: .green
    case .merged: .purple
    case .closed: .red
    default: Palette.muted
    }
  }
}

struct PopoverList<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 1) { content }
      .padding(6)
      .frame(minWidth: 210, alignment: .leading)
  }
}

struct PopoverRow: View {
  var title: String
  var icon: String
  var selected: Bool
  var action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: icon).frame(width: 16)
        Text(title).lineLimit(1)
        Spacer(minLength: 12)
        if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
      }
      .padding(.horizontal, 8)
      .frame(height: 26)
      .background(hovering ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }
}

extension SourceControlStore {
  func isLocal(_ environmentId: EnvironmentId) -> Bool {
    ["localhost", "127.0.0.1", "::1", "[::1]"].contains(runtime.connectionEntry(environmentId)?.httpBaseURL.host(percentEncoded: false) ?? "")
  }

  func environmentLabel(_ environmentId: EnvironmentId) -> String {
    runtime.environments.first { $0.environmentId == environmentId }?.label ?? environmentId.rawValue
  }
}
