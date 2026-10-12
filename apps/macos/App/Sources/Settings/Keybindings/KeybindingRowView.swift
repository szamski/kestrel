import SwiftUI
import T3Contracts
import T3Keybindings

/// One binding: command and condition on the left, the shortcut on the right. Clicking the shortcut records a new one; Save
/// appears once the key or the condition differs from the server's.
struct KeybindingRowView: View {
  let controller: KeybindingsController
  let row: KeybindingRow
  let all: [KeybindingRow]
  let anchored: Bool
  @State private var keyDraft: String
  @State private var whenDraft: String
  @State private var whenOpen = false
  @State private var confirmRemove = false

  init(controller: KeybindingsController, row: KeybindingRow, all: [KeybindingRow], anchored: Bool) {
    self.controller = controller
    self.row = row
    self.all = all
    self.anchored = anchored
    _keyDraft = State(initialValue: row.key)
    _whenDraft = State(initialValue: row.when)
  }

  private var draft: KeybindingCatalog.WhenDraft { KeybindingCatalog.whenDraft(whenDraft) }
  private var whenExpression: String? {
    switch draft {
    case .empty: ""
    case .valid(_, let expression, _): expression
    case .invalid: nil
    }
  }
  private var keyIsValid: Bool { KeybindingParser.shortcut(keyDraft.trimmingCharacters(in: .whitespaces)) != nil }
  private var isDirty: Bool { keyDraft != row.key || (whenExpression ?? whenDraft) != row.when }
  private var recording: Bool { controller.recordingId == row.id }
  private var saving: Bool { controller.savingIds.contains(row.id) }
  private var canSave: Bool { isDirty && keyIsValid && whenExpression != nil && !saving }
  private var showPill: Bool { !recording && !isDirty && !row.key.isEmpty }
  private var conflicts: [String] { KeybindingCatalog.conflictLabels(all, id: row.id, key: keyDraft, when: whenExpression ?? whenDraft) }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(KeybindingCatalog.label(row.command)).help(row.command.rawValue)
          if row.source != .default { KeybindingBadge(text: row.source.rawValue) }
        }
        whenControl
      }
      Spacer(minLength: 8)
      if !conflicts.isEmpty {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).imageScale(.small)
          .help("Also used by \(conflicts.joined(separator: ", "))").accessibilityLabel("Conflicts with \(conflicts.joined(separator: ", "))")
      }
      keyControl
      menu
    }
    .padding(.vertical, 2)
    .background(highlight)
    .id(anchored ? KeybindingCatalog.anchor(row.command) : row.id)
    .onDisappear { if recording { controller.stopRecording() } }
    .confirmationDialog("Remove this keybinding?", isPresented: $confirmRemove) {
      Button("Remove", role: .destructive) { Task { await controller.remove(row) } }
    } message: {
      Text("\(KeybindingCatalog.label(row.command)) loses \(row.key).")
    }
  }

  private var highlight: some View {
    RoundedRectangle(cornerRadius: 6).fill(controller.model.highlightedRow == KeybindingCatalog.anchor(row.command) && anchored ? Color.accentColor.opacity(0.18) : .clear)
      .padding(.horizontal, -6).padding(.vertical, -3)
  }

  // MARK: When

  private var whenControl: some View {
    Button { whenOpen = true } label: {
      HStack(spacing: 4) {
        Text("When").foregroundStyle(.tertiary)
        Text(whenDraft.isEmpty ? "Always" : whenDraft).font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
        Image(systemName: "chevron.down").imageScale(.small).opacity(0.6)
      }
      .font(.caption).foregroundStyle(whenDraft.isEmpty ? .secondary : .primary)
    }
    .buttonStyle(.borderless)
    .accessibilityLabel("Edit when clause for \(KeybindingCatalog.label(row.command))")
    .popover(isPresented: $whenOpen, arrowEdge: .bottom) { KeybindingWhenEditor(text: $whenDraft).padding(14).frame(width: 340) }
  }

  // MARK: Key

  @ViewBuilder private var keyControl: some View {
    if isDirty || recording { Button(saving ? "Saving" : "Save") { save() }.disabled(!canSave) }
    if isDirty && !recording { Button("Cancel") { revert() }.buttonStyle(.borderless) }
    if showPill, let shortcut = row.rule?.shortcut {
      Button { record() } label: { KeybindingPill(text: Keybindings.label(shortcut)) }
        .buttonStyle(.plain).help("Click, then press a new shortcut")
        .accessibilityLabel("Edit shortcut for \(KeybindingCatalog.label(row.command)): \(Keybindings.label(shortcut))")
    } else {
      HStack(spacing: 4) {
        TextField("", text: recording ? .constant("") : $keyDraft, prompt: Text(recording ? "Press shortcut" : "Unassigned"))
          .labelsHidden().textFieldStyle(.roundedBorder).font(.system(.callout, design: .monospaced)).frame(width: 150)
          .foregroundStyle(keyDraft.isEmpty || keyIsValid ? Color.primary : Color.red)
          .disabled(recording).accessibilityLabel("Keybinding for \(KeybindingCatalog.label(row.command))")
          .onSubmit { if canSave { save() } }
        Button(recording ? "Stop" : "Record") { recording ? controller.stopRecording() : record() }
      }
    }
  }

  private func record() {
    controller.startRecording(row.id, onKey: { keyDraft = $0 }, onCancel: { keyDraft = row.key })
  }

  private func revert() {
    keyDraft = row.key
    whenDraft = row.when
  }

  private func save() {
    guard let expression = whenExpression else { return }
    let input = ServerUpsertKeybindingInput(
      key: keyDraft.trimmingCharacters(in: .whitespaces), command: row.command, when: expression.isEmpty ? nil : expression,
      replace: row.rule == nil ? nil : controller.removeTarget(row))
    Task { await controller.upsert(input, rowId: row.id) }
  }

  // MARK: Menu

  @ViewBuilder private var menu: some View {
    if row.canReset || row.canRemove {
      Menu {
        if row.canReset { Button("Reset to default") { Task { await controller.reset(row) } } }
        if row.canRemove { Button("Remove", role: .destructive) { confirmRemove = true } }
      } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(saving)
        .accessibilityLabel("Actions for \(KeybindingCatalog.label(row.command))")
    }
  }
}

