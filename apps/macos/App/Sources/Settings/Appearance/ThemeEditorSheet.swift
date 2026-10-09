import AppKit
import SwiftUI
import T3Theme

/// The create/edit sheet. The guided view generates a whole palette from a background and an accent; the advanced view edits
/// each role family. Both paint the draft on the live app while the sheet is open, and Cancel puts the saved theme back.
struct ThemeEditorSheet: View {
  let target: ThemeEditorTarget
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var active: ThemeAppearance
  @State private var colors: [ThemeAppearance: ThemeColors]
  @State private var touched: Set<ThemeAppearance>
  @State private var advanced: Bool
  @State private var filter = ""
  @State private var error: String?

  init(target: ThemeEditorTarget) {
    self.target = target
    let source = target.editing ?? target.seed
    _name = State(initialValue: target.editing?.label ?? target.seedName ?? "")
    var initial: [ThemeAppearance: ThemeColors] = [:]
    for appearance in ThemeAppearance.allCases {
      initial[appearance] = ThemeFile.canonicalized(source?.colors(for: appearance) ?? ThemePalette.standardColors(appearance))
    }
    _colors = State(initialValue: initial)
    let start = source?.colors(for: target.appearance) != nil ? target.appearance : (source?.appearance ?? target.appearance)
    _active = State(initialValue: start)
    _touched = State(initialValue: target.editing != nil ? Set(source?.modes ?? [start]) : (source == nil ? [start] : Set(source!.modes)))
    // Only a palette the guided editor generated is safe to regenerate; anything else opens in advanced mode.
    _advanced = State(initialValue: source != nil && source?.managed != true)
  }

  private var isEditing: Bool { target.editing != nil }
  private var current: ThemeColors { colors[active]! }

