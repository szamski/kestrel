import SwiftUI
import T3Contracts
import T3Timeline

/// The approval request that replaces the editor until it is answered.
struct ComposerApprovalPanel: View {
  let model: ComposerModel
  let approval: ApprovalPrompt

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text("PENDING APPROVAL").font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(.orange)
        Text(approval.panelLabel).font(.system(size: 12, weight: .medium))
        if model.pendingApprovalCount > 1 {
          Text("1/\(model.pendingApprovalCount)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
        }
        Spacer()
      }
      if let appName = approval.appName { Text(appName).font(.system(size: 12)).foregroundStyle(.secondary) }
      Text(approval.displayDetail)
        .font(approval.detailIsCode ? .system(size: 12, design: .monospaced) : .system(size: 12.5))
        .lineLimit(5)
        .textSelection(.enabled)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .accessibilityLabel(approval.detailLabel)
        .accessibilityValue(approval.displayDetail)
      ForEach(Array(approval.resolvedOptions.enumerated()), id: \.offset) { _, option in
        if let warning = option.warning { Label(warning, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(.orange) }
      }
    }
    .padding(.horizontal, 14)
    .padding(.top, 12)
    .padding(.bottom, 4)
    .accessibilityElement(children: .contain)
  }
}

/// Footer controls of an approval: Decline / Approve, and the remaining decisions in a menu.
struct ComposerApprovalActions: View {
  let model: ComposerModel
  let approval: ApprovalPrompt

  var body: some View {
    let busy = model.respondingRequestIds.contains(approval.id)
    HStack(spacing: 8) {
      if !approval.moreOptions.isEmpty {
        Menu {
          ForEach(Array(approval.moreOptions.enumerated()), id: \.offset) { _, option in
            Button(option.label) { Task { await model.respondToApproval(option.decision) } }
          }
        } label: {
          Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("More approval options")
      }
      ForEach(Array(approval.primaryOptions.enumerated()), id: \.offset) { _, option in
        if option.decision == .accept {
          Button(option.label) { Task { await model.respondToApproval(option.decision) } }
            .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
        } else {
          Button(option.label) { Task { await model.respondToApproval(option.decision) } }
            .buttonStyle(.bordered)
        }
      }
    }
    .controlSize(.regular)
    .disabled(busy)
  }
}

/// The question the agent is waiting on: options (1-9 keys), a free-text answer in the editor.
struct ComposerUserInputPanel: View {
  let model: ComposerModel
  let prompt: UserInputPrompt

  var body: some View {
    if let progress = model.userInputProgress, let question = progress.activeQuestion {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Text(question.header.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
          Spacer()
          if prompt.questions.count > 1 {
            Text("\(progress.questionIndex + 1)/\(prompt.questions.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
          }
          if prompt.dismissible {
            Button { Task { await model.dismissUserInput() } } label: { Image(systemName: "xmark") }
              .buttonStyle(.borderless).help("Dismiss").accessibilityLabel("Dismiss question")
          }
        }
        Text(question.question).font(.system(size: 13.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
        VStack(spacing: 4) {
          ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
            let value = option.value ?? option.label
            let selected = progress.selectedOptionValues.contains(value)
            Button { model.selectUserInputOption(questionId: question.id, value: value) } label: {
              HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(index + 1)").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.secondary).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                  Text(option.label).font(.system(size: 13, weight: .medium))
                  if !option.description.isEmpty { Text(option.description).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.leading) }
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: question.multiSelect ? "checkmark.square.fill" : "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
              }
              .padding(.horizontal, 10).padding(.vertical, 6)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04)))
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(index < 9 ? KeyEquivalent(Character("\(index + 1)")) : "0", modifiers: [])
            .accessibilityAddTraits(selected ? .isSelected : [])
          }
        }
      }
      .padding(.horizontal, 14)
      .padding(.top, 12)
      .padding(.bottom, 4)
      .accessibilityElement(children: .contain)
    }
  }
}

/// Footer controls of a question: Back, then Next or Submit.
struct ComposerUserInputActions: View {
  let model: ComposerModel
  let prompt: UserInputPrompt

  var body: some View {
    if let progress = model.userInputProgress {
      let busy = model.respondingRequestIds.contains(prompt.id)
      HStack(spacing: 8) {
        if progress.questionIndex > 0 { Button("Back") { model.previousUserInputQuestion() }.buttonStyle(.bordered) }
        Button(progress.isLastQuestion ? "Submit answers" : "Next") { Task { await model.advanceUserInput() } }
          .buttonStyle(.borderedProminent).disabled(!progress.canAdvance || busy)
          .keyboardShortcut(.return, modifiers: .command)
      }
    }
  }
}
