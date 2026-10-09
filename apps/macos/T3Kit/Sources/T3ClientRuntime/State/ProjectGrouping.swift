import Foundation
import T3Contracts

/// Port of `state/projectGrouping.ts`: logical project groups over physical environment
/// projects, honouring the grouping mode and per-project overrides.
public enum ProjectGroupingMode: String, Sendable, Codable, Hashable {
  case repository
  case repositoryPath = "repository_path"
  case separate
}

public struct ProjectGroupingSettings: Sendable, Equatable {
  public var mode: ProjectGroupingMode
  /// Keyed by physical project key (`environmentId:normalized workspace root`).
  public var overrides: [String: ProjectGroupingMode]
  public init(mode: ProjectGroupingMode = .repository, overrides: [String: ProjectGroupingMode] = [:]) {
    self.mode = mode
    self.overrides = overrides
  }
}

public struct ProjectGroup: Sendable, Equatable {
  public struct Member: Sendable, Equatable {
    public let physicalProjectKey: String
    public let project: EnvironmentProject
  }
  public let key: String
  public let label: String
  public let representative: EnvironmentProject
  public let members: [Member]
  public let memberProjectRefs: [ScopedProjectRef]
}

public enum ProjectGrouping {
  /// `normalizeProjectPathForComparison` from packages/shared/src/path.ts.
  public static func normalizePath(_ value: String) -> String {
    let normalized = trimTrailingSeparators(value.trimmingCharacters(in: .whitespacesAndNewlines))
    if isWindowsDrive(normalized) || normalized.hasPrefix("\\\\") {
      return normalized.replacingOccurrences(of: "/", with: "\\").lowercased()
    }
    return normalized
  }

  private static func isWindowsDrive(_ v: String) -> Bool {
    let c = Array(v)
    guard c.count >= 2, c[0].isASCII, c[0].isLetter, c[1] == ":" else { return false }
    return c.count == 2 || c[2] == "/" || c[2] == "\\"
  }

  private static func trimTrailingSeparators(_ value: String) -> String {
    if value.isEmpty || value == "/" || value == "\\" { return value }
    let c = Array(value)
    if c.count == 3, c[0].isASCII, c[0].isLetter, c[1] == ":", c[2] == "/" || c[2] == "\\" { return value }
    var end = c.count
    if value.hasPrefix("/") {
      while end > 0, c[end - 1] == "/" { end -= 1 }
    } else {
      while end > 0, c[end - 1] == "/" || c[end - 1] == "\\" { end -= 1 }
    }
    let trimmed = String(c[0..<end])
    if trimmed.isEmpty { return value }
    let t = Array(trimmed)
    return t.count == 2 && t[0].isASCII && t[0].isLetter && t[1] == ":" ? trimmed + "\\" : trimmed
  }

  private static func uniqueNonEmpty(_ values: [String?]) -> [String] {
    var seen = Set<String>(), unique: [String] = []
    for value in values {
      guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
      unique.append(trimmed)
    }
    return unique
  }

  static func physicalKey(_ project: EnvironmentProject) -> String {
    "\(project.environmentId.rawValue):\(normalizePath(project.project.workspaceRoot))"
  }

  public static func resolveMode(_ project: EnvironmentProject, _ settings: ProjectGroupingSettings) -> ProjectGroupingMode {
    settings.overrides[physicalKey(project)] ?? settings.mode
  }

  private static func repositoryRelativePath(_ project: EnvironmentProject) -> String? {
    guard let identity = optionalValue(project.project.repositoryIdentity),
      let rootPath = identity.rootPath?.trimmingCharacters(in: .whitespacesAndNewlines), !rootPath.isEmpty
    else { return nil }
    let projectPath = normalizePath(project.project.workspaceRoot), root = normalizePath(rootPath)
    if projectPath.isEmpty || root.isEmpty { return nil }
    if projectPath == root { return "" }
    let separator = root.contains("\\") ? "\\" : "/"
    let prefix = root + separator
    guard projectPath.hasPrefix(prefix) else { return nil }
    return String(projectPath.dropFirst(prefix.count)).replacingOccurrences(of: "\\", with: "/")
  }

  private static func repositoryScopedKey(_ project: EnvironmentProject, _ mode: ProjectGroupingMode) -> String? {
    guard let canonical = optionalValue(project.project.repositoryIdentity)?.canonicalKey, !canonical.isEmpty else { return nil }
    if mode == .repository { return canonical }
    guard let relative = repositoryRelativePath(project) else { return canonical }
    return relative.isEmpty ? canonical : "\(canonical)::\(relative)"
  }

