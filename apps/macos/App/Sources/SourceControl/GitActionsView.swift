import AppKit
import SwiftUI
import T3ClientRuntime
import T3Contracts

/// Header control: the quick action (commit, push, pull, pull request ...) with the full list behind it.
struct GitActionsMenu: View {
  let store: SourceControlStore
  let info: WorkspaceInfo

  var body: some View {
    let context = info.context
    let model = store.statusModel(context.environmentId, cwd: context.cwd)
    let status = model.status
    Group {
      if let status, status.isRepo {
        let busy = store.isRunning(context)
        let quick = GitActionsLogic.quickAction(status, isBusy: busy, isDefaultRef: status.isDefaultRef, hasPrimaryRemote: status.hasPrimaryRemote)
        Menu {
          ForEach(GitActionsLogic.menuItems(status, isBusy: busy, hasPrimaryRemote: status.hasPrimaryRemote)) { item in
            Button(item.label, systemImage: Self.symbol(item.id)) { open(item, context: context, status: status) }
              .disabled(item.disabled)
          }
          Divider()
          if !status.hasPrimaryRemote { Button("Publish repository\u{2026}", systemImage: "square.and.arrow.up") { store.dialog = .publish(context) } }
          if status.hasUpstream { Button("Pull", systemImage: "arrow.down.circle") { store.pull(context) }.disabled(busy || status.behindCount == 0) }
          Button("Refresh status", systemImage: "arrow.clockwise") { model.refresh() }
        } label: {
          Label(quick.label, systemImage: Self.symbol(quick)).labelStyle(.titleAndIcon)
        } primaryAction: {
          store.run(quick, context, status: status)
        }
        .menuIndicator(.visible)
        .disabled(busy)
        .help(quick.disabled ? (quick.hint ?? "This action is currently unavailable.") : quick.label)
      }
    }
    .modifier(FollowsStatus(model: model))
  }

  private func open(_ item: GitActionMenuItem, context: GitContext, status: VcsStatus) {
    switch item.kind {
    case .openPr: store.openPullRequest(status)
    case .openDialog:
      if item.id == .commit { store.dialog = .commit(context) } else if let action = item.action { store.runAction(context, action) }
    }
  }

  static func symbol(_ id: GitActionMenuItem.ID) -> String {
    switch id {
    case .commit: "checkmark.circle"
    case .push: "arrow.up.circle"
    case .pr: "arrow.triangle.pull"
    }
  }

  static func symbol(_ quick: GitQuickAction) -> String {
    switch quick.kind {
    case .runPull: "arrow.down.circle"
    case .openPublish: "square.and.arrow.up"
    case .openPr: "arrow.triangle.pull"
    case .showHint: "checkmark.circle"
    case .runAction:
      switch quick.action {
      case .push: "arrow.up.circle"
      case .create_pr, .commit_push_pr: "arrow.triangle.pull"
      case .commit_push: "arrow.up.circle"
      default: "checkmark.circle"
      }
    }
  }
}

// MARK: - Commit

struct CommitSheet: View {
  let store: SourceControlStore
  let context: GitContext
  @Environment(\.dismiss) private var dismiss
  @State private var message = ""
  @State private var excluded: Set<String> = []
  @FocusState private var messageFocused: Bool

  var body: some View {
    let model = store.statusModel(context.environmentId, cwd: context.cwd)
    let status = model.status
    let files = status?.files ?? []
    let selected = files.filter { !excluded.contains($0.path) }
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Commit changes").font(.headline)
        Text("Review and confirm your commit. Leave the message empty to generate one.").font(.callout).foregroundStyle(.secondary)
      }
      HStack(spacing: 6) {
        Image(systemName: "arrow.triangle.branch")
        Text(status?.refName ?? "(detached HEAD)").fontDesign(.monospaced)
        Spacer()
        if !files.isEmpty {
          Button(selected.count == files.count ? "Deselect all" : "Select all") {
            excluded = selected.count == files.count ? Set(files.map(\.path)) : []
          }
          .buttonStyle(.link)
          .font(.callout)
        }
      }
      .font(.callout)
      if files.isEmpty {
        Text("No changes to commit.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
      } else {
        List(files, id: \.path) { file in
          HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { !excluded.contains(file.path) }, set: { if $0 { excluded.remove(file.path) } else { excluded.insert(file.path) } }))
              .labelsHidden()
            Text(file.path).lineLimit(1).truncationMode(.head)
            Spacer()
            Text("+\(file.insertions)").foregroundStyle(.green)
            Text("-\(file.deletions)").foregroundStyle(.red)
          }
          .font(.system(size: 12, design: .monospaced))
        }
        .frame(height: 170)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.border))
        HStack {
          Spacer()
          Text("+\(selected.reduce(0) { $0 + $1.insertions })").foregroundStyle(.green)
          Text("-\(selected.reduce(0) { $0 + $1.deletions })").foregroundStyle(.red)
        }
        .font(.system(size: 12, design: .monospaced))
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("Commit message").font(.callout.weight(.medium))
        TextEditor(text: $message)
          .font(.body)
          .scrollContentBackground(.hidden)
          .focused($messageFocused)
          .padding(6)
          .frame(height: 78)
          .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
          .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.border))
          .overlay(alignment: .topLeading) {
            if message.isEmpty { Text("Leave empty to auto-generate").foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false) }
          }
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Commit on new branch") { run(featureBranch: true, files: files, selected: selected) }.disabled(selected.isEmpty)
        // Return belongs to the message editor, so the sheet's default action is \u{2318}\u{21A9}.
        Button("Commit") { run(featureBranch: false, files: files, selected: selected) }
          .keyboardShortcut(.return, modifiers: .command)
          .buttonStyle(.borderedProminent)
          .disabled(selected.isEmpty)
      }
    }
    .padding(20)
    .frame(width: 520)
    .modifier(FollowsStatus(model: model))
    .onAppear { messageFocused = true }
  }

  private func run(featureBranch: Bool, files: [VcsStatusLocalResultWorkingTreeFilesItem], selected: [VcsStatusLocalResultWorkingTreeFilesItem]) {
    dismiss()
    store.runAction(
      context, .commit, commitMessage: message, featureBranch: featureBranch, filePaths: selected.count == files.count ? nil : selected.map(\.path),
      skipDefaultBranchPrompt: featureBranch)
  }
}

