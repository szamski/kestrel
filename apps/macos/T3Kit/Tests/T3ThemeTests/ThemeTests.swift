import Foundation
import Testing

@testable import T3Theme

private func fixture(_ name: String) throws -> Data {
  try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)"))
}

private struct Oracle: Decodable {
  struct Vivid: Decodable { var appearance: String, canvas: String, accent: String, colors: [String: String] }
  struct Canonical: Decodable { var input: String, canonical: String, hex: String }
  struct Serialized: Decodable { var serialized: String }
  var vivid: [Vivid]
  var canonical: [Canonical]
  var vscode: Serialized
  var grove: String
  var updateAccent: [String: String]

  static func load() throws -> Oracle { try JSONDecoder().decode(Oracle.self, from: fixture("oracle.json")) }
}

private func table(_ colors: ThemeColors) -> [String: String] {
  Dictionary(uniqueKeysWithValues: ThemeRole.allCases.map { ($0.rawValue, colors[$0]) })
}

/// The expected values come from the web implementation (`scripts/theme-oracle/oracle.ts`), so these are parity checks, not
/// self-consistency checks.
@Suite struct PaletteParityTests {
  @Test func canonicalColorsMatchTheWeb() throws {
    for item in try Oracle.load().canonical {
      #expect(ThemeColorMath.canonical(item.input) == item.canonical, "\(item.input)")
      #expect(ThemeColorMath.hex(item.input) == item.hex, "\(item.input)")
    }
  }

  @Test func vividPalettesMatchTheWeb() throws {
    for input in try Oracle.load().vivid {
      let colors = ThemePalette.vivid(ThemeAppearance(rawValue: input.appearance)!, background: input.canvas, accent: input.accent)
      let actual = table(colors)
      let wrong = actual.filter { $0.value != input.colors[$0.key] }.keys.sorted()
      #expect(wrong.isEmpty, "\(input.canvas)/\(input.accent) differs in \(wrong)")
      #expect(actual.count == ThemeRole.allCases.count && actual.count == input.colors.count)
    }
  }

  @Test func familyUpdateMatchesTheWeb() throws {
    let oracle = try Oracle.load()
    let base = ThemePalette.vivid(.dark, background: "#1a1b26", accent: "#7aa2f7")
    let updated = ThemePalette.updateFamily(.dark, base, role: .accent, value: "#e0af68")
    let wrong = table(updated).filter { $0.value != oracle.updateAccent[$0.key] }.keys.sorted()
    #expect(wrong.isEmpty, "differs in \(wrong)")
  }

  @Test func vsCodeImportMatchesTheWeb() throws {
    let source = try #require(try JSONC.parseObject(String(decoding: fixture("sample-vscode-theme.json"), as: UTF8.self), description: "sample"))
    #expect(VSCodeThemeImport.isVSCodeTheme(source))
    let theme = try VSCodeThemeImport.parse(source)
    #expect(theme.label == "Tokyo Night Storm" && theme.appearance == .dark)
    #expect(try ThemeFile.serialize(theme) == (try Oracle.load().vscode.serialized))
  }
}

@Suite struct ThemeFileTests {
  @Test func builtInExportMatchesTheWebByteForByte() throws {
    #expect(try ThemeFile.serialize(.grove) == (try Oracle.load().grove))
  }

  @Test func roundTrip() throws {
    for theme in ThemeDefinition.builtIns {
      // Built-ins are reserved ids; export under a user id like Duplicate does.
      var copy = theme
      copy.id = "copy-\(theme.id)"
      copy.sidebarArtwork = false
      let json = try ThemeFile.serialize(copy)
      let back = try ThemeFile.parse(data: Data(json.utf8))
      #expect(back.id == copy.id && back.label == copy.label && back.appearance == copy.appearance)
      #expect(back.colors == ThemeFile.canonicalized(copy.colors))
      #expect(back.variants == copy.variants.mapValues(ThemeFile.canonicalized))
      #expect(try ThemeFile.serialize(back) == json)
    }
  }