  public static func logicalKey(_ project: EnvironmentProject, mode: ProjectGroupingMode = .repository) -> String {
    if mode == .separate { return physicalKey(project) }
    return repositoryScopedKey(project, mode) ?? physicalKey(project)
  }

  private static func groupLabel(representative: EnvironmentProject, members: [EnvironmentProject]) -> String {
    let titles = uniqueNonEmpty(members.map { $0.project.title })
    let displayNames = uniqueNonEmpty(members.map { optionalValue($0.project.repositoryIdentity)?.displayName })
    let names = uniqueNonEmpty(members.map { optionalValue($0.project.repositoryIdentity)?.name })
    if titles.count == 1, let title = titles.first, !displayNames.contains(title), !names.contains(title) { return title }
    if displayNames.count == 1 { return displayNames[0] }
    if names.count == 1 { return names[0] }
    return representative.project.title
  }

  private static func freshness(_ project: EnvironmentProject) -> Double {
    IsoTimestamp.parse(project.project.updatedAt) ?? IsoTimestamp.parse(project.project.createdAt) ?? 0
  }

  private static func shouldReplace(_ existing: EnvironmentProject, with candidate: EnvironmentProject) -> Bool {
    let delta = freshness(candidate) - freshness(existing)
    return delta > 0 || (delta == 0 && JS.less(existing.project.id.rawValue, candidate.project.id.rawValue))
  }

  private static func hasIdentity(_ p: EnvironmentProject) -> Bool { optionalValue(p.project.repositoryIdentity) != nil }

  private static func identitySource(_ projects: [EnvironmentProject], winner: EnvironmentProject) -> EnvironmentProject {
    if hasIdentity(winner) { return winner }
    var freshest: EnvironmentProject?
    for project in projects where hasIdentity(project) {
      if freshest == nil || shouldReplace(freshest!, with: project) { freshest = project }
    }
    return freshest ?? winner
  }

  public static func buildGroups(
    projects: [EnvironmentProject], settings: ProjectGroupingSettings, preferredEnvironmentId: EnvironmentId? = nil,
    connectedEnvironmentIds: Set<EnvironmentId>? = nil
  ) -> [ProjectGroup] {
    // Insertion-ordered maps: JS Map iteration order is the observable output order.
    var physicalOrder: [String] = [], byPhysical: [String: [EnvironmentProject]] = [:]
    for project in projects {
      let key = physicalKey(project)
      if byPhysical[key] == nil { physicalOrder.append(key) }
      byPhysical[key, default: []].append(project)
    }
    var logicalByPhysical: [String: String] = [:]
    var groupOrder: [String] = [], grouped: [String: [ProjectGroup.Member]] = [:]
    for key in physicalOrder {
      let candidates = byPhysical[key]!
      let winner = candidates.dropFirst().reduce(candidates[0]) { shouldReplace($0, with: $1) ? $1 : $0 }
      let source = identitySource(candidates, winner: winner)
      let logical = logicalKey(source, mode: resolveMode(winner, settings))
      logicalByPhysical[key] = logical
      if grouped[logical] == nil { groupOrder.append(logical) }
      grouped[logical, default: []].append(.init(physicalProjectKey: key, project: winner))
    }
    var refsByLogical: [String: [ScopedProjectRef]] = [:]
    var seen = Set<String>()
    for project in projects {
      let logical = logicalByPhysical[physicalKey(project)]
        ?? logicalKey(project, mode: resolveMode(project, settings))
      guard seen.insert(project.id).inserted else { continue }
      refsByLogical[logical, default: []].append(ScopedProjectRef(environmentId: project.environmentId, projectId: project.projectId))
    }
    return groupOrder.map { key in
      let members = grouped[key]!
      // New threads start in the representative, so a disconnected environment only represents a group nobody else has.
      let live = connectedEnvironmentIds.map { ids in members.filter { ids.contains($0.project.environmentId) } } ?? members
      let pool = live.isEmpty ? members : live
      let representative = preferredEnvironmentId.flatMap { id in pool.first { $0.project.environmentId == id }?.project } ?? pool[0].project
      return ProjectGroup(
        key: key,
        label: members.count > 1 ? groupLabel(representative: representative, members: members.map(\.project)) : representative.project.title,
        representative: representative, members: members, memberProjectRefs: refsByLogical[key] ?? [])
    }
  }
}
