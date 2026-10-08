import Foundation
import T3Contracts

public typealias ProviderSkill = ServerConfigProvidersItemSkillsItem
public typealias ProviderSlashCommand = ServerConfigProvidersItemSlashCommandsItem

/// Port of `packages/client-runtime/src/providerSkills.ts` and `apps/web/src/providerSkillSearch.ts`.
public enum ProviderSkills {
  public enum SourceKind: String, Sendable { case app, repo, project, personal, system, other }

  private static func titleCaseWords(_ value: String) -> String {
    var words: [String] = []
    var current = ""
    func flush() {
      if let first = current.first { words.append(first.uppercased() + current.dropFirst()) }
      current = ""
    }
    for character in value {
      if character == ":" || character == "_" || character == "-" || character.isWhitespace { flush() } else { current.append(character) }
    }
    flush()
    return words.joined(separator: " ")
  }

  public static func displayName(_ skill: ProviderSkill) -> String {
    if let name = skill.displayName?.jsTrim(), !name.isEmpty { return name }
    return titleCaseWords(skill.name)
  }

  public static func dedupeByName(_ skills: [ProviderSkill]) -> [ProviderSkill] {
    var seen = Set<String>()
    return skills.filter { seen.insert($0.name.jsTrim().lowercased()).inserted }
  }

  /// A skill switched off in the provider's settings will not run, and one the provider reserves
  /// for the agent rejects a user invocation.
  public static func isUserInvocable(_ skill: ProviderSkill) -> Bool { skill.enabled && skill.userInvocable != false }

  public static func forSlashMenu(_ skills: [ProviderSkill], showSkillsInSlashMenu: Bool) -> [ProviderSkill] {
    showSkillsInSlashMenu ? dedupeByName(skills.filter(isUserInvocable)) : []
  }

  public static func slashCommandsForSlashMenu(_ commands: [ProviderSlashCommand], visibleSkills: [ProviderSkill]) -> [ProviderSlashCommand] {
    let names = Set(visibleSkills.map { $0.name.jsTrim().lowercased() })
    return commands.filter { !names.contains($0.name.jsTrim().lowercased()) }
  }

  public static func sourceKind(_ skill: ProviderSkill) -> SourceKind {
    let path = skill.path.replacingOccurrences(of: "\\", with: "/")
    if path.contains("/.codex/plugins/") || path.contains("/.agents/plugins/") { return .app }
    switch skill.scope?.jsTrim().lowercased() {
    case "repo", "repository": return .repo
    case "project", "workspace", "local": return .project
    case "user", "personal": return .personal
    case "system": return .system
    default: return .other
    }
  }

  public static func score(_ skill: ProviderSkill, query: String) -> Int? {
    let name = skill.name.lowercased()
    let label = displayName(skill).lowercased()
    let short = skill.shortDescription?.lowercased() ?? ""
    let description = skill.description?.lowercased() ?? ""
    let scope = skill.scope?.lowercased() ?? ""
    let scores = [
      SearchRanking.queryScore(value: name, query: query, exactBase: 0, prefixBase: 2, boundaryBase: 4, includesBase: 6, fuzzyBase: 100, boundaryMarkers: ["-", "_", "/"]),
      SearchRanking.queryScore(value: label, query: query, exactBase: 1, prefixBase: 3, boundaryBase: 5, includesBase: 7, fuzzyBase: 110),
      SearchRanking.queryScore(value: short, query: query, exactBase: 20, prefixBase: 22, boundaryBase: 24, includesBase: 26),
      SearchRanking.queryScore(value: description, query: query, exactBase: 30, prefixBase: 32, boundaryBase: 34, includesBase: 36),
      SearchRanking.queryScore(value: scope, query: query, exactBase: 40, prefixBase: 42, includesBase: 44),
    ].compactMap { $0 }
    return scores.min()
  }

