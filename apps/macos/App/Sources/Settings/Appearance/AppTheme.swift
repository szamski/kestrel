import AppKit
import Observation
import SwiftUI
import T3Composer
import T3ClientRuntime
import T3Contracts
import T3Markdown
import T3Terminal
import T3Theme

/// The theme the whole app follows: the library (built-ins, saved themes, themes the environment publishes), the preference,
/// and the palette resolved from them plus the Appearance settings. One refresh turns those inputs into everything the
/// surfaces read: `Palette` colors for SwiftUI chrome, the `MarkdownTheme` (timeline, code, files, diffs), the terminal theme,
/// the composer style and fonts. Reads register with Observation, so views repaint when the theme changes.
@MainActor @Observable
final class AppTheme {
  static let shared = AppTheme(directory: AppModel.dataDirectory)

  // MARK: Inputs

  private(set) var preference = ThemePreference()
  private(set) var customThemes: [ThemeDefinition] = []
  private(set) var environmentThemes: [ThemeDefinition] = []
  /// Saved theme files that could not be read, for the page to show.
  private(set) var libraryIssues: [String] = []
  /// An unsaved editor draft painted on the live app; nil when no editor is open.
  private(set) var draft: Draft?

  struct Draft: Equatable {
    var colors: ThemeColors
    var appearance: ThemeAppearance
  }

  // MARK: Outputs

  private(set) var resolved: ResolvedTheme
  private(set) var revision = 0
  private var palette: [ThemeRole: NSColor] = [:]
  private(set) var markdown: MarkdownTheme = .light
  private(set) var terminalTheme: TerminalTheme = .dark
  private(set) var terminalFont = TerminalFont()
  private(set) var composerStyle = ComposerEditorStyle()
  /// Set only when the interface font differs from the system default, so a default setup keeps the native look.
  private(set) var interfaceFont: Font?
  private(set) var panelAnimation: Animation?

  /// Whether the "Typography › Advanced" overrides (separate prompt and terminal fonts) are on.
  var typographyAdvanced: Bool {
    didSet {
      guard typographyAdvanced != oldValue else { return }
      UserDefaults.standard.set(typographyAdvanced, forKey: Self.typographyKey)
      refresh()
    }
  }

  @ObservationIgnored private let store: ThemeLibraryStore
  @ObservationIgnored private let preferenceURL: URL?
  @ObservationIgnored private var inputs: Inputs?
  @ObservationIgnored private var started = false
  @ObservationIgnored private var systemDark: Bool
  @ObservationIgnored private var settingsTask: Task<Void, Never>?
  @ObservationIgnored private var runtimeTask: Task<Void, Never>?
  @ObservationIgnored private var systemObserver: NSObjectProtocol?
  @ObservationIgnored private var environmentThemeSource: [PublishedTheme] = []
  private static let typographyKey = "appearance.typographyAdvanced"

  /// `directory: nil` keeps everything in memory (previews, tests).
  init(directory: URL?) {
    store = ThemeLibraryStore(directory: directory?.appending(path: "themes", directoryHint: .isDirectory))
    preferenceURL = directory?.appending(path: "appearance.json")
    typographyAdvanced = UserDefaults.standard.bool(forKey: Self.typographyKey)
    systemDark = Self.isSystemDark()
    resolved = ThemeResolver.resolve(ThemePreference(), systemDark: false, library: ThemeDefinition.builtIns)
    if let preferenceURL, let data = try? Data(contentsOf: preferenceURL), let stored = try? JSONDecoder().decode(ThemePreference.self, from: data) {
      preference = stored
    }
    #if DEBUG
    // Verification runs: `-T3Theme <id> -T3ThemeMode light|dark|system` wear a theme without touching the saved preference.
    if let id = UserDefaults.standard.string(forKey: "T3Theme") {
      preference = ThemePreference(mode: ThemeMode(rawValue: UserDefaults.standard.string(forKey: "T3ThemeMode") ?? "") ?? .system, light: id, dark: id)
    }
    #endif
    reloadLibrary()
  }

  // MARK: Lifecycle

