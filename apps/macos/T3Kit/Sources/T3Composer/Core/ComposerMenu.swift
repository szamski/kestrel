import Foundation
import T3Contracts

/// One row of the trigger popover (`ComposerCommandItem`).
public enum ComposerMenuItem: Sendable, Hashable, Identifiable {
  case path(path: String, kind: ProjectEntryKind, label: String, description: String)
  /// A `/` row: built-in command, provider command or skill.
  case slash(SlashMenuItem)
  /// A `$` skill.
  case skill(driver: String, skill: ProviderSkill, label: String, description: String)
  case pullRequest(ComposerPullRequestCandidate)

  public var id: String {
    switch self {
    case .path(let path, let kind, _, _): "path:\(kind == .directory ? "directory" : "file"):\(path)"
    case .slash(let item): item.id
    case .skill(let driver, let skill, _, _): "skill:\(driver):\(skill.name)"
    case .pullRequest(let candidate): candidate.id
    }
  }

  public var label: String {
    switch self {
    case .path(_, _, let label, _), .skill(_, _, let label, _): label
    case .slash(let item): item.label
    case .pullRequest(let candidate): "#\(candidate.number)"
    }
  }

  public var itemDescription: String {
    switch self {
    case .path(_, _, _, let description), .skill(_, _, _, let description): description
    case .slash(let item): item.itemDescription
    case .pullRequest(let candidate): candidate.title
    }
  }
}

/// What picking a menu row does to the prompt, and the side effects that come with it.
public struct ComposerMenuEdit: Sendable, Hashable {
  public enum Effect: Sendable, Hashable {
    case openModelPicker
    case setInteractionMode(ProviderInteractionMode)
    case addRecord(ComposerContextRecord)
  }

  /// Markdown (expanded) offsets of the text to replace.
  public var rangeStart: Int
  public var rangeEnd: Int
  public var replacement: String
  public var effects: [Effect]
  /// The text the range must still hold for the edit to apply (a stale pick is dropped).
  public var expectedText: String
  /// Whether the editor keeps focus after the edit (`/model` hands focus to the picker).
  public var refocusEditor: Bool
}

public enum ComposerMenu {
  /// Replacement that ends in a space also swallows the space already after the range.
  private static func extendedRangeEnd(_ text: String, rangeEnd: Int, replacement: String) -> Int {
    guard replacement.hasSuffix(" ") else { return rangeEnd }
    return text.jsUnit(at: rangeEnd) == 0x20 ? rangeEnd + 1 : rangeEnd
  }

  /// `serializeComposerFileLink`: `[basename](encoded-path)`.
  public static func fileLink(forPath path: String) -> String {
    let slash = path.jsLastIndex(of: 0x2F, from: path.jsLength)
    let back = path.jsLastIndex(of: 0x5C, from: path.jsLength)
    let separator = max(slash, back)
    let base = separator >= 0 ? path.jsSlice(separator + 1) : path
    let label = base.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    return "[\(label)](\(URICodec.encodeFileLinkDestination(path)))"
  }

  /// The edit for picking `item` while `trigger` is active in `prompt`; nil when it cannot apply.
  public static func edit(for item: ComposerMenuItem, trigger: ComposerTrigger, prompt: String, planModeEnabled: Bool) -> ComposerMenuEdit? {
    let selected = prompt.jsSlice(trigger.rangeStart, trigger.rangeEnd)
    func make(_ replacement: String, effects: [ComposerMenuEdit.Effect] = [], refocus: Bool = true, extend: Bool = true) -> ComposerMenuEdit {
      let end = extend ? extendedRangeEnd(prompt, rangeEnd: trigger.rangeEnd, replacement: replacement) : trigger.rangeEnd
      return ComposerMenuEdit(
        rangeStart: trigger.rangeStart, rangeEnd: end, replacement: replacement, effects: effects,
        expectedText: extend ? prompt.jsSlice(trigger.rangeStart, end) : selected, refocusEditor: refocus)
    }
    switch item {
    case .path(let path, _, _, _):
      return make("\(fileLink(forPath: path)) ")
    case .slash(.builtIn(let command, _, _)):
      if command == .model { return make("", effects: [.openModelPicker], refocus: false, extend: false) }
      guard planModeEnabled else { return nil }
      return make("", effects: [.setInteractionMode(command == .plan ? .plan : .default)], extend: false)
    case .slash(.provider(_, let command, _, _)):
      return make("/\(command.name) ")
    case .slash(.skill(_, let skill, _, _)), .skill(_, let skill, _, _):
      return make("$\(skill.name) ")
    case .pullRequest(let candidate):
      guard trigger.kind == .pullRequest else { return nil }
      let record = ContextRecords.pullRequestReferenceRecord(candidate.metadata)
      let reference = ContextRecords.reference(for: .reviewComment(record))
      return make("\(ComposerContextReferences.format(reference)) ", effects: [.addRecord(.reviewComment(record))])
    }
  }

