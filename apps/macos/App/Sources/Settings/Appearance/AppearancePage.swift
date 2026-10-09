import SwiftUI
import T3Contracts
import T3Theme

/// Settings › Appearance. Every control of the web page: colors and themes, contrast, glass opacity, environment
/// identification, diff colors, chat width, panel animations, typography and word wrap. All of it is device-local.
struct AppearancePage: View {
  @Environment(SettingsModel.self) private var model
  @State private var addTheme = false
  @State private var editor: ThemeEditorTarget?

  private let dc = ClientSettingsSchema()
  private var theme: AppTheme { .shared }

  var body: some View {
    ScrollViewReader { proxy in
      Form {
        Section {
          ThemeLibraryView(addTheme: $addTheme, editor: $editor).id("appearance")
        } header: { Text("Colors & themes") }
        interface
        motion
        typography
      }
      .formStyle(.grouped)
      .onChange(of: model.jump?.token) {
        guard let id = model.jump?.id else { return }
        if ["prompt-font", "terminal-font", "font-smoothing"].contains(id) { theme.typographyAdvanced = true }
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(80))
          withAnimation { proxy.scrollTo(id, anchor: .center) }
        }
      }
    }
    .sheet(isPresented: $addTheme) { AddThemeSheet() }
    .sheet(item: $editor) { ThemeEditorSheet(target: $0) }
  }

  // MARK: Helpers

  private func item(_ id: String) -> SettingsSearchItem { SettingsRegistry.items.first { $0.id == id }! }

  private func client<T: Equatable>(_ keyPath: WritableKeyPath<ClientSettingsSchema, T>) -> Binding<T> {
    Binding(get: { model.client[keyPath: keyPath] }, set: { value in model.updateClient { $0[keyPath: keyPath] = value } })
  }

  private func isDefault<T: Equatable>(_ keyPath: KeyPath<ClientSettingsSchema, T>) -> Bool { model.client[keyPath: keyPath] == dc[keyPath: keyPath] }

  private func reset<T>(_ keyPath: WritableKeyPath<ClientSettingsSchema, T>) { model.updateClient { $0[keyPath: keyPath] = dc[keyPath: keyPath] } }

  /// A value slider with the readout the web shows beside it.
  private func slider(_ binding: Binding<Int>, range: ClosedRange<Int>, step: Int, unit: String, label: String) -> some View {
    HStack(spacing: 10) {
      Text("\(binding.wrappedValue)\(unit)").monospacedDigit().font(.callout).frame(minWidth: 54).padding(.vertical, 2).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
      Slider(value: Binding(get: { Double(binding.wrappedValue) }, set: { binding.wrappedValue = Int($0.rounded()) }), in: Double(range.lowerBound)...Double(range.upperBound), step: Double(step))
        .frame(width: 170).accessibilityLabel(label)
    }
  }

  // MARK: Interface

  private var interface: some View {
    Section {
      SettingRow(
        id: "setting-appearance-contrast", title: item("setting-appearance-contrast").title, help: "Adjust the contrast of colors and borders across the interface.",
        isDefault: isDefault(\.appearanceContrast), reset: { reset(\.appearanceContrast) }
      ) { slider(client(\.appearanceContrast), range: 50...200, step: 5, unit: "%", label: "Contrast") }
      SettingRow(
        id: "setting-glass-opacity", title: item("setting-glass-opacity").title, help: "Higher values make menus, dialogs, and the composer more solid.",
        isDefault: isDefault(\.glassOpacity), reset: { reset(\.glassOpacity) }
      ) { slider(client(\.glassOpacity), range: 40...100, step: 5, unit: "%", label: "Glass opacity") }
      if theme.stageLabel != nil {
        SettingRow(
          id: "environment-identification", title: item("environment-identification").title, help: "Choose how Dev and Nightly environments are identified.",
          isDefault: isDefault(\.environmentIdentificationMode), reset: { reset(\.environmentIdentificationMode) }
        ) {
          Picker("", selection: client(\.environmentIdentificationMode)) {
            Text("Artwork").tag(ClientSettingsSchemaEnvironmentIdentificationMode.artwork)
            Text("Version pill").tag(ClientSettingsSchemaEnvironmentIdentificationMode.pill)
            Text("None").tag(ClientSettingsSchemaEnvironmentIdentificationMode.noneValue)
          }.labelsHidden().pickerStyle(.menu).fixedSize()
        }
      }
      SettingRow(
        id: "diff-color-scheme", title: item("diff-color-scheme").title, help: "Choose colors for additions and deletions, including change counts.",
        isDefault: isDefault(\.diffColorScheme), reset: { reset(\.diffColorScheme) }
      ) {
        HStack(spacing: 8) {
          let blue = model.client.diffColorScheme == .blueOrange
          HStack(spacing: 3) {
            Circle().fill(blue ? Color.orange : .red).frame(width: 8, height: 8)
            Circle().fill(blue ? Color.blue : .green).frame(width: 8, height: 8)
          }.accessibilityHidden(true)
          Picker("", selection: client(\.diffColorScheme)) {
            Text("Red & green (default)").tag(ClientSettingsSchemaDiffColorScheme.redGreen)
            Text("Blue & orange").tag(ClientSettingsSchemaDiffColorScheme.blueOrange)
          }.labelsHidden().pickerStyle(.menu).fixedSize()
        }
      }
      SettingRow(
        id: "chat-width", title: item("chat-width").title, help: "Set how wide messages and the composer can grow on large screens.",
        isDefault: isDefault(\.chatWidth), reset: { reset(\.chatWidth) }
      ) {
        Picker("", selection: client(\.chatWidth)) {
          Text("Comfortable (default)").tag(ClientSettingsSchemaChatWidth.comfortable)
          Text("Wide").tag(ClientSettingsSchemaChatWidth.wide)
          Text("Full").tag(ClientSettingsSchemaChatWidth.full)
        }.labelsHidden().pickerStyle(.menu).fixedSize()
      }
    } header: {
      Text("Interface").id("appearance-interface")
    }
  }

  // MARK: Motion

  private var motion: some View {
    Section("Motion") {
      SettingRow(
        id: "panel-animations", title: item("panel-animations").title, help: "Set how fast panels open and close. 0 ms opens them immediately.",
        isDefault: isDefault(\.panelAnimationDurationMs), reset: { reset(\.panelAnimationDurationMs) }
      ) {
        HStack(spacing: 14) {
          PanelAnimationPreview(durationMs: model.client.panelAnimationDurationMs)
          slider(client(\.panelAnimationDurationMs), range: 0...400, step: 25, unit: " ms", label: "Panel animation duration")
        }
      }
    }
  }

  // MARK: Typography

  private var typography: some View {
    @Bindable var theme = theme
    return Section {
      if theme.typographyAdvanced {
        FontFamilyRow(id: "interface-font", title: "Interface font", help: "Everything outside code blocks and the terminal.", family: \.fontFamilySans, size: \.fontSizeInterface, sizes: ThemeFonts.interfaceSize, monospaced: false)
        FontFamilyRow(id: "prompt-font", title: "Prompt font", help: "Only the box you write prompts in. Mono works well here.", family: \.fontFamilyComposer, size: \.fontSizePrompt, sizes: ThemeFonts.promptSize, monospaced: false)
        FontFamilyRow(id: "code-font", title: "Code font", help: "Code blocks, diffs, and file previews.", family: \.fontFamilyCode, size: \.fontSizeCode, sizes: ThemeFonts.codeSize, monospaced: true)
        FontFamilyRow(id: "terminal-font", title: "Terminal font", help: "Terminal output, independent from code blocks and diffs.", family: \.fontFamilyTerminal, size: \.fontSizeTerminal, sizes: ThemeFonts.terminalSize, monospaced: true)
        SettingToggleRow(
          id: "font-smoothing", title: item("font-smoothing").title, help: "Use thinner grayscale text smoothing instead of the macOS default.",
          isDefault: isDefault(\.fontSmoothing), reset: { reset(\.fontSmoothing) }, status: "Takes effect the next time the app launches.", isOn: client(\.fontSmoothing))
      } else {
        FontFamilyRow(id: "interface-font", title: "Interface font", help: "Everything outside code blocks and the terminal.", family: \.fontFamilySans, size: \.fontSizeInterface, sizes: ThemeFonts.interfaceSize, monospaced: false)
        FontFamilyRow(id: "code-font", title: "Monospace font", help: "Code blocks, diffs, file previews, and the terminal.", family: \.fontFamilyCode, size: \.fontSizeCode, sizes: ThemeFonts.codeSize, monospaced: true)
      }
      SettingToggleRow(
        id: "word-wrap", title: item("word-wrap").title, help: "Wrap long lines in code blocks, tables, diffs, and file previews by default.",
        isDefault: isDefault(\.wordWrap), reset: { reset(\.wordWrap) }, isOn: client(\.wordWrap))
    } header: {
      HStack {
        Text("Typography")
        Spacer()
        Toggle("Advanced", isOn: $theme.typographyAdvanced).toggleStyle(.switch).controlSize(.small).accessibilityLabel("Show advanced typography settings")
      }
    }
  }
}

