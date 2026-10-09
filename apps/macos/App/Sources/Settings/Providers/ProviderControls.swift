import AppKit
import SwiftUI
import T3ClientRuntime
import T3Contracts

/// A text field that saves when you press Return or leave it, not on every keystroke (a write is a server round trip).
struct DraftTextField: View {
  let title: String
  let value: String
  var secure = false
  var mono = false
  var width: CGFloat? = 240
  let commit: (String) -> Void
  @State private var draft = ""
  @FocusState private var focused: Bool

  var body: some View {
    Group {
      if secure { SecureField(title, text: $draft) } else { TextField(title, text: $draft) }
    }
    .labelsHidden()
    .font(mono ? .body.monospaced() : .body)
    .textFieldStyle(.roundedBorder)
    .autocorrectionDisabled()
    .frame(width: width)
    .focused($focused)
    .onSubmit(save)
    .onChange(of: focused) { if !focused { save() } }
    .onChange(of: value) { if !focused { draft = value } }
    .onAppear { draft = value }
    .onDisappear { if draft != value { commit(draft) } }
    .accessibilityLabel(title)
  }

  private func save() {
    if draft != value { commit(draft) }
  }
}

/// The driver glyph: a rounded tile with the instance's initials, tinted with its accent color.
struct ProviderGlyph: View {
  let name: String
  let accent: String?
  var size: CGFloat = 26

  var body: some View {
    let tint = accent.flatMap(Color.init(hex:)) ?? .secondary
    Text(initials)
      .font(.system(size: size * 0.4, weight: .semibold))
      .foregroundStyle(accent == nil ? Color.primary : tint)
      .frame(width: size, height: size)
      .background(tint.opacity(accent == nil ? 0.16 : 0.18), in: RoundedRectangle(cornerRadius: size * 0.28))
      .accessibilityHidden(true)
  }

  private var initials: String {
    let words = name.split { $0 == " " || $0 == "_" || $0 == "-" }.map(String.init)
    if words.count > 1 { return words.prefix(2).compactMap { $0.first.map { String($0).uppercased() } }.joined() }
    return String((words.first ?? "").prefix(2)).capitalized
  }
}

/// An account email that stays hidden until you ask for it.
struct RedactedEmail: View {
  let email: String
  @State private var revealed = false

  var body: some View {
    Button { revealed.toggle() } label: {
      Text(revealed ? email : "••••••@••••").lineLimit(1)
    }
    .buttonStyle(.plain)
    .help(revealed ? "Click to hide email" : "Click to reveal email")
    .accessibilityLabel("Account email")
    .accessibilityValue(revealed ? email : "hidden")
  }
}

/// A `#rrggbb` accent choice. The colour panel updates continuously, so a pick is saved once it settles. Only a pick by the
/// user writes: showing the saved colour never does.
struct AccentColorControl: View {
  let hex: String?
  let commit: (String?) -> Void
  @State private var picked: Color?
  @State private var pending: Task<Void, Never>?

  var body: some View {
    HStack(spacing: 6) {
      ColorPicker(
        "Accent color",
        selection: Binding(
          get: { picked ?? hex.flatMap(Color.init(hex:)) ?? .accentColor },
          set: { color in
            picked = color
            pending?.cancel()
            pending = Task {
              try? await Task.sleep(for: .milliseconds(160))
              guard !Task.isCancelled else { return }
              commit(color.hexString)
              picked = nil
            }
          }), supportsOpacity: false
      )
      .labelsHidden()
      if hex != nil {
        Button {
          pending?.cancel()
          picked = nil
          commit(nil)
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove accent color").accessibilityLabel("Remove accent color")
      }
    }
  }
}

extension Color {
  init?(hex: String) {
    guard let normalized = ProviderInstances.normalizedAccent(hex), let value = UInt32(normalized.dropFirst(), radix: 16) else { return nil }
    self.init(
      .sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255, opacity: 1)
  }

  var hexString: String {
    let color = NSColor(self).usingColorSpace(.sRGB) ?? .gray
    let channel = { (value: CGFloat) in Int((value * 255).rounded()) }
    return String(format: "#%02x%02x%02x", channel(color.redComponent), channel(color.greenComponent), channel(color.blueComponent))
  }
}

/// One driver setting (binary path, home directory, launch arguments, API key, ...), written into the instance config.
struct ProviderFieldRow: View {
  let idPrefix: String
  let field: ProviderField
  let config: JSONValue?
  let onChange: (JSONValue?) -> Void
  var inSheet = false
  @State private var invalid: String?

