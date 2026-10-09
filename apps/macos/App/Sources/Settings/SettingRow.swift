import SwiftUI
import T3ClientRuntime
import T3Contracts

/// One setting: title and help on the left, the control on the right, a reset arrow when the value is not the default.
/// Server rows (`keys` not empty) follow the scope target: they go inert without a connected target, or when a project
/// scope cannot override them, and show where the value comes from.
struct SettingRow<Control: View>: View {
  @Environment(SettingsModel.self) private var model
  let id: String
  let title: String
  var help: String?
  /// Server setting keys this row edits. Empty for a device preference.
  var keys: [String] = []
  /// Whether the shown value is the built-in default (hides the reset arrow).
  var isDefault = true
  var reset: (() -> Void)?
  var status: String?
  @ViewBuilder var control: Control

  var body: some View {
    let state = model.rowState(keys)
    let projectScope = model.scope.isProject && !keys.isEmpty
    let overridden = projectScope && model.isOverridden(keys)
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(title)
          if overridden {
            resetButton(help: "Reset to inherited value") { model.clearOverrides(keys) }
          } else if !projectScope, !isDefault, state == .editable, let reset {
            resetButton(help: "Reset to default", action: reset)
          }
        }
        if let help { Text(help).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        if let note = note(state: state, overridden: overridden) {
          Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 12)
      control
        .disabled(state != .editable)
        .opacity(state == .editable ? 1 : 0.5)
    }
    .padding(.vertical, 2)
    .background(highlight)
    .id(id)
  }

  private func note(state: SettingsModel.RowState, overridden: Bool) -> String? {
    switch state {
    case .noTarget: return "Reconnect the selected environment to change this setting."
    case .environmentWide: return "Environment-wide setting. Select an environment to change it."
    case .editable: break
    }
    if let status { return status }
    if !keys.isEmpty, model.isMixed(keys) { return "Mixed across the selected targets. Choosing a value applies it to all of them." }
    if model.scope.isProject, !keys.isEmpty { return overridden ? "Overridden for this project." : "Inherited from the environment." }
    return nil
  }

  private var highlight: some View {
    RoundedRectangle(cornerRadius: 6).fill(model.highlightedRow == id ? Color.accentColor.opacity(0.18) : .clear)
      .padding(.horizontal, -6).padding(.vertical, -3)
  }

  private func resetButton(help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: "arrow.uturn.backward").imageScale(.small) }
      .buttonStyle(.borderless).foregroundStyle(.secondary).help(help).accessibilityLabel("\(help): \(title)")
  }
}

/// A switch row. `isOn` reads and writes the value; `reset` restores the default.
struct SettingToggleRow: View {
  let id: String
  let title: String
  var help: String?
  var keys: [String] = []
  var isDefault = true
  var reset: (() -> Void)?
  var status: String?
  @Binding var isOn: Bool

  var body: some View {
    SettingRow(id: id, title: title, help: help, keys: keys, isDefault: isDefault, reset: reset, status: status) {
      Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
    }
  }
}