/// What "Restore defaults" resets on this page.
@MainActor
enum AppearanceDefaults {
  private static let dc = ClientSettingsSchema()

  static func changedLabels(_ model: SettingsModel) -> [String] {
    let c = model.client
    let preference = AppTheme.shared.preference
    return [
      ("Color scheme and themes", preference != ThemePreference()), ("Contrast", c.appearanceContrast != dc.appearanceContrast),
      ("Glass opacity", c.glassOpacity != dc.glassOpacity), ("Environment identification", c.environmentIdentificationMode != dc.environmentIdentificationMode),
      ("Diff colors", c.diffColorScheme != dc.diffColorScheme), ("Chat width", c.chatWidth != dc.chatWidth),
      ("Panel animations", c.panelAnimationDurationMs != dc.panelAnimationDurationMs),
      ("Interface font", c.fontFamilySans != dc.fontFamilySans || c.fontSizeInterface != dc.fontSizeInterface),
      ("Prompt font", c.fontFamilyComposer != dc.fontFamilyComposer || c.fontSizePrompt != dc.fontSizePrompt),
      ("Code font", c.fontFamilyCode != dc.fontFamilyCode || c.fontSizeCode != dc.fontSizeCode),
      ("Terminal font", c.fontFamilyTerminal != dc.fontFamilyTerminal || c.fontSizeTerminal != dc.fontSizeTerminal),
      ("Font smoothing", c.fontSmoothing != dc.fontSmoothing), ("Word wrap", c.wordWrap != dc.wordWrap),
    ].filter(\.1).map(\.0)
  }

  static func restore(_ model: SettingsModel) {
    AppTheme.shared.setPreference(ThemePreference())
    model.updateClient { c in
      c.appearanceContrast = dc.appearanceContrast
      c.glassOpacity = dc.glassOpacity
      c.environmentIdentificationMode = dc.environmentIdentificationMode
      c.diffColorScheme = dc.diffColorScheme
      c.chatWidth = dc.chatWidth
      c.panelAnimationDurationMs = dc.panelAnimationDurationMs
      c.fontFamilySans = dc.fontFamilySans
      c.fontSizeInterface = dc.fontSizeInterface
      c.fontFamilyComposer = dc.fontFamilyComposer
      c.fontSizePrompt = dc.fontSizePrompt
      c.fontFamilyCode = dc.fontFamilyCode
      c.fontSizeCode = dc.fontSizeCode
      c.fontFamilyTerminal = dc.fontFamilyTerminal
      c.fontSizeTerminal = dc.fontSizeTerminal
      c.fontSmoothing = dc.fontSmoothing
      c.wordWrap = dc.wordWrap
    }
  }
}