  @Test func rejectsBadFiles() throws {
    func parse(_ json: String, lenient: Bool = false) throws -> ThemeDefinition { try ThemeFile.parse(data: Data(json.utf8), lenient: lenient) }
    #expect(throws: ThemeError("This theme file uses an unsupported version. Expected 1.")) {
      try parse(##"{"version":2,"name":"x","appearance":"dark","colors":{"text":"#fff"}}"##)
    }
    #expect(throws: ThemeError("The theme id \"dark\" is reserved.")) {
      try parse(##"{"version":1,"name":"Dark","appearance":"dark","colors":{"text":"#fff"}}"##)
    }
    #expect(throws: ThemeError("\"nope\" is not a supported theme color role.")) {
      try parse(##"{"version":1,"name":"X","appearance":"dark","colors":{"nope":"#fff"}}"##)
    }
    #expect(throws: ThemeError("Add at least one color role to the theme file.")) {
      try parse(##"{"version":1,"name":"X","appearance":"dark","colors":{}}"##)
    }
    // Files from another build keep their usable colors when read leniently.
    let lenient = try parse(##"{"version":1,"name":"X","appearance":"dark","colors":{"nope":"#fff","text":"#abcdef","accent":"banana"}}"##, lenient: true)
    #expect(lenient.colors[.text] == ThemeColorMath.canonical("#abcdef"))
    #expect(lenient.colors[.accent] == ThemePalette.defaultColors(.dark)[.accent])
  }

  @Test func idsFollowTheWebRules() {
    #expect(ThemeIds.fromName("  Tokyo Night — Storm!  ") == "tokyo-night-storm")
    #expect(ThemeIds.fromName("***") == "custom-theme")
    #expect(ThemeIds.isValid("a-1") && !ThemeIds.isValid("-a") && !ThemeIds.isValid("A") && !ThemeIds.isValid(String(repeating: "a", count: 49)))
    #expect(ThemeIds.normalize("t3-grove") == "grove")
  }

  @Test func publishedThemesFollowTheWebRules() {
    let seeded = PublishedTheme(id: "nightfall", name: "Nightfall", appearance: .dark, canvas: "#1a1b26", accent: "#7aa2f7", colors: ["error": "#f7768e", "bogus": "x"])
    let definitions = PublishedTheme.definitions([seeded, PublishedTheme(id: "dark", name: "Dark", appearance: .dark, canvas: "#000", accent: "#fff"), PublishedTheme(id: "empty", name: "Empty", appearance: .dark)])
    #expect(definitions.map(\.id) == ["nightfall"])
    #expect(definitions[0].colors[.error] == ThemeColorMath.canonical("#f7768e"))
    #expect(definitions[0].colors[.canvas] == ThemePalette.vivid(.dark, background: "#1a1b26", accent: "#7aa2f7")[.canvas])
    #expect(!definitions[0].managed)  // explicit role overrides: the guided editor would discard them
  }
}

@Suite struct ResolutionTests {
  @Test func standardLookWhenNothingIsPicked() {
    let resolved = ThemeResolver.resolve(ThemePreference(mode: .dark), systemDark: false, library: ThemeDefinition.builtIns)
    #expect(resolved.isStandard && resolved.appearance == .dark)
    #expect(resolved.colors[.canvas] == ThemeColorMath.canonical("#0a0a0a"))
  }

  @Test func systemModeFollowsTheSystemAndHalvesPickThemes() {
    let preference = ThemePreference(mode: .system, light: "grove", dark: "ocean")
    #expect(ThemeResolver.resolve(preference, systemDark: false, library: ThemeDefinition.builtIns).themeId == "grove")
    let dark = ThemeResolver.resolve(preference, systemDark: true, library: ThemeDefinition.builtIns)
    #expect(dark.themeId == "ocean" && dark.appearance == .dark)
  }

  @Test func singleAppearanceThemeForcesItsOwnAppearance() throws {
    let darkOnly = try ThemeFile.make(name: "Night", appearance: .dark, colors: ThemePalette.vivid(.dark, background: "#101010", accent: "#ff8800"))
    let resolved = ThemeResolver.resolve(ThemePreference(mode: .light, light: darkOnly.id), systemDark: false, library: [darkOnly])
    #expect(resolved.appearance == .dark && resolved.themeId == "night")
  }

  @Test func contrastLeavesOneHundredAloneAndMovesTextAndBorders() {
    let base = ThemeResolver.resolve(ThemePreference(mode: .light), systemDark: false, library: [])
    #expect(base.colors == ThemeFile.canonicalized(ThemePalette.standardColors(.light)))
    let black = ThemeRGB(r: 0, g: 0, b: 0)
    let canvas = ThemeColorMath.rgb(base.colors[.canvas], fallback: black)
    func ratio(_ colors: ThemeColors, _ role: ThemeRole) -> Double {
      let c = ThemeColorMath.parse(colors[role])!
      // Borders may be translucent: judge what lands on the canvas.
      let over = ThemeColorMath.mix(canvas, ThemeColorMath.toRGB(c.color), c.alpha)
      return ThemeColorMath.contrastRatio(over, canvas)
    }
    let high = ThemeResolver.resolve(ThemePreference(mode: .light), systemDark: false, library: [], contrast: 200).colors
    let low = ThemeResolver.resolve(ThemePreference(mode: .light), systemDark: false, library: [], contrast: 50).colors
    for role in [ThemeRole.text, .textMuted, .border] {
      #expect(ratio(high, role) > ratio(base.colors, role), "\(role) at 200%")
      #expect(ratio(low, role) < ratio(base.colors, role), "\(role) at 50%")
    }
  }
}

@Suite struct JSONCTests {
  @Test func commentsTrailingCommasAndStringsThatLookLikeComments() throws {
    let object = try JSONC.parseObject(
      """
      \u{FEFF}{
        // line comment
        "url": "https://example.com/a//b", /* block */
        "list": [1, 2, 3,],
        "nested": { "x": "/* not a comment */", },
      }
      """, description: "t")
    #expect(object["url"] as? String == "https://example.com/a//b")
    #expect((object["list"] as? [Int]) == [1, 2, 3])
    #expect((object["nested"] as? [String: String])?["x"] == "/* not a comment */")
    #expect(throws: ThemeError("t is not valid JSON.")) { try JSONC.parseObject("{ nope }", description: "t") }
  }
}
