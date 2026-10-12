import SwiftUI
import T3ClientRuntime
import T3Contracts

/// "Choose icon": a symbol, an emoji or a monogram, with a colour for the symbol and the monogram.
struct ProjectIconPickerSheet: View {
  let current: ProjectIconChoice?
  let projectName: String
  let onSelect: (ProjectIconChoice) -> Void
  @Environment(\.dismiss) private var dismiss

  private enum Mode: String, CaseIterable { case icons = "Icons", emoji = "Emoji", monogram = "Monogram" }

  @State private var mode: Mode
  @State private var iconName: String
  @State private var color: ProjectIconColor
  @State private var letters: String
  @State private var emoji: String
  @State private var query = ""
  @State private var customEmoji = ""

  init(current: ProjectIconChoice?, projectName: String, onSelect: @escaping (ProjectIconChoice) -> Void) {
    self.current = current
    self.projectName = projectName
    self.onSelect = onSelect
    let automatic = ProjectIdentity.derive(projectName)
    switch current {
    case .lucide(let name, let color):
      _mode = State(initialValue: .icons)
      _iconName = State(initialValue: name)
      _color = State(initialValue: color)
      _letters = State(initialValue: automatic.monogram)
      _emoji = State(initialValue: "💻")
    case .emoji(let value):
      _mode = State(initialValue: .emoji)
      _iconName = State(initialValue: "folder-code")
      _color = State(initialValue: automatic.color)
      _letters = State(initialValue: automatic.monogram)
      _emoji = State(initialValue: value)
    case .monogram(let text, let color):
      _mode = State(initialValue: .monogram)
      _iconName = State(initialValue: "folder-code")
      _color = State(initialValue: color)
      _letters = State(initialValue: text)
      _emoji = State(initialValue: "💻")
    case nil:
      _mode = State(initialValue: .icons)
      _iconName = State(initialValue: "folder-code")
      _color = State(initialValue: automatic.color)
      _letters = State(initialValue: automatic.monogram)
      _emoji = State(initialValue: "💻")
    }
  }

  private var monogram: String { letters.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespaces).uppercased() }
  private var canSave: Bool { mode != .monogram || ProjectIdentity.isValidMonogram(monogram) }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Choose project icon").font(.headline)
        Text("Choose an icon, emoji, or monogram.").font(.callout).foregroundStyle(.secondary)
      }
      Picker("Icon type", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
        .pickerStyle(.segmented).labelsHidden()
      if mode != .emoji { colors }
      switch mode {
      case .icons: icons
      case .emoji: emojis
      case .monogram: monogramEditor
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Save icon") {
          onSelect(mode == .icons ? .lucide(iconName, color) : mode == .emoji ? .emoji(emoji) : .monogram(monogram, color))
          dismiss()
        }
        .keyboardShortcut(.defaultAction).disabled(!canSave)
      }
    }
    .padding(20).frame(width: 480)
  }

  private var colors: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Color").font(.caption).foregroundStyle(.secondary)
      HStack(spacing: 6) {
        ForEach(ProjectIconColor.palette, id: \.rawValue) { option in
          Button { color = option } label: {
            Circle().fill(option.swiftUI).frame(width: 16, height: 16).padding(3)
              .overlay(Circle().strokeBorder(color == option ? Color.primary.opacity(0.7) : .clear, lineWidth: 1.5))
          }
          .buttonStyle(.plain).accessibilityLabel(option.title).accessibilityAddTraits(color == option ? .isSelected : [])
        }
      }
    }
  }

  private var icons: some View {
    let matches = ProjectIconOptions.filter(query)
    return VStack(alignment: .leading, spacing: 8) {
      TextField("Search icons", text: $query).textFieldStyle(.roundedBorder)
      ScrollView {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 4) {
          ForEach(matches, id: \.name) { icon in
            Button { iconName = icon.name } label: {
              Image(systemName: icon.symbol).font(.system(size: 17)).foregroundStyle(color.swiftUI)
                .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
                .background(iconName == icon.name ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain).help(ProjectIconOptions.title(icon.name)).accessibilityLabel(ProjectIconOptions.title(icon.name))
            .accessibilityAddTraits(iconName == icon.name ? .isSelected : [])
          }
        }
        .padding(2)
        if matches.isEmpty { Text("No icons found.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24) }
      }
      .frame(height: 170)
    }
  }

  private var emojis: some View {
    VStack(alignment: .leading, spacing: 8) {
      ScrollView {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 4) {
          ForEach(ProjectIconOptions.emojis, id: \.emoji) { option in
            Button { emoji = option.emoji } label: {
              Text(option.emoji).font(.system(size: 20)).frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
                .background(emoji == option.emoji ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain).help(option.label).accessibilityLabel(option.label)
          }
        }
        .padding(2)
      }
      .frame(height: 140)
      TextField("Or paste any emoji", text: $customEmoji).textFieldStyle(.roundedBorder)
        .onChange(of: customEmoji) { if let first = Self.firstEmoji(customEmoji) { emoji = first } }
    }
  }

  private var monogramEditor: some View {
    HStack(spacing: 16) {
      ProjectMonogram(text: ProjectIdentity.isValidMonogram(monogram) ? monogram : ProjectIdentity.monogram(projectName), color: color, size: 48)
      VStack(alignment: .leading, spacing: 4) {
        Text("Letters").font(.callout.weight(.medium))
        TextField("Letters", text: $letters).labelsHidden().textFieldStyle(.roundedBorder)
        Text("One or two letters or numbers.").font(.caption).foregroundStyle(ProjectIdentity.isValidMonogram(monogram) ? Color.secondary : Color.red)
      }
    }
    .padding(.vertical, 8)
  }

  /// The first emoji in pasted text, ignoring digits and punctuation that merely have an emoji form.
  static func firstEmoji(_ text: String) -> String? {
    text.first { $0.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0xFF) } }.map(String.init)
  }
}

/// "Choose file": an image from the project's own checkout, found with the server's file search.
struct ProjectFaviconPickerSheet: View {
  let runtime: ClientRuntime
  let environmentId: EnvironmentId
  let cwd: String
  let projectName: String
  let onSelect: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var entries: [ProjectEntry] = []
  @State private var message: String? = "Indexing project files\u{2026}"

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Choose project icon").font(.headline)
        Text("Pick an image from \(projectName).").font(.callout).foregroundStyle(.secondary)
      }
      TextField("Search image files\u{2026}", text: $query).textFieldStyle(.roundedBorder)
      List(entries, id: \.path) { entry in
        Button {
          onSelect(entry.path)
          dismiss()
        } label: {
          VStack(alignment: .leading, spacing: 1) {
            Text((entry.path as NSString).lastPathComponent)
            Text(entry.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
          }
          .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      .overlay { if let message { Text(message).foregroundStyle(.secondary) } }
      .frame(height: 260)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
      }
    }
    .padding(20).frame(width: 480)
    .task(id: query) {
      if !query.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
      guard !Task.isCancelled else { return }
      guard let session = await runtime.runtime(for: environmentId)?.supervisor.session.value else {
        message = "Connect this environment to browse its files."
        return
      }
      do {
        let result = try await session.call(Rpc.projectsSearchEntries, ProjectSearchEntriesInput(cwd: cwd, query: query, limit: 40, imageOnly: true))
        guard !Task.isCancelled else { return }
        entries = result.entries.filter { $0.kind == .file }
        message = entries.isEmpty ? (query.isEmpty ? "No image files found." : "No matching image files.") : nil
      } catch {
        if !Task.isCancelled { message = SourceControlStore.describe(error) }
      }
    }
  }
}