/// The condition as text, validated against the parser while typing; variables can be inserted from the menu.
struct KeybindingWhenEditor: View {
  @Binding var text: String

  var body: some View {
    let draft = KeybindingCatalog.whenDraft(text)
    VStack(alignment: .leading, spacing: 8) {
      Text("When").font(.headline)
      TextField("Always", text: $text, prompt: Text("terminalFocus && !previewFocus"))
        .textFieldStyle(.roundedBorder).font(.system(.callout, design: .monospaced)).autocorrectionDisabled()
      switch draft {
      case .invalid:
        Label("Use variables with !, &&, ||, and parentheses.", systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
      case .valid(_, _, let unknown) where !unknown.isEmpty:
        Label("\(unknown.joined(separator: ", ")) \(unknown.count == 1 ? "is" : "are") not a known variable and evaluates to false.", systemImage: "exclamationmark.triangle.fill")
          .font(.caption).foregroundStyle(.orange)
      case .valid, .empty:
        Text("Leave empty to apply everywhere. ! is not, && is and, || is or.").font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Menu("Insert variable") {
          ForEach(KeybindingCatalog.whenVariables, id: \.self) { name in Button(name) { insert(name) } }
        }.fixedSize()
        Button("Negate") { text = text.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "!(\(text.trimmingCharacters(in: .whitespaces)))" }
          .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        Spacer()
        Button("Clear") { text = "" }.disabled(text.isEmpty)
      }
    }
  }

  private func insert(_ name: String) {
    let current = text.trimmingCharacters(in: .whitespaces)
    text = current.isEmpty ? name : "\(current) && \(name)"
  }
}

struct KeybindingPill: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(.callout, design: .rounded).weight(.medium)).monospacedDigit()
      .padding(.horizontal, 8).padding(.vertical, 3)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
  }
}