  public static func search(_ skills: [ProviderSkill], query: String, limit: Int = Int.max) -> [ProviderSkill] {
    let enabled = dedupeByName(skills.filter(isUserInvocable))
    let normalized = SearchRanking.normalizeQuery(query) { $0.properties.generalCategory == .currencySymbol }
    if normalized.isEmpty { return enabled }
    var ranked: [SearchRanking.Ranked<ProviderSkill>] = []
    for skill in enabled {
      guard let score = score(skill, query: normalized) else { continue }
      SearchRanking.insert(&ranked, .init(item: skill, score: score, tieBreaker: "\(displayName(skill).lowercased())\u{0}\(skill.name)"), limit: limit)
    }
    return ranked.map(\.item)
  }
}

/// One row of the `/` menu.
public enum SlashMenuItem: Sendable, Hashable {
  case builtIn(ComposerSlashCommand, label: String, description: String)
  case provider(driver: String, command: ProviderSlashCommand, label: String, description: String)
  case skill(driver: String, skill: ProviderSkill, label: String, description: String)

  public var id: String {
    switch self {
    case .builtIn(let command, _, _): "slash:\(command.rawValue)"
    case .provider(let driver, let command, _, _): "provider-slash-command:\(driver):\(command.name)"
    case .skill(let driver, let skill, _, _): "skill:\(driver):\(skill.name)"
    }
  }

  public var label: String {
    switch self {
    case .builtIn(_, let label, _), .provider(_, _, let label, _), .skill(_, _, let label, _): label
    }
  }

  public var itemDescription: String {
    switch self {
    case .builtIn(_, _, let value), .provider(_, _, _, let value), .skill(_, _, _, let value): value
    }
  }
}

public enum SlashCommandSearch {
  /// A provider expands a slash command only when it opens the whole message.
  public static func itemsForPromptPosition(_ items: [SlashMenuItem], isAtPromptStart: Bool) -> [SlashMenuItem] {
    if isAtPromptStart { return items }
    return items.filter { if case .provider = $0 { false } else { true } }
  }

  private static func score(_ item: SlashMenuItem, query: String) -> Int? {
    if case .skill(_, let skill, _, _) = item {
      if query == "skill" { return 0 }
      let skillQuery = query.hasPrefix("skill:") ? String(query.dropFirst("skill:".count)) : query
      if !skillQuery.isEmpty, let score = ProviderSkills.score(skill, query: skillQuery) { return score }
      if skillQuery.isEmpty { return 0 }
      return "skill".hasPrefix(query) ? 9_007_199_254_740_991 : nil
    }
    let primary: String
    switch item {
    case .builtIn(let command, _, _): primary = command.rawValue.lowercased()
    case .provider(_, let command, _, _): primary = command.name.lowercased()
    case .skill: primary = ""
    }
    let description = item.itemDescription.lowercased()
    let scores = [
      SearchRanking.queryScore(value: primary, query: query, exactBase: 0, prefixBase: 2, boundaryBase: 4, includesBase: 6, fuzzyBase: 100, boundaryMarkers: ["-", "_", "/"]),
      SearchRanking.queryScore(value: description, query: query, exactBase: 20, prefixBase: 22, boundaryBase: 24, includesBase: 26),
    ].compactMap { $0 }
    return scores.min()
  }

  public static func search(_ items: [SlashMenuItem], query: String) -> [SlashMenuItem] {
    let normalized = SearchRanking.normalizeQuery(query) { $0 == "/" }
    if normalized.isEmpty { return items }
    var ranked: [SearchRanking.Ranked<SlashMenuItem>] = []
    for item in items {
      guard let score = score(item, query: normalized) else { continue }
      let tie: String
      switch item {
      case .builtIn(let command, _, _): tie = "0\u{0}\(command.rawValue)"
      case .provider(let driver, let command, _, _): tie = "1\u{0}\(command.name)\u{0}\(driver)"
      case .skill(let driver, let skill, _, _): tie = "2\u{0}\(skill.name)\u{0}\(driver)"
      }
      SearchRanking.insert(&ranked, .init(item: item, score: score, tieBreaker: tie))
    }
    return ranked.map(\.item)
  }
}
