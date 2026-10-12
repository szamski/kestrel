import Foundation
import T3Contracts

// Thread <-> pull request linking: change request URLs, the capability negotiation between the single legacy link
// and the multi-link commands, and the stacked chains of a thread's links. Ports of `changeRequestUrl.ts`,
// `threadPullRequests.ts`, `pullRequestReference.ts` and `threadPullRequestCompatibility.ts`.

/// The shell's form of a thread's pull request link.
public typealias ThreadPullRequestItem = V1.OrchestrationThreadShellPullRequestsItem

/// A change request named the way a thread link names one: the host below which the repository is addressed, the
/// repository path as that host writes it (lower case) and the number.
public struct ChangeRequestLink: Sendable, Hashable {
  public var host: String
  public var repository: String
  public var number: Int
  /// Forgejo's HTTP host and port, separate from the portless repository identity.
  public var authority: String?

  public init(host: String, repository: String, number: Int, authority: String? = nil) {
    self.host = host
    self.repository = repository
    self.number = number
    self.authority = authority
  }
}

public enum ChangeRequestURL {
  /// The repository and number behind a change request URL on a host this can read, else nil. A doubtful match is worse
  /// than none, so nothing here guesses.
  public static func parse(_ text: String) -> ChangeRequestLink? {
    guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
      let host = components.host?.lowercased(), !host.isEmpty
    else { return nil }
    let path = components.percentEncodedPath
    func isHost(of apex: String, label: String? = nil) -> Bool {
      host == apex || host.hasSuffix("." + apex) || (label.map { host.split(separator: ".").contains(Substring($0)) } ?? false)
    }
    func claim(_ match: [String]?) -> ChangeRequestLink? {
      guard let match, let number = Int(match[2]), number > 0 else { return nil }
      return ChangeRequestLink(host: host, repository: match[1].lowercased(), number: number)
    }
    if isHost(of: "github.com", label: "github"), let link = claim(path.captures(#"^/([^/]+/[^/]+)/pull/(\d+)(?:/|$)"#)) { return link }
    if var link = claim(path.captures(#"^/([^/]+(?:/[^/]+)+)/pulls/(\d+)(?:/|$)"#)) {
      // JS `URL.host`: the port is kept unless it is the scheme's default.
      let port = components.port.flatMap { ($0 == 443 && scheme == "https") || ($0 == 80 && scheme == "http") ? nil : $0 }
      link.authority = port.map { "\(host):\($0)" } ?? host
      return link
    }
    if let link = claim(path.captures(#"^/([^/]+(?:/[^/]+)+)/-/merge_requests/(\d+)(?:/|$)"#)) { return link }
    if isHost(of: "bitbucket.org", label: "bitbucket") { return claim(path.captures(#"^/([^/]+/[^/]+)/pull-requests/(\d+)(?:/|$)"#)) }
    if isHost(of: "dev.azure.com") || host.hasSuffix(".visualstudio.com") {
      return claim(path.captures(#"^/((?:[^/]+/)*_git/[^/]+)/pullrequest/(\d+)(?:/|$)"#))
    }
    return nil
  }

  /// The web URL a host writes for a change request; nil when the host shape is unknown.
  public static func webURL(kind: String?, host: String, repository: String, number: Int, remoteURL: String? = nil) -> String? {
    switch kind {
    case "github": return "https://\(host)/\(repository)/pull/\(number)"
    case "forgejo":
      if let remote = remoteURL.flatMap({ URLComponents(string: $0) }), let scheme = remote.scheme?.lowercased(), scheme == "http" || scheme == "https",
        let remoteHost = remote.host?.lowercased()
      {
        let authority = remote.port.map { "\(remoteHost):\($0)" } ?? remoteHost
        if remoteHost == host.lowercased() || authority == host.lowercased() {
          return "\(scheme)://\(authority)/\(repository)/pulls/\(number)"
        }
      }
      return "https://\(host)/\(repository)/pulls/\(number)"
    case "gitlab": return "https://\(host)/\(repository)/-/merge_requests/\(number)"
    case "bitbucket": return "https://\(host)/\(repository)/pull-requests/\(number)"
    case "azure-devops": return "https://\(PullRequestKey.canonical("\(host)/\(repository)".lowercased()))/pullrequest/\(number)"
    default: return nil
    }
  }

  /// What a link dialog accepts: a pull request URL, `123` / `#123`, or the checkout command of a provider's CLI.
  /// Returns the URL or the bare number, else nil (`parsePullRequestReference`).
  public static func reference(from input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    var normalized = trimmed
    if let rest = trimmed.captures(#"^tea\s+(?:pr|pulls)\s+checkout\s+(.+)$"#, caseInsensitive: true)?[1]
      ?? trimmed.captures(#"^gh\s+pr\s+checkout\s+(.+)$"#, caseInsensitive: true)?[1]
      ?? trimmed.captures(#"^glab\s+mr\s+checkout\s+(.+)$"#, caseInsensitive: true)?[1]
    {
      normalized = rest.trimmingCharacters(in: .whitespaces)
    } else if let args = trimmed.captures(#"^az\s+repos\s+pr\s+checkout\s+(.+)$"#, caseInsensitive: true)?[1] {
      let parts = args.split(whereSeparator: \.isWhitespace).map(String.init)
      var found: String?
      for (index, part) in parts.enumerated() {
        if part == "--id" || part == "-i" { found = parts.indices.contains(index + 1) ? parts[index + 1] : nil; break }
        if part.hasPrefix("--id="), part.count > 5 { found = String(part.dropFirst(5)); break }
      }
      normalized = found ?? parts.first { !$0.hasPrefix("-") } ?? ""
    }
    guard !normalized.isEmpty else { return nil }
    let urlPatterns = [
      #"^https?://[^/\s]+/(?:[^/\s]+/)+[^/\s]+/pulls/(\d+)(?:[/?#].*)?$"#,
      #"^https://github\.com/[^/\s]+/[^/\s]+/pull/(\d+)(?:[/?#].*)?$"#,
      #"^https://[^/\s]*gitlab[^/\s]*/.+/-/merge_requests/(\d+)(?:[/?#].*)?$"#,
      #"^https://(?:dev\.azure\.com/[^/\s]+/[^/\s]+|[^/\s]+\.visualstudio\.com/[^/\s]+)/_git/[^/\s]+/pullrequest/(\d+)(?:[/?#].*)?$"#,
    ]
    if urlPatterns.contains(where: { normalized.captures($0, caseInsensitive: true) != nil }) { return normalized }
    return normalized.captures(#"^#?(\d+)$"#)?[1]
  }
}

extension String {
  /// Capture groups of the first match (index 0 is the whole match), or nil.
  func captures(_ pattern: String, caseInsensitive: Bool = false) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []),
      let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self))
    else { return nil }
    return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: self).map { String(self[$0]) } ?? "" }
  }
}

// MARK: Linking a pull request to a thread

/// What the dialog's input names, or why it cannot be linked.
public enum LinkPullRequestResolution: Sendable, Equatable {
  case link(ChangeRequestLink, url: String)
  case invalid(String)
}

/// The thread's own repository: a bare `#123` can only mean this one.
public struct LinkPullRequestProject: Sendable {
  public var host: String
  public var repository: String
  public var webURL: @Sendable (Int) -> String?

  public init(host: String, repository: String, webURL: @escaping @Sendable (Int) -> String?) {
    self.host = host
    self.repository = repository
    self.webURL = webURL
  }
}

/// A key identifying a link on its host (`normalizeThreadPullRequestKey`): host and repository trimmed and lower-cased,
/// Azure DevOps host forms canonicalised, a Forgejo HTTP port recovered from the link's URL.
public struct ThreadPullRequestKey: Sendable, Hashable, CustomStringConvertible {
  public var host: String
  public var repository: String
  public var number: Int

  public init(host: String, repository: String, number: Int, url: String? = nil) {
    let repository = repository.trimmingCharacters(in: .whitespaces).lowercased()
    var authority = host
    if let url, let parsed = ChangeRequestURL.parse(url), parsed.repository == repository, parsed.number == number, let own = parsed.authority { authority = own }
    let canonical = PullRequestKey.canonical("\(authority.trimmingCharacters(in: .whitespaces).lowercased())/\(repository)")
    let slash = canonical.firstIndex(of: "/") ?? canonical.endIndex
    self.host = String(canonical[..<slash])
    self.repository = slash == canonical.endIndex ? "" : String(canonical[canonical.index(after: slash)...])
    self.number = number
  }

  public var description: String { "\(host)/\(repository)#\(number)" }
}

extension ThreadPullRequestItem {
  public var linkKey: ThreadPullRequestKey { ThreadPullRequestKey(host: host, repository: repository, number: number, url: url) }
  /// An unsynced link counts as open: it was just linked, and hiding it until the first sync would look like a lost link.
  public var isOpen: Bool { snapshot == nil || snapshot?.state == .open }
  public var isVisible: Bool { source != .stackDismissed }
}

/// How a server takes thread link edits: the multi-link commands (`threadPullRequests`), the single legacy link through
/// `thread.meta.update` (`threadPullRequestLinking` only), or not at all.
public enum ThreadPullRequestLinkMode: Sendable, Equatable {
  case multiple, single, unsupported

  public init(_ capabilities: ExecutionEnvironmentCapabilities?) {
    if capabilities?.threadPullRequests == true {
      self = .multiple
    } else if capabilities?.threadPullRequestLinking == true {
      self = .single
    } else {
      self = .unsupported
    }
  }
}

/// The command a link change turns into.
public enum ThreadPullRequestMutation: Sendable, Equatable {
  case link(ThreadPullRequestKey, url: String)
  case unlink(ThreadPullRequestKey)
  /// `thread.meta.update` with the single `linkedPullRequest` (nil clears it).
  case legacy(ThreadLinkedPullRequest?)

  /// `planThreadPullRequestMutation`. The legacy path needs the exact repository checkout (`legacyProjectId`); nil when
  /// the environment cannot take this change.
  public static func plan(
    mode: ThreadPullRequestLinkMode, link: ChangeRequestLink, url: String, legacyProjectId: ProjectId?, legacyRepository: String? = nil, linked: Bool
  ) -> ThreadPullRequestMutation? {
    let key = ThreadPullRequestKey(host: link.authority ?? link.host, repository: link.repository, number: link.number, url: url)
    switch mode {
    case .multiple: return linked ? .link(key, url: url) : .unlink(key)
    case .single:
      if linked, legacyProjectId == nil { return nil }
      guard linked, let legacyProjectId else { return .legacy(nil) }
      return .legacy(ThreadLinkedPullRequest(projectId: legacyProjectId, repository: legacyRepository ?? link.repository, number: link.number, url: url))
    case .unsupported: return nil
    }
  }
}

/// Resolution of the link dialog's input (`resolveLinkPullRequestInput`).
public enum LinkPullRequestInput {
  public static func resolve(_ input: String, project: LinkPullRequestProject?, canLink: (ChangeRequestLink) -> Bool) -> LinkPullRequestResolution? {
    guard let reference = ChangeRequestURL.reference(from: input) else { return nil }
    if let parsed = ChangeRequestURL.parse(reference) {
      if !canLink(parsed) { return .invalid("No project in this environment can read \(parsed.host)/\(parsed.repository).") }
      return .link(parsed, url: reference)
    }
    guard let number = Int(reference), number > 0 else { return nil }
    guard let project else { return .invalid("Paste a full URL to link a pull request from another repository.") }
    guard let web = project.webURL(number), let parsed = ChangeRequestURL.parse(web) else {
      return .invalid("Paste a full URL; this project's host has no known pull request URL.")
    }
    return .link(parsed, url: web)
  }
}

// MARK: Projects

public enum PullRequestProjects {
  /// The host below which a repository is addressed (`pullRequestHostOf`).
  public static func host(of identity: RepositoryIdentity, kind: String) -> String {
    if kind == "forgejo", let remote = URLComponents(string: identity.locator.remoteUrl), let scheme = remote.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = remote.host?.lowercased()
    {
      return remote.port.map { "\(host):\($0)" } ?? host
    }
    let first = identity.canonicalKey.split(separator: "/").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    return first.isEmpty ? kind : first.lowercased()
  }

  public static func identity(of project: EnvironmentProject) -> RepositoryIdentity? { project.project.repositoryIdentity.flatMap { $0 } }

  /// `owner/name` of the repository as pull requests name it.
  public static func repository(of identity: RepositoryIdentity) -> String? {
    if let name = identity.displayName, !name.isEmpty { return name }
    guard let owner = identity.owner, let name = identity.name else { return nil }
    return "\(owner)/\(name)"
  }

  /// The project a link belongs to, matched the way the server matches (`findProjectForChangeRequest`).
  public static func project(for link: ChangeRequestLink, in projects: [EnvironmentProject]) -> EnvironmentProject? {
    projects.first { entry in
      guard let identity = identity(of: entry), let kind = identity.provider else { return false }
      if link.authority != nil, let remote = URLComponents(string: identity.locator.remoteUrl), let scheme = remote.scheme?.lowercased(), scheme == "http" || scheme == "https",
        let remoteHost = remote.host?.lowercased()
      {
        let authority = remote.port.map { "\(remoteHost):\($0)" } ?? remoteHost
        if authority != link.authority { return false }
      }
      if kind == "azure-devops" {
        return PullRequestKey.canonical(identity.canonicalKey.lowercased()) == PullRequestKey.canonical("\(link.host)/\(link.repository)".lowercased())
      }
      guard let repository = repository(of: identity) else { return false }
      let host = host(of: identity, kind: kind)
      return repository.lowercased() == link.repository.lowercased() && (host == link.host.lowercased() || host == link.authority)
    }
  }

  /// A project's own repository, for `#123` in the link dialog.
  public static func linkProject(for project: EnvironmentProject) -> LinkPullRequestProject? {
    guard let identity = identity(of: project), let kind = identity.provider,
      let repository = repository(of: identity)
    else { return nil }
    let host = host(of: identity, kind: kind)
    let remote = identity.locator.remoteUrl
    let webBase = identity.webUrl
    return LinkPullRequestProject(host: host, repository: repository) { number in
      if kind == "forgejo", let webBase { return "\(webBase.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/pulls/\(number)" }
      return ChangeRequestURL.webURL(kind: kind, host: host, repository: repository, number: number, remoteURL: remote)
    }
  }
}

// MARK: Chains

/// A thread's links grouped into a stack, bottom to top (`resolveThreadPullRequestChains`).
public struct ThreadPullRequestChain: Sendable {
  public enum Kind: Sendable { case native, derived }
  public var kind: Kind
  public var layers: [ThreadPullRequestItem]
}

/// One line of a thread's pull request list: a link plus how deep it sits in its stack.
public struct ThreadPullRequestLine: Sendable, Identifiable {
  public var link: ThreadPullRequestItem
  public var depth: Int
  public var chainKey: String
  /// Set on the bottom layer of a multi-layer stack, so that row can name the whole stack.
  public var stackSize: Int?
  public var id: String { link.linkKey.description }
}

public enum ThreadPullRequests {
  public static func visible(_ links: [ThreadPullRequestItem]) -> [ThreadPullRequestItem] { links.filter(\.isVisible) }

  /// Native stacks come from the host and win; the rest are chained by matching one link's base branch to another's head
  /// branch within the same repository. A link that chains to nothing is a one-layer chain.
  public static func chains(_ all: [ThreadPullRequestItem]) -> [ThreadPullRequestChain] {
    let links = visible(all)
    var chains: [ThreadPullRequestChain] = []
    var placed = Set<ThreadPullRequestKey>()

    var native: [(stack: String, members: [ThreadPullRequestItem])] = []
    for link in links {
      guard let stack = link.stack else { continue }
      let key = link.linkKey
      let stackKey = "\(key.host)/\(key.repository)#stack:\(stack.id)"
      if let index = native.firstIndex(where: { $0.stack == stackKey }) { native[index].members.append(link) } else { native.append((stackKey, [link])) }
    }
    for group in native {
      let layers = group.members[0].stack?.layers ?? []
      var members = group.members
      let order = Dictionary(layers.enumerated().map { ($1.number, $0) }, uniquingKeysWith: { first, _ in first })
      members.sort { (order[$0.number] ?? 0) < (order[$1.number] ?? 0) }
      placed.formUnion(members.map(\.linkKey))
      chains.append(ThreadPullRequestChain(kind: .native, layers: members))
    }

    let remaining = links.filter { !placed.contains($0.linkKey) }
    func branchKey(_ link: ThreadPullRequestItem, _ branch: String) -> String { "\(link.linkKey.host)/\(link.linkKey.repository):\(branch)" }
    // Reused head names cannot identify a parent unambiguously.
    var byHead: [String: ThreadPullRequestItem?] = [:]
    for link in remaining {
      guard let snapshot = link.snapshot else { continue }
      let key = branchKey(link, snapshot.headBranch)
      byHead[key] = byHead[key] != nil ? .some(nil) : .some(link)
    }
    func parent(of link: ThreadPullRequestItem) -> ThreadPullRequestItem? {
      guard let snapshot = link.snapshot, case .some(.some(let found)) = byHead[branchKey(link, snapshot.baseBranch)], found.linkKey != link.linkKey else { return nil }
      return found
    }
    var hasChild = Set<ThreadPullRequestKey>()
    for link in remaining { if let parent = parent(of: link) { hasChild.insert(parent.linkKey) } }
    // Walk from each top (a link nothing builds on) down its base chain.
    for top in remaining where !hasChild.contains(top.linkKey) {
      var layers: [ThreadPullRequestItem] = []
      var cursor: ThreadPullRequestItem? = top
      while let link = cursor, placed.insert(link.linkKey).inserted {
        layers.insert(link, at: 0)
        cursor = parent(of: link)
      }
      if !layers.isEmpty { chains.append(ThreadPullRequestChain(kind: .derived, layers: layers)) }
    }
    // Cycles have no top. Keep those links visible without inventing a stack order.
    for link in remaining where !placed.contains(link.linkKey) { chains.append(ThreadPullRequestChain(kind: .derived, layers: [link])) }
    return chains
  }

  private static func activity(_ link: ThreadPullRequestItem) -> Double {
    IsoTimestamp.parse(link.snapshot?.updatedAt ?? link.linkedAt) ?? 0
  }

  /// Chains flattened into indented lines, newest first. A stack sorts by its most recent layer and then reads bottom to
  /// top beneath that slot.
  public static func lines(_ chains: [ThreadPullRequestChain]) -> [ThreadPullRequestLine] {
    let ordered = chains.sorted { ($0.layers.map(activity).max() ?? 0) > ($1.layers.map(activity).max() ?? 0) }
    return ordered.flatMap { chain in
      let bottom = chain.layers[0]
      let chainKey = "\(bottom.host)/\(bottom.repository)#\(bottom.number)"
      return chain.layers.enumerated().map { depth, link in
        ThreadPullRequestLine(link: link, depth: depth, chainKey: chainKey, stackSize: depth == 0 && chain.layers.count > 1 ? chain.layers.count : nil)
      }
    }
  }

  /// The single pull request a one-slot surface (copy number, tab icon) shows: open work first and the highest open layer
  /// within a chain; a completed chain still points at its top; unrelated terminal links use the most recently updated.
  public static func current(_ all: [ThreadPullRequestItem]) -> ThreadPullRequestItem? {
    let links = visible(all)
    if links.isEmpty { return nil }
    let open = links.filter(\.isOpen)
    if open.count == 1 { return open[0] }
    let chains = chains(links)
    if open.count > 1 {
      let openChains = chains.map { $0.layers.reversed().filter(\.isOpen) }.filter { !$0.isEmpty }
        .sorted { ($0.map { IsoTimestamp.parse($0.linkedAt) ?? 0 }.max() ?? 0) > ($1.map { IsoTimestamp.parse($0.linkedAt) ?? 0 }.max() ?? 0) }
      return openChains.flatMap { $0 }.first
    }
    if chains.count == 1 { return chains[0].layers.last }
    return links.max { activity($0) < activity($1) }
  }
}