struct KeybindingBadge: View {
  let text: String

  var body: some View {
    Text(text).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
      .overlay(Capsule().strokeBorder(.secondary.opacity(0.5))).foregroundStyle(.secondary)
  }
}

/// The form behind "Add keybinding": any command, a recorded or typed key, an optional condition.
struct NewKeybindingRow: View {
  let controller: KeybindingsController
  let all: [KeybindingRow]
  @State private var command: KeybindingCommand?
  @State private var keyDraft = ""
  @State private var whenDraft = ""
  @State private var whenOpen = false

  private var whenExpression: String? {
    switch KeybindingCatalog.whenDraft(whenDraft) {
    case .empty: ""
    case .valid(_, let expression, _): expression
    case .invalid: nil
    }
  }
  private var keyIsValid: Bool { KeybindingParser.shortcut(keyDraft.trimmingCharacters(in: .whitespaces)) != nil }
  private var recording: Bool { controller.recordingId == "new" }
  private var saving: Bool { controller.savingIds.contains("new") }
  private var conflicts: [String] { KeybindingCatalog.conflictLabels(all, id: "new", key: keyDraft, when: whenExpression ?? whenDraft) }

  var body: some View {
    let options = KeybindingCatalog.commandOptions(controller.rules)
    VStack(alignment: .leading, spacing: 10) {
      Picker("Command", selection: $command) {
        Text("Choose a command").tag(KeybindingCommand?.none)
        ForEach(options, id: \.rawValue) { Text(KeybindingCatalog.label($0)).tag(KeybindingCommand?.some($0)) }
      }
      HStack {
        TextField("Shortcut", text: recording ? .constant("") : $keyDraft, prompt: Text(recording ? "Press shortcut" : "mod+shift+k"))
          .font(.system(.body, design: .monospaced)).disabled(recording)
          .foregroundStyle(keyDraft.isEmpty || keyIsValid ? Color.primary : Color.red)
        Button(recording ? "Stop" : "Record") {
          if recording { controller.stopRecording() } else { controller.startRecording("new", onKey: { keyDraft = $0 }, onCancel: {}) }
        }
      }
      HStack {
        Button { whenOpen = true } label: {
          HStack(spacing: 4) {
            Text("When").foregroundStyle(.secondary)
            Text(whenDraft.isEmpty ? "Always" : whenDraft).font(.system(.callout, design: .monospaced)).lineLimit(1)
            Image(systemName: "chevron.down").imageScale(.small).opacity(0.6)
          }
        }
        .buttonStyle(.borderless).popover(isPresented: $whenOpen, arrowEdge: .bottom) { KeybindingWhenEditor(text: $whenDraft).padding(14).frame(width: 340) }
        Spacer()
        if !conflicts.isEmpty { Label("Also used by \(conflicts.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
      }
      HStack {
        Spacer()
        Button("Cancel") {
          controller.stopRecording()
          controller.isAdding = false
        }
        Button(saving ? "Saving" : "Save") { save() }.keyboardShortcut(.defaultAction)
          .disabled(command == nil || !keyIsValid || whenExpression == nil || saving)
      }
    }
    .onDisappear { if recording { controller.stopRecording() } }
  }

  private func save() {
    guard let command, let expression = whenExpression else { return }
    let input = ServerUpsertKeybindingInput(key: keyDraft.trimmingCharacters(in: .whitespaces), command: command, when: expression.isEmpty ? nil : expression)
    Task { if await controller.upsert(input, rowId: "new") { controller.isAdding = false } }
  }
}
