import SwiftUI
import T3ClientRuntime
import T3Contracts

/// Step 3: the directories Claude Code or Codex has used, grouped by repository. Browsing only scans; nothing is
/// created or imported until the footer's Import button.
struct ImportStep: View {
  @Environment(AppModel.self) private var app
  @State private var otherExpanded = false

  var body: some View {
    let model = app.onboarding
    let scans = model.connected.compactMap { status in model.scans[status.environmentId].map { (status, $0) } }
    let (repositories, other) = ProjectImportLogic.group(model.candidates)
    Form {
      Section {
        StepHeader(
          title: "Choose your projects",
          text: "Kestrel found directories that Claude Code or Codex has used. Imported projects include their conversations from the last 30 days, so you can continue them here.")
      }
      if model.scanning && model.candidates.isEmpty {
        Section { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking for your projects\u{2026}").foregroundStyle(.secondary) } }
      }
      ForEach(scans, id: \.0.environmentId) { status, scan in
        if let failure = scan.failure { Section(status.label) { Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) } }
        if scan.truncated {
          Section(status.label) { Text("The history is large, so some projects or conversations may be missing.").foregroundStyle(.secondary) }
        }
      }
      if !repositories.isEmpty {
        Section {
          HStack {
            Button("Select all") { model.setSelection(Set(model.candidates.map(\.id))) }
            Button("Select none") { model.setSelection([]) }
            Spacer()
            Text("\(model.selected.count) of \(model.candidates.count) selected").foregroundStyle(.secondary).font(.callout)
          }
          .buttonStyle(.link)
          ForEach(repositories) { group in GroupRow(group: group, multipleComputers: scans.count > 1) }
        }
      }
      if !other.isEmpty {
        Section {
          DisclosureGroup("Other folders (\(other.count))", isExpanded: $otherExpanded) {
            ForEach(other) { item in
              CandidateToggle(candidate: item, title: item.candidate.path, subtitle: Self.activity(item.candidate.threadCount, item.candidate.lastActiveAt))
            }
          }
        }
      }
      if !model.scanning && model.candidates.isEmpty && scans.allSatisfy({ $0.1.failure == nil }) {
        Section { Text("No agent history was found. You can add projects later from the command palette.").foregroundStyle(.secondary) }
      }
      if let progress = model.importProgress {
        Section { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(progress).lineLimit(1) } }
      }
      if let warning = model.importWarning {
        Section { Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
      }
    }
    .formStyle(.grouped)
    .disabled(model.importing)
    .task { model.scanAll() }
  }

  static func activity(_ threads: Int, _ last: IsoDateTime?) -> String {
    let count = "\(threads) \(threads == 1 ? "conversation" : "conversations")"
    guard let date = last?.date else { return count }
    return "\(count) \u{00B7} \(date.formatted(.relative(presentation: .named)))"
  }
}

/// One repository: a toggle for all of its clones.
private struct GroupRow: View {
  @Environment(AppModel.self) private var app
  let group: ImportGroup
  let multipleComputers: Bool

  var body: some View {
    let model = app.onboarding
    let ids = Set(group.candidates.map(\.id))
    Toggle(
      isOn: Binding(
        get: { ids.isSubset(of: model.selection) },
        set: { on in model.setSelection(on ? model.selection.union(ids) : model.selection.subtracting(ids)) })
    ) {
      VStack(alignment: .leading, spacing: 1) {
        Text(group.label)
        Text(ImportStep.activity(group.threadCount, group.lastActiveAt) + (group.candidates.count > 1 ? " \u{00B7} \(group.candidates.count) checkouts" : ""))
          .font(.caption).foregroundStyle(.secondary)
        if group.candidates.count == 1, let item = group.candidates.first {
          Text(multipleComputers ? "\(app.environmentLabel(item.environmentId)) \u{00B7} \(item.candidate.path)" : item.candidate.path)
            .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
        }
      }
    }
    .toggleStyle(.checkbox)
  }
}

private struct CandidateToggle: View {
  @Environment(AppModel.self) private var app
  let candidate: ImportCandidate
  let title: String
  let subtitle: String

  var body: some View {
    let model = app.onboarding
    Toggle(
      isOn: Binding(
        get: { model.selection.contains(candidate.id) },
        set: { on in model.setSelection(on ? model.selection.union([candidate.id]) : model.selection.subtracting([candidate.id])) })
    ) {
      VStack(alignment: .leading, spacing: 1) {
        Text(title).lineLimit(1).truncationMode(.middle)
        Text(subtitle).font(.caption).foregroundStyle(.secondary)
      }
    }
    .toggleStyle(.checkbox)
  }
}