  /// Applies the stored appearance before the first window is shown, then keeps following the system and the Appearance
  /// settings.
  func start() {
    guard !started else { return }
    started = true
    refresh()
    systemObserver = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.systemDark = Self.isSystemDark()
        self?.refresh()
      }
    }
    settingsTask = Task { @MainActor [weak self] in
      for await _ in Observations({ ClientSettingsStore.shared.client }) { self?.refresh() }
    }
  }

  /// Follows the themes the primary environment publishes (`environmentThemesUpdated`).
  func observeEnvironment(runtime: ClientRuntime) {
    guard runtimeTask == nil else { return }
    runtimeTask = Task { @MainActor [weak self] in
      for await themes in Observations({ Self.publishedThemes(runtime) }) { self?.setEnvironmentThemes(themes) }
    }
  }

  private static func isSystemDark() -> Bool { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" }

  /// The themes of the environment whose server runs on this Mac (the web follows its own server the same way).
  private static func publishedThemes(_ runtime: ClientRuntime) -> [PublishedTheme] {
    let local = runtime.environments.map(\.environmentId).first { id in
      ["localhost", "127.0.0.1", "::1", "[::1]"].contains(runtime.connectionEntry(id)?.httpBaseURL.host(percentEncoded: false) ?? "")
    }
    guard let local, let themes = runtime.serverConfigs[local]?.config.environmentThemes else { return [] }
    return themes.map { theme in
      PublishedTheme(
        id: theme.id, name: theme.name, appearance: theme.appearance == .dark ? .dark : .light, canvas: theme.canvas, accent: theme.accent,
        colors: theme.colors,
        variants: [.light: theme.variants?.light, .dark: theme.variants?.dark].compactMapValues { $0 })
    }
  }

  // MARK: Library

  /// Built-ins first, then saved themes, then the environment's: a saved theme beats a published one with the same id.
  var library: [ThemeDefinition] {
    var seen = Set<String>()
    return (ThemeDefinition.builtIns + customThemes + environmentThemes).filter { seen.insert($0.id).inserted }
  }

  func definition(_ id: String) -> ThemeDefinition? { ThemeResolver.definition(id, library: library) }

  func reloadLibrary() {
    let loaded = store.load()
    customThemes = loaded.themes
    libraryIssues = loaded.issues
    refresh()
  }

  func setEnvironmentThemes(_ published: [PublishedTheme]) {
    guard published != environmentThemeSource else { return }
    environmentThemeSource = published
    environmentThemes = PublishedTheme.definitions(published)
    refresh()
  }

  /// Saves a new theme file. Throws when the id is reserved or taken, or the write fails.
  @discardableResult
  func install(_ theme: ThemeDefinition) throws -> ThemeDefinition {
    if ThemeIds.reserved.contains(theme.id) { throw ThemeError("The theme id \"\(theme.id)\" is reserved.") }
    if customThemes.contains(where: { $0.id == theme.id }) { throw ThemeError("A theme named \"\(theme.label)\" is already installed.") }
    try store.write(theme)
    customThemes.append(theme)
    refresh()
    return theme
  }

  func update(_ theme: ThemeDefinition) throws {
    guard let index = customThemes.firstIndex(where: { $0.id == theme.id }) else { throw ThemeError("The theme \"\(theme.label)\" is not installed.") }
    try store.write(theme)
    customThemes[index] = theme
    refresh()
  }

  /// Replaces every theme of an Open VSX extension with a fresh install of it.
  func replaceCollection(_ collectionId: String, with themes: [ThemeDefinition]) throws {
    let others = Set(customThemes.filter { $0.collection?.id != collectionId }.map(\.id))
    if let clash = themes.first(where: { others.contains($0.id) || ThemeIds.reserved.contains($0.id) }) {
      throw ThemeError("A theme named \"\(clash.label)\" is already installed.")
    }
    let old = customThemes.filter { $0.collection?.id == collectionId }.map(\.id)
    for theme in themes { try store.write(theme) }
    try store.remove(old.filter { id in !themes.contains { $0.id == id } })
    customThemes.removeAll { $0.collection?.id == collectionId }
    customThemes.append(contentsOf: themes)
    refresh()
  }

  func installedCollection(_ id: String) -> [ThemeDefinition] { customThemes.filter { $0.collection?.id == id } }

  /// Removes saved themes; a preference that named one falls back to the standard look.
  func remove(_ ids: [String]) throws {
    try store.remove(ids)
    customThemes.removeAll { ids.contains($0.id) }
    var next = preference
    if let light = next.light, ids.contains(light) { next.light = nil }
    if let dark = next.dark, ids.contains(dark) { next.dark = nil }
    setPreference(next)
  }

  // MARK: Preference

  func setPreference(_ next: ThemePreference) {
    guard next != preference else { return }
    preference = next
    if let preferenceURL, let data = try? JSONEncoder().encode(next) {
      try? FileManager.default.createDirectory(at: preferenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? data.write(to: preferenceURL, options: .atomic)
    }
    refresh()
  }

  func setMode(_ mode: ThemeMode) { var next = preference; next.mode = mode; setPreference(next) }

  /// Picks `id` (nil is the standard look) for the given appearances. A theme that renders only one appearance also moves the
  /// mode to it, since the other would not show it.
  func use(_ id: String?, for appearances: [ThemeAppearance] = ThemeAppearance.allCases) {
    var next = preference
    let theme = id.flatMap(definition)
    for appearance in appearances { next.setOwner(theme?.id, of: appearance) }
    if let theme, let only = theme.singleAppearance, appearances.count == 2 { next.mode = ThemeMode(rawValue: only.rawValue) ?? next.mode }
    setPreference(next)
  }

  /// System, light, dark, system: the `appearance.cycle` command.
  func cycleMode() {
    let order: [ThemeMode] = [.system, .light, .dark]
    setMode(order[((order.firstIndex(of: preference.mode) ?? 0) + 1) % order.count])
  }

  // MARK: Editor preview

  func previewDraft(_ colors: ThemeColors, appearance: ThemeAppearance) {
    let next = Draft(colors: colors, appearance: appearance)
    guard next != draft else { return }
    draft = next
    refresh()
  }

  func clearDraft() {
    guard draft != nil else { return }
    draft = nil
    refresh()
  }

  // MARK: Reading

  func nsColor(_ role: ThemeRole) -> NSColor { palette[role] ?? .clear }
  func color(_ role: ThemeRole) -> Color { Color(nsColor: nsColor(role)) }

  /// Only a chosen theme paints the sidebar and toolbar; the standard look keeps the native glass chrome.
  var paintsChrome: Bool { !resolved.isStandard || draft != nil }

  var glassOpacity: Double { Double(ClientSettingsStore.shared.client.glassOpacity) / 100 }

  /// "Dev" in Debug builds: the stage the Environment identification setting is about.
  var stageLabel: String? {
    #if DEBUG
    "Dev"
    #else
    nil
    #endif
  }

  // MARK: Refresh

  private struct Inputs: Equatable {
    var preference: ThemePreference
    var library: [ThemeDefinition]
    var draft: Draft?
    var systemDark: Bool
    var contrast: Int
    var diffScheme: String
    var fonts: [String]
    var sizes: [Int]
    var panelMs: Int
    var chatWidth: String
  }

  /// Re-derives everything from the inputs; a no-op when none changed.
  func refresh() {
    let client = ClientSettingsStore.shared.client
    let advanced = typographyAdvanced
    let inputs = Inputs(
      preference: preference, library: customThemes + environmentThemes, draft: draft, systemDark: systemDark,
      contrast: client.appearanceContrast, diffScheme: client.diffColorScheme.rawValue,
      fonts: [client.fontFamilySans, client.fontFamilyComposer, client.fontFamilyCode, advanced ? client.fontFamilyTerminal : client.fontFamilyCode],
      sizes: [client.fontSizeInterface, client.fontSizePrompt, client.fontSizeCode, advanced ? client.fontSizeTerminal : client.fontSizeCode],
      panelMs: client.panelAnimationDurationMs, chatWidth: client.chatWidth.rawValue)
    guard inputs != self.inputs else { return }
    self.inputs = inputs

    if let draft {
      let colors = ThemeFile.canonicalized(draft.colors)
      resolved = ResolvedTheme(
        appearance: draft.appearance, themeId: "__preview",
        colors: inputs.contrast == 100 ? colors : ThemeContrast.apply(colors, percent: inputs.contrast, appearance: draft.appearance), sidebarArtwork: false)
    } else {
      resolved = ThemeResolver.resolve(preference, systemDark: systemDark, library: library, contrast: inputs.contrast)
    }
    palette = Dictionary(uniqueKeysWithValues: ThemeRole.allCases.map { ($0, Self.nsColor(resolved.colors[$0])) })

    let fonts = FontSet(client: client, advanced: advanced)
    markdown = makeMarkdown(fonts)
    terminalTheme = TerminalTheme(
      background: nsColor(.terminalBackground), foreground: nsColor(.terminalForeground), cursor: nsColor(.terminalCursor),
      selection: nsColor(.terminalSelection), isDark: resolved.appearance == .dark)
    terminalFont = TerminalFont(family: AppearanceFonts.resolvedFamily(fonts.terminalFamily) ?? "", size: fonts.terminalSize)
    composerStyle = ComposerEditorStyle(
      fontSize: CGFloat(fonts.promptSize), fontFamily: AppearanceFonts.resolvedFamily(fonts.promptFamily),
      textColor: nsColor(.text), fill: color(.surface).opacity(glassOpacity),
      stroke: color(.border))
    interfaceFont = fonts.swiftUIFont
    panelAnimation =
      client.panelAnimationDurationMs > 0 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      ? .easeInOut(duration: Double(client.panelAnimationDurationMs) / 1000) : nil

    let codeFont = AppearanceFonts.font(fonts.codeFamily, size: CGFloat(fonts.codeSize), monospaced: true)
    ThemeOverrides.shared.install(
      markdown: markdown, diff: client.diffColorScheme == .blueOrange ? .blueOrange : .redGreen, codeFont: codeFont)
    // Grayscale smoothing without the system's stem darkening is `AppleFontSmoothing = 0`; unset restores the platform default.
    if client.fontSmoothing { UserDefaults.standard.set(0, forKey: "AppleFontSmoothing") } else { UserDefaults.standard.removeObject(forKey: "AppleFontSmoothing") }
    NSApplication.shared.appearance = NSAppearance(named: resolved.appearance == .dark ? .darkAqua : .aqua)
    revision += 1
  }

  private static func nsColor(_ css: String) -> NSColor {
    guard let parsed = ThemeColorMath.parse(css) else { return .clear }
    let rgb = ThemeColorMath.srgbComponents(parsed.color)
    return NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: parsed.alpha)
  }

  private struct FontSet {
    var interfaceFamily: String, promptFamily: String, codeFamily: String, terminalFamily: String
    var interfaceSize: Int, promptSize: Int, codeSize: Int, terminalSize: Int

    init(client: ClientSettingsSchema, advanced: Bool) {
      interfaceFamily = client.fontFamilySans
      // The prompt follows the interface font until it has its own.
      promptFamily = client.fontFamilyComposer.isEmpty ? client.fontFamilySans : client.fontFamilyComposer
      codeFamily = client.fontFamilyCode
      terminalFamily = ThemeFonts.terminalFamily(advanced: advanced, code: client.fontFamilyCode, terminal: client.fontFamilyTerminal)
      interfaceSize = ThemeFonts.clamp(client.fontSizeInterface, to: ThemeFonts.interfaceSize)
      promptSize = ThemeFonts.clamp(client.fontSizePrompt, to: ThemeFonts.promptSize)
      codeSize = ThemeFonts.clamp(client.fontSizeCode, to: ThemeFonts.codeSize)
      terminalSize = ThemeFonts.terminalSize(advanced: advanced, code: codeSize, terminal: ThemeFonts.clamp(client.fontSizeTerminal, to: ThemeFonts.terminalSize))
    }

    /// The web's 16px interface size is the app's 14pt reading size; the system's own 13pt chrome moves with it.
    var bodySize: CGFloat { CGFloat(interfaceSize - 2) }

    var swiftUIFont: Font? {
      let family = AppearanceFonts.resolvedFamily(interfaceFamily)
      guard family != nil || interfaceSize != ThemeFonts.defaultInterfaceSize else { return nil }
      let size = CGFloat(13 + interfaceSize - ThemeFonts.defaultInterfaceSize)
      return family.map { .custom($0, size: size) } ?? .system(size: size)
    }
  }

  private func makeMarkdown(_ fonts: FontSet) -> MarkdownTheme {
    let dark = resolved.appearance == .dark
    var theme = dark ? MarkdownTheme.t3ChatDark(bodySize: fonts.bodySize) : MarkdownTheme.t3ChatLight(bodySize: fonts.bodySize)
    theme.bodyFont = AppearanceFonts.font(fonts.interfaceFamily, size: fonts.bodySize, monospaced: false)
    theme.codeFont = AppearanceFonts.font(fonts.codeFamily, size: CGFloat(fonts.codeSize), monospaced: true)
    theme.foreground = nsColor(.text)
    theme.muted = nsColor(.textMuted)
    theme.link = nsColor(.updateForeground)
    theme.codeBackground = nsColor(.codeBackground)
    theme.codeForeground = nsColor(.codeForeground)
    theme.border = nsColor(.border)
    theme.quoteBar = nsColor(.input)
    theme.tableHeaderBackground = nsColor(.secondary)
    theme.chipBackground = nsColor(.accentSurface)
    theme.chipForeground = nsColor(.accentSurfaceForeground)
    theme.syntax[.plain] = nsColor(.codeForeground)
    return theme
  }
}