  private static let groups: [(title: String, families: [(label: String, role: ThemeRole, roles: [ThemeRole])])] = [
    ("Foundation", [
      ("Background", .canvas, [.canvas, .chrome, .toolbar]), ("Surface", .surface, [.surface]), ("Raised surface", .surfaceRaised, [.surfaceRaised]),
      ("Overlay", .surfaceOverlay, [.surfaceOverlay]), ("Text", .text, [.text, .toolbarForeground, .toolbarControlForeground]),
      ("Muted text", .mutedForeground, [.textMuted, .mutedForeground, .placeholder, .secondaryLabel, .iconMuted, .sidebarMutedForeground]),
      ("Border", .border, [.border, .toolbarBorder, .sidebarBorder]), ("Input", .input, [.input]),
    ]),
    ("Brand & content", [
      ("Subtle surface", .secondary, [.secondary, .secondaryForeground, .muted, .toolbarControl]),
      ("Highlight surface", .accentSurface, [.accentSurface, .accentSurfaceForeground, .toolbarControlHover]),
      ("Accent", .accent, [.accent, .accentForeground, .focus, .update, .updateForeground, .updateSurface, .terminalCursor]),
      ("Action", .messageAction, [.messageAction, .messageActionForeground, .messageActionHover]),
      ("Message surface", .messageSurface, [.messageSurface, .messageForeground]), ("Code surface", .codeBackground, [.codeBackground, .codeForeground]),
    ]),
    ("Context", [
      ("Sidebar background", .sidebar, [.sidebar, .sidebarForeground]), ("Sidebar controls", .sidebarControlSurface, [.sidebarControlSurface]),
      ("Sidebar selection", .sidebarRowSelected, [.sidebarRowHover, .sidebarRowActive, .sidebarRowSelected]),
      ("Terminal background", .terminalBackground, [.terminalBackground, .terminalForeground, .terminalSelection, .terminalScrollbar, .terminalScrollbarHover]),
    ]),
    ("Status", [
      ("Error", .error, [.error, .errorForeground, .errorSurface]), ("Warning", .warning, [.warning, .warningForeground, .warningSurface]),
    ]),
  ]

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(isEditing ? "Edit theme" : "Create theme").font(.headline)
        Spacer()
      }.padding([.horizontal, .top], 20).padding(.bottom, 8)
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          TextField("Theme name", text: $name, prompt: Text("e.g. Aurora")).textFieldStyle(.roundedBorder)
          Picker("Appearance", selection: $active) {
            ForEach(ThemeAppearance.allCases, id: \.self) { Text($0 == .light ? "Light" : "Dark").tag($0) }
          }.pickerStyle(.segmented)
          if let note = lockNote { Text(note).font(.caption).foregroundStyle(.secondary) }
          ThemeWireframe(colors: current).aspectRatio(2.2, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.12)))
          Toggle("Advanced colors", isOn: $advanced).toggleStyle(.switch)
          if advanced { advancedColors } else { guidedColors }
          if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        }.padding(.horizontal, 20).padding(.bottom, 12)
      }
      Divider()
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button(isEditing ? "Save changes" : "Create theme") { save() }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
      }.padding(14)
    }
    .frame(width: 520, height: 640)
    .task(id: PreviewKey(colors: current, appearance: active)) { AppTheme.shared.previewDraft(current, appearance: active) }
    .onDisappear { AppTheme.shared.clearDraft() }
  }

  private struct PreviewKey: Hashable {
    var colors: ThemeColors
    var appearance: ThemeAppearance
  }

  /// Why an appearance cannot take a palette here (the web's `appearanceLockReason`).
  private var lockNote: String? {
    guard let editing = target.editing, !editing.modes.contains(active) else { return nil }
    return "\u{201C}\(editing.label)\u{201D} has no \(active.rawValue) palette yet; saving adds one."
  }

  // MARK: Guided

  private var guidedColors: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Pick two colors; the rest of the palette is generated and contrast-checked.").font(.callout).foregroundStyle(.secondary)
      colorRow("Background", role: .canvas)
      colorRow("Accent", role: .accent)
    }
  }

  // MARK: Advanced

  private var advancedColors: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField("Filter colors", text: $filter).textFieldStyle(.roundedBorder)
      ForEach(Self.groups, id: \.title) { group in
        let families = group.families.filter { filter.isEmpty || $0.label.localizedCaseInsensitiveContains(filter) || $0.roles.contains { $0.rawValue.localizedCaseInsensitiveContains(filter) } }
        if !families.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text(group.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(families, id: \.role) { family in colorRow(family.label, role: family.role) }
          }
        }
      }
    }
  }

  private func colorRow(_ label: String, role: ThemeRole) -> some View {
    HStack {
      Text(label)
      Spacer()
      Text(ThemeColorMath.hex(current[role]) ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
      ColorPicker(label, selection: binding(role), supportsOpacity: false).labelsHidden()
    }
  }

  private func binding(_ role: ThemeRole) -> Binding<Color> {
    Binding(
      get: { Color(css: current[role]) },
      set: { color in
        let srgb = NSColor(color).usingColorSpace(.sRGB) ?? .black
        let hex = ThemeColorMath.hex(ThemeRGB(r: srgb.redComponent * 255, g: srgb.greenComponent * 255, b: srgb.blueComponent * 255))
        update(role, hex)
      })
  }

  private func update(_ role: ThemeRole, _ value: String) {
    guard ThemeColorMath.isThemeColor(value) else { return }
    if advanced {
      colors[active] = ThemePalette.updateFamily(active, current, role: role, value: value)
    } else {
      let background = role == .canvas ? value : current[.canvas]
      let accent = role == .accent ? value : current[.accent]
      colors[active] = ThemeFile.canonicalized(ThemePalette.vivid(active, background: background, accent: accent))
    }
    touched.insert(active)
    error = nil
  }

  // MARK: Save

  private func save() {
    let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let app = AppTheme.shared
    do {
      let edited = target.editing
      let wanted = ThemeAppearance.allCases.filter { touched.contains($0) }
      let id = edited?.id ?? ThemeIds.fromName(label)
      // A name an installed theme already uses combines instead of failing: the new palette joins that theme.
      let existing = edited ?? app.customThemes.first { $0.id == id || $0.label.lowercased() == label.lowercased() }
      if edited == nil, let existing {
        let taken = wanted.filter { existing.modes.contains($0) }
        if !taken.isEmpty { throw ThemeError("\u{201C}\(existing.label)\u{201D} already has a \(taken[0].rawValue) palette.") }
      }
      var palettes: [ThemeAppearance: ThemeColors] = [:]
      for appearance in existing?.modes ?? [] { palettes[appearance] = existing?.colors(for: appearance) }
      for appearance in wanted { palettes[appearance] = colors[appearance]! }
      let base = existing.map { $0.modes.contains($0.appearance) ? $0.appearance : wanted[0] } ?? wanted.first ?? active
      let variants = palettes.filter { $0.key != base }
      let theme = try ThemeFile.make(
        id: existing?.id ?? id, name: label, appearance: base, colors: palettes[base] ?? current, variants: variants,
        managed: existing == nil ? !advanced : (existing!.managed && !advanced))
      var saved = theme
      saved.collection = existing?.collection
      if existing != nil { try app.update(saved) } else { try app.install(saved) }
      if edited == nil { app.use(saved.id) }
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}