// MARK: - Default branch

struct DefaultBranchSheet: View {
  let store: SourceControlStore
  let pending: PendingGitAction
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    let status = store.statusModel(pending.context.environmentId, cwd: pending.context.cwd).status
    let copy = GitActionsLogic.defaultBranchCopy(
      action: pending.action, branch: pending.branch, includesCommit: pending.includesCommit,
      terminology: ChangeRequestTerminology(provider: status?.local.sourceControlProvider))
    VStack(alignment: .leading, spacing: 14) {
      Text(copy.title).font(.headline)
      Text(copy.description).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Abort", role: .cancel) { dismiss() }
        Button(copy.continueLabel) { go(featureBranch: false) }
        Button("Check out feature branch & continue") { go(featureBranch: true) }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 560)
  }

  private func go(featureBranch: Bool) {
    dismiss()
    store.runAction(
      pending.context, pending.action, commitMessage: pending.commitMessage, featureBranch: featureBranch, filePaths: pending.filePaths,
      skipDefaultBranchPrompt: true)
  }
}

// MARK: - Publish

struct PublishSheet: View {
  let store: SourceControlStore
  let context: GitContext
  @Environment(\.dismiss) private var dismiss
  @State private var provider = SourceControlProviderKind.github
  @State private var repository = ""
  @State private var visibility = SourceControlRepositoryVisibility.private
  @State private var transport = SourceControlCloneProtocol.ssh
  @State private var remoteName = "origin"
  @State private var working = false
  @State private var error: String?
  @State private var published: SourceControlPublishRepositoryResult?

  private static let providers: [(SourceControlProviderKind, String, String)] = [
    (.github, "GitHub", "owner/repo"), (.gitlab, "GitLab", "group/project"), (.forgejo, "Forgejo", "owner/repo"),
    (.bitbucket, "Bitbucket", "workspace/repo"), (.azureDevops, "Azure DevOps", "project/repository"),
  ]
  private var canSubmit: Bool {
    let parts = repository.trimmingCharacters(in: .whitespaces).split(separator: "/", maxSplits: 1)
    return parts.count == 2 && !parts[0].trimmingCharacters(in: .whitespaces).isEmpty && !parts[1].trimmingCharacters(in: .whitespaces).isEmpty && !working
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if let published {
        Label("Published \(published.repository.nameWithOwner)", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
        Text("Branch \(published.branch) was pushed to \(published.remoteName).").foregroundStyle(.secondary)
        HStack {
          if let url = URL(string: published.repository.url) { Button("Open repository") { NSWorkspace.shared.open(url) } }
          Spacer()
          Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
      } else {
        Text("Publish repository").font(.headline)
        Text("Create a remote repository for this project and push the current branch.").foregroundStyle(.secondary)
        Form {
          Picker("Provider", selection: $provider) { ForEach(Self.providers, id: \.0) { Text($0.1).tag($0.0) } }
          TextField("Repository", text: $repository, prompt: Text(Self.providers.first { $0.0 == provider }?.2 ?? "owner/repo"))
          Picker("Visibility", selection: $visibility) {
            Text("Private").tag(SourceControlRepositoryVisibility.private)
            Text("Public").tag(SourceControlRepositoryVisibility.public)
          }
          .pickerStyle(.segmented)
          Picker("Remote URL", selection: $transport) {
            Text("SSH").tag(SourceControlCloneProtocol.ssh)
            Text("HTTPS").tag(SourceControlCloneProtocol.https)
          }
          .pickerStyle(.segmented)
          TextField("Remote name", text: $remoteName)
        }
        .formStyle(.columns)
        if let error { Text(error).font(.callout).foregroundStyle(.red) }
        HStack {
          if working { ProgressView().controlSize(.small) }
          Spacer()
          Button("Cancel", role: .cancel) { dismiss() }
          Button("Publish", action: submit).keyboardShortcut(.defaultAction).disabled(!canSubmit)
        }
      }
    }
    .padding(20)
    .frame(width: 440)
  }

  private func submit() {
    working = true
    error = nil
    let input = SourceControlPublishRepositoryInput(
      cwd: context.cwd, provider: provider, repository: repository.trimmingCharacters(in: .whitespaces), visibility: visibility,
      remoteName: remoteName.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "origin", protocol: transport)
    Task {
      defer { working = false }
      do { published = try await store.publish(context, input) } catch { self.error = SourceControlStore.describe(error) }
    }
  }
}