  var body: some View {
    if inSheet {
      VStack(alignment: .leading, spacing: 4) {
        Text(field.label).font(.callout.weight(.medium))
        control(width: nil)
        if let help = field.help { Text(help).font(.caption).foregroundStyle(.secondary) }
        if let invalid { Text(invalid).font(.caption).foregroundStyle(.red) }
      }
    } else {
      SettingRow(id: "\(idPrefix)-\(field.key)", title: field.label, help: field.help, status: invalid) { control(width: 240) }
    }
  }

  @ViewBuilder private func control(width: CGFloat?) -> some View {
    switch field.control {
    case .toggle:
      Toggle(field.label, isOn: Binding(get: { ProviderConfig.bool(config, field.key, default: field.defaultBool) }, set: { onChange(ProviderConfig.applying(.toggle($0), to: field, in: config)) }))
        .labelsHidden().toggleStyle(.switch)
    case .select:
      Picker(field.label, selection: Binding(get: { ProviderConfig.selection(config, field) }, set: { onChange(ProviderConfig.applyingSelection($0, to: field, in: config)) })) {
        ForEach(field.options, id: \.value) { Text($0.label).tag($0.value) }
      }
      .labelsHidden().pickerStyle(.menu).fixedSize()
    case .text, .password:
      DraftTextField(title: field.placeholder ?? field.label, value: ProviderConfig.string(config, field.key), secure: field.control == .password, mono: false, width: width) { text in
        invalid = field.error(for: text)
        if invalid == nil { onChange(ProviderConfig.applying(.text(text), to: field, in: config)) }
      }
    }
  }
}

/// Per-instance environment variables (API keys, base URLs). Sensitive values are stored on the server and never come back.
struct EnvironmentVariablesEditor: View {
  let environment: [ProviderInstanceEnvironmentVariable]
  let onChange: ([ProviderInstanceEnvironmentVariable]) -> Void
  @State private var rows: [ProviderInstances.EnvironmentDraft]
  @State private var published: [ProviderInstanceEnvironmentVariable]?

  init(environment: [ProviderInstanceEnvironmentVariable], onChange: @escaping ([ProviderInstanceEnvironmentVariable]) -> Void) {
    self.environment = environment
    self.onChange = onChange
    _rows = State(initialValue: environment.map { ProviderInstances.EnvironmentDraft($0) })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Variables")
          Text("API keys, base URLs, and other per-instance CLI settings.").font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Add variable", systemImage: "plus") { rows.append(ProviderInstances.EnvironmentDraft()) }
      }
      ForEach($rows) { $row in
        HStack(spacing: 6) {
          DraftTextField(title: "VARIABLE_NAME", value: row.name, mono: true, width: 170) { row.name = $0.trimmingCharacters(in: .whitespaces); publish() }
          Text("=").foregroundStyle(.secondary).accessibilityHidden(true)
          DraftTextField(
            title: row.valueRedacted == true ? "Stored secret, enter a new value to replace" : "value", value: row.valueRedacted == true ? "" : row.value,
            secure: row.sensitive, mono: true, width: nil
          ) {
            row.value = $0
            row.valueRedacted = false
            publish()
          }
          Button {
            row.sensitive.toggle()
            if !row.sensitive { row.valueRedacted = false }
            publish()
          } label: { Image(systemName: row.sensitive ? "lock.fill" : "lock.open") }
            .buttonStyle(.borderless).help(row.sensitive ? "Sensitive, stored separately" : "Plain text")
            .accessibilityLabel(row.sensitive ? "Sensitive. Mark as plain text" : "Plain text. Mark as sensitive")
          Button { rows.removeAll { $0.id == row.id }; publish() } label: { Image(systemName: "xmark") }
            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove variable").accessibilityLabel("Remove variable \(row.name)")
        }
      }
      if !rows.isEmpty {
        Text("Sensitive values are stored separately and never returned to the app.").font(.caption).foregroundStyle(.secondary)
      }
    }
    .onChange(of: environment) {
      // Follow the server unless it is just echoing what this editor saved.
      if environment != published { rows = environment.map { ProviderInstances.EnvironmentDraft($0) } }
    }
  }

  private func publish() {
    guard let next = ProviderInstances.publishedEnvironment(rows) else { return }
    published = next
    onChange(next)
  }
}