  public struct Inputs: Sendable {
    public var trigger: ComposerTrigger
    public var prompt: String
    public var driver: String
    public var skills: [ProviderSkill]
    public var slashCommands: [ProviderSlashCommand]
    public var showSkillsInSlashMenu: Bool
    public var planModeEnabled: Bool
    /// `/compact` only makes sense in an otherwise empty composer of a started thread.
    public var compactAvailable: Bool
    public var pathEntries: [ProjectEntry]
    public var pullRequests: [ComposerPullRequestCandidate]
    public var exactPullRequest: ComposerPullRequestCandidate?
    public var projectId: String?
    public var repository: String?

    public init(
      trigger: ComposerTrigger, prompt: String, driver: String, skills: [ProviderSkill] = [], slashCommands: [ProviderSlashCommand] = [],
      showSkillsInSlashMenu: Bool = true, planModeEnabled: Bool = false, compactAvailable: Bool = false, pathEntries: [ProjectEntry] = [],
      pullRequests: [ComposerPullRequestCandidate] = [], exactPullRequest: ComposerPullRequestCandidate? = nil, projectId: String? = nil, repository: String? = nil
    ) {
      self.trigger = trigger
      self.prompt = prompt
      self.driver = driver
      self.skills = skills
      self.slashCommands = slashCommands
      self.showSkillsInSlashMenu = showSkillsInSlashMenu
      self.planModeEnabled = planModeEnabled
      self.compactAvailable = compactAvailable
      self.pathEntries = pathEntries
      self.pullRequests = pullRequests
      self.exactPullRequest = exactPullRequest
      self.projectId = projectId
      self.repository = repository
    }
  }

  private static func skillDescription(_ skill: ProviderSkill, fallback: String) -> String {
    skill.shortDescription ?? skill.description ?? skill.scope.map { "\($0) skill" } ?? fallback
  }

  /// The rows for the active trigger (the `composerMenuItems` memo of the web composer).
  public static func items(_ input: Inputs) -> [ComposerMenuItem] {
    let trigger = input.trigger
    switch trigger.kind {
    case .path:
      return input.pathEntries.map { entry in
        let slash = entry.path.jsLastIndex(of: 0x2F, from: entry.path.jsLength)
        let base = slash >= 0 ? entry.path.jsSlice(slash + 1) : entry.path
        return .path(path: entry.path, kind: entry.kind, label: base, description: entry.path.jsSlice(0, max(0, slash)))
      }
    case .slashCommand, .slashModel:
      var builtIns: [SlashMenuItem] = [.builtIn(.model, label: "/model", description: "Switch response model for this thread")]
      if input.planModeEnabled {
        builtIns.append(.builtIn(.plan, label: "/plan", description: "Switch this thread into plan mode"))
        builtIns.append(.builtIn(.default, label: "/default", description: "Switch this thread back to normal build mode"))
      }
      let slashSkills = ProviderSkills.forSlashMenu(input.skills, showSkillsInSlashMenu: input.showSkillsInSlashMenu)
      let providerCommands = ProviderSkills.slashCommandsForSlashMenu(input.slashCommands, visibleSkills: slashSkills)
        .map { command in
          SlashMenuItem.provider(
            driver: input.driver, command: command, label: "/\(command.name)", description: command.description ?? command.input?.hint ?? "Run provider command")
        }
        .filter { item in
          if case .provider(_, let command, _, _) = item, command.name == "compact" { return input.compactAvailable }
          return true
        }
      let skillItems = slashSkills.map {
        SlashMenuItem.skill(driver: input.driver, skill: $0, label: "/skill:\($0.name)", description: skillDescription($0, fallback: ""))
      }
      let all = SlashCommandSearch.itemsForPromptPosition(builtIns + providerCommands + skillItems, isAtPromptStart: trigger.rangeStart == 0)
      return SlashCommandSearch.search(all, query: trigger.query.jsTrim().lowercased()).map { .slash($0) }
    case .skill:
      return ProviderSkills.search(input.skills, query: trigger.query).map {
        .skill(driver: input.driver, skill: $0, label: ProviderSkills.displayName($0), description: skillDescription($0, fallback: "Run provider skill"))
      }
    case .pullRequest:
      guard let projectId = input.projectId, let repository = input.repository else { return [] }
      return PullRequestMatching.menuMatches(
        recent: input.pullRequests, exact: input.exactPullRequest, projectId: projectId, repository: repository, query: trigger.query
      ).map { .pullRequest($0) }
    }
  }
}
