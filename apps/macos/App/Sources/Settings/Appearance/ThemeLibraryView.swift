import AppKit
import SwiftUI
import T3Theme
import UniformTypeIdentifiers

/// What the editor sheet opens with: a saved theme to edit, or a seed (the current look, another theme) for a new one.
struct ThemeEditorTarget: Identifiable {
  let id = UUID()
  var editing: ThemeDefinition?
  var seed: ThemeDefinition?
  var seedName: String?
  var appearance: ThemeAppearance
}

/// Settings › Appearance › Colors & themes: the appearance mode tiles, then every theme as a card. The standard T3 Code look,
/// the built-ins, the themes saved on this Mac and the ones this Mac's server publishes.
struct ThemeLibraryView: View {
  @Binding var addTheme: Bool
  @Binding var editor: ThemeEditorTarget?
  @State private var removal: Removal?
  @State private var notice: String?

  private struct Removal: Identifiable {
    var theme: ThemeDefinition
    var siblings: [ThemeDefinition]
    var id: String { theme.id }
  }

  private var theme: AppTheme { .shared }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      modeTiles
      HStack(spacing: 10) {
        Button("Create theme", systemImage: "plus") { editor = ThemeEditorTarget(seed: nil, seedName: nil, appearance: theme.resolved.appearance) }
        Button("Add theme\u{2026}", systemImage: "square.and.arrow.down") { addTheme = true }
        Spacer()
      }
      if let notice { Text(notice).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
      if !theme.libraryIssues.isEmpty {
        DisclosureGroup("\(theme.libraryIssues.count) saved theme file\(theme.libraryIssues.count == 1 ? "" : "s") could not be read") {
          ForEach(theme.libraryIssues, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }.font(.callout)
      }
      cards("Built in", themes: [nil] + ThemeDefinition.builtIns.map { Optional($0) })
      if !theme.customThemes.isEmpty { cards("Your themes", themes: theme.customThemes.map { Optional($0) }) }
      if !theme.environmentThemes.isEmpty {
        cards("From this Mac\u{2019}s server", themes: theme.environmentThemes.map { Optional($0) })
      }
    }
    .padding(.vertical, 4)
    .confirmationDialog(
      removal.map { $0.siblings.count > 1 ? "Remove themes?" : "Remove \u{201C}\($0.theme.label)\u{201D}?" } ?? "", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
      titleVisibility: .visible, presenting: removal
    ) { target in
      Button(target.siblings.count > 1 ? "Remove \(target.theme.label)" : "Remove theme", role: .destructive) { remove([target.theme.id]) }
      if target.siblings.count > 1 {
        Button("Remove all \(target.siblings.count) in \(target.theme.collection?.label ?? "this collection")", role: .destructive) { remove(target.siblings.map(\.id)) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("The theme file is deleted from this Mac.")
    }
  }

  // MARK: Mode tiles

  private var modeTiles: some View {
    HStack(spacing: 12) {
      ForEach(ThemeMode.allCases, id: \.self) { mode in
        let active = theme.preference.mode == mode
        Button { theme.setMode(mode) } label: {
          VStack(spacing: 6) {
            modePreview(mode).aspectRatio(1.9, contentMode: .fit)
              .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
              .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.12)))
            Text(mode == .system ? "System" : mode == .light ? "Light" : "Dark").font(.callout.weight(active ? .semibold : .regular))
          }
          .padding(8)
          .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(active ? Color.accentColor.opacity(0.12) : .clear))
          .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(active ? Color.accentColor : .primary.opacity(0.1), lineWidth: active ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode == .system ? "Follow the system appearance" : "Use \(mode.rawValue) mode")
        .accessibilityAddTraits(active ? .isSelected : [])
      }
    }
  }

  private func palette(_ appearance: ThemeAppearance) -> ThemeColors {
    let resolved = ThemeResolver.resolve(
      ThemePreference(mode: ThemeMode(rawValue: appearance.rawValue)!, light: theme.preference.light, dark: theme.preference.dark), systemDark: appearance == .dark,
      library: theme.library)
    return resolved.colors
  }

  @ViewBuilder private func modePreview(_ mode: ThemeMode) -> some View {
    switch mode {
    case .light: ThemeWireframe(colors: palette(.light))
    case .dark: ThemeWireframe(colors: palette(.dark))
    case .system:
      ZStack {
        ThemeWireframe(colors: palette(.light))
        ThemeWireframe(colors: palette(.dark)).mask(HStack(spacing: 0) { Color.clear; Color.black })
      }
    }
  }

  // MARK: Cards

  private func cards(_ title: String, themes: [ThemeDefinition?]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12, alignment: .top)], spacing: 12) {
        ForEach(Array(themes.enumerated()), id: \.offset) { _, definition in card(definition) }
      }
    }
  }

  private func card(_ definition: ThemeDefinition?) -> some View {
    let id = definition?.id
    let light = definition == nil ? ThemePalette.standardColors(.light) : definition?.colors(for: .light)
    let dark = definition == nil ? ThemePalette.standardColors(.dark) : definition?.colors(for: .dark)
    let owns = ThemeAppearance.allCases.filter { theme.preference.owner(of: $0) == id }
    let active = owns.contains(theme.resolved.appearance)
    let isCustom = definition.map { d in theme.customThemes.contains { $0.id == d.id } } ?? false
    return VStack(alignment: .leading, spacing: 6) {
      ThemeCardPreview(light: light, dark: dark)
      HStack(spacing: 6) {
        Text(definition?.label ?? "T3 Code").font(.callout.weight(.medium)).lineLimit(1)
        Spacer(minLength: 0)
        ForEach(owns, id: \.self) { appearance in
          Image(systemName: appearance == .light ? "sun.max.fill" : "moon.fill").imageScale(.small).foregroundStyle(.secondary)
            .help("Used in \(appearance.rawValue) mode")
        }
        Menu {
          menuItems(definition, light: light != nil, dark: dark != nil, isCustom: isCustom)
        } label: { Image(systemName: "ellipsis.circle") }
          .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Actions for \(definition?.label ?? "T3 Code")")
      }
      if let collection = definition?.collection { Text(collection.label).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
    }
    .padding(8)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(active ? Color.accentColor.opacity(0.1) : .clear))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(active ? Color.accentColor : .primary.opacity(0.1), lineWidth: active ? 2 : 1))
    .contentShape(RoundedRectangle(cornerRadius: 12))
    .onTapGesture { theme.use(id) }
    .contextMenu { menuItems(definition, light: light != nil, dark: dark != nil, isCustom: isCustom) }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(definition?.label ?? "T3 Code") theme\(active ? ", in use" : "")")
    .accessibilityAddTraits(.isButton)
  }

  @ViewBuilder private func menuItems(_ definition: ThemeDefinition?, light: Bool, dark: Bool, isCustom: Bool) -> some View {
    let id = definition?.id
    Button("Use") { theme.use(id) }
    if light { Button("Use for light mode") { theme.use(id, for: [.light]) } }
    if dark { Button("Use for dark mode") { theme.use(id, for: [.dark]) } }
    Divider()
    Button("Duplicate\u{2026}") {
      editor = ThemeEditorTarget(seed: definition, seedName: "\(definition?.label ?? "T3 Code") copy", appearance: theme.resolved.appearance)
    }
    if let definition, isCustom { Button("Edit\u{2026}") { editor = ThemeEditorTarget(editing: definition, seed: definition, appearance: definition.modes.contains(theme.resolved.appearance) ? theme.resolved.appearance : definition.appearance) } }
    if let definition {
      Button("Export theme file\u{2026}") { export(definition) }
      if isCustom {
        Divider()
        Button("Remove\u{2026}", role: .destructive) {
          removal = Removal(theme: definition, siblings: definition.collection.map { theme.installedCollection($0.id) } ?? [definition])
        }
      }
    }
  }

  // MARK: Actions

  private func remove(_ ids: [String]) {
    do {
      try theme.remove(ids)
      notice = nil
    } catch {
      notice = "Could not remove the theme. \(error.localizedDescription)"
    }
  }

  private func export(_ definition: ThemeDefinition) {
    var file = definition
    // A built-in id is reserved; the exported copy takes a free one so it imports back.
    if ThemeIds.reserved.contains(file.id) { file.id = "\(file.id)-copy" }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "\(file.id).json"
    panel.allowedContentTypes = [.json]
    panel.message = "Export \(definition.label) as a T3 Code theme file"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try Data(try ThemeFile.serialize(file).utf8).write(to: url, options: .atomic)
      notice = nil
    } catch {
      notice = "Could not export the theme. \(error.localizedDescription)"
    }
  }
}
