import Foundation
import T3ClientRuntime

/// The settings pages, in sidebar order.
enum SettingsPage: String, CaseIterable, Identifiable {
  case general, appearance, projects, keybindings, snapShot, providers, integrations, sourceControl, storage, connections, archived, diagnostics, licenses

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: "General"
    case .appearance: "Appearance"
    case .projects: "Projects"
    case .keybindings: "Keybindings"
    case .snapShot: "SnapShots"
    case .providers: "Providers"
    case .integrations: "Integrations"
    case .sourceControl: "Source control"
    case .storage: "Storage"
    case .connections: "Connections"
    case .archived: "Archived"
    case .diagnostics: "Diagnostics"
    case .licenses: "Open-source licenses"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .appearance: "paintpalette"
    case .projects: "rectangle.3.group"
    case .keybindings: "keyboard"
    case .snapShot: "camera.viewfinder"
    case .providers: "cpu"
    case .integrations: "puzzlepiece.extension"
    case .sourceControl: "arrow.triangle.branch"
    case .storage: "internaldrive"
    case .connections: "link"
    case .archived: "archivebox"
    case .diagnostics: "waveform.path.ecg"
    case .licenses: "doc.text"
    }
  }

  /// Device-local pages never touch a server, so they ignore the scope selection and hide the scope bar.
  var hidesScopeBar: Bool {
    switch self {
    case .appearance, .snapShot, .connections, .diagnostics, .licenses: true
    default: false
    }
  }

  /// Which targets can edit the page's settings (`SETTINGS_CATEGORY_SCOPES`).
  var owningScope: SettingsSearchScope? {
    switch self {
    case .projects: .project
    case .sourceControl: .environmentDefaults
    case .storage, .archived: .projectDefaults
    case .connections: .connections
    default: nil
    }
  }
}

/// Where a setting can be edited. Rows without one are device-local and render at every selection;
/// `projectDefaults` rows also accept project overrides.
enum SettingsSearchScope {
  case environment, environmentDefaults, projectDefaults, project, checkout, connections

  func isAvailable(in kind: SettingsScope.Kind) -> Bool {
    switch self {
    case .connections: true
    case .environment: kind == .environment
    case .checkout: kind == .checkout
    case .project: kind == .project || kind == .checkout
    case .environmentDefaults: kind == .environment || kind == .all
    case .projectDefaults: kind != .unavailable
    }
  }
}

/// One searchable destination. `anchor` is the row id to scroll to when it differs from `id`.
struct SettingsSearchItem: Identifiable {
  let id: String
  let title: String
  let page: SettingsPage
  var anchor: String?
  var terms: String = ""
  var scope: SettingsSearchScope?
  var requiresAutoSettlement = false

  var target: String { anchor ?? id }
}

/// Port of `settingsSearch.ts`. Rows with a dedicated anchor take their id and title from here, so the catalog and the
/// rendered pages cannot drift apart. Desktop-shell, cloud and Windows-only entries and the per-command keybinding rows
/// are left out until their pages exist.
enum SettingsRegistry {
  private static func item(
    _ id: String, _ title: String, _ page: SettingsPage, _ terms: String = "", scope: SettingsSearchScope? = nil, anchor: String? = nil,
    autoSettle: Bool = false
  ) -> SettingsSearchItem {
    SettingsSearchItem(id: id, title: title, page: page, anchor: anchor, terms: terms, scope: scope, requiresAutoSettlement: autoSettle)
  }

  static let items: [SettingsSearchItem] = [
    item("storage-worktrees", "Worktree cleanup", .storage, "disk storage delete deleted archived threads old inactive merged unchanged worktrees retention days project inherit off custom", scope: .projectDefaults),
    item("storage-worktrees-location", "Worktree location", .storage, "worktree location folder directory path drive external disk", scope: .environmentDefaults),
    item("storage-artifacts", "Artifacts and logs", .storage, "disk storage browser screenshots captures rotated logs cleanup retention", scope: .environmentDefaults),
    item("project-defaults", "Project defaults and overrides", .general, "model workspace environments projects inheritance checkout", scope: .projectDefaults),
    item("project-overview", "Project overview", .projects, "name icon emoji image checkout remove delete"),
    item("default-model", "Default model", .general, "new thread project provider reasoning effort", scope: .projectDefaults),
    item("default-permissions", "Permissions", .general, "new thread default runtime mode supervised approvals auto accept edits full access", scope: .projectDefaults),
    item("color-scheme", "Color scheme", .appearance, "appearance light dark system mode", anchor: "appearance"),
    item("theme", "Themes", .appearance, "appearance colors palette custom import", anchor: "appearance"),
    item("setting-appearance-contrast", "Contrast", .appearance, "colors borders interface"),
    item("setting-glass-opacity", "Glass opacity", .appearance, "transparent transparency solid menus dialogs composer"),
    item("diff-color-scheme", "Diff colors", .appearance, "red green blue orange additions deletions changes counts palette colorblind"),
    item("chat-width", "Chat width", .appearance, "wide full width column layout messages composer monitor"),
    item("panel-animations", "Panel animations", .appearance),
    item("environment-identification", "Environment identification", .appearance, "dev nightly artwork pill label hide none", anchor: "appearance-interface"),
    item("interface-font", "Interface font", .appearance, "typography family size system sans"),
    item("prompt-font", "Prompt font", .appearance, "typography family size composer input"),
    item("code-font", "Code font", .appearance, "typography family size monospace code blocks diffs file previews"),
    item("terminal-font", "Terminal font", .appearance, "typography family size monospace output"),
    item("font-smoothing", "Font smoothing", .appearance, "typography text grayscale anti aliasing macos thin"),
    item("word-wrap", "Word wrap", .appearance, "long lines code blocks tables diffs file previews"),
    item("project-grouping", "Project grouping", .general, "combine matching repositories environments sidebar"),
    item("auto-settle-inactive-threads", "Auto-settle inactive threads", .general, "sidebar inactivity days no activity automatically", scope: .projectDefaults, autoSettle: true),
    item("auto-settle-merged-threads", "Auto-settle merged threads", .general, "pull request merge closed automatically sidebar", scope: .projectDefaults, autoSettle: true),
    item("days-before-auto-settle", "Days of inactivity before auto-settle", .general, "thread timeout activity sidebar", scope: .projectDefaults, anchor: "auto-settle-inactive-threads", autoSettle: true),
    item("thread-notifications", "Thread notifications", .general, "notification sound alert completion input approval desktop"),
    item("in-app-notifications", "In-app notifications", .general, "notification toast popup completion input approval failure"),
    item("time-format", "Time format", .general, "timestamp clock locale system browser os 12 hour 24 hour"),
    item("response-streaming", "Response streaming", .general, "output token paragraph buffered wait turn legacy", scope: .projectDefaults),
    item("hide-whitespace-changes", "Hide whitespace changes", .general, "diff ignore spaces edits default"),
    item("default-diff-file-state", "Default diff file state", .general, "collapsed expanded collapse expand files pull request pr code tab"),
    item("diff-layout", "Diff layout", .general, "stacked split side by side unified inline view"),
    item("proactive-panels", "Proactive panels", .general, "automatically open diff pull request pr right panel agent completion"),
    item("skills-in-slash-menu", "Show skills in slash menu", .general, "command menu dollar $ slash /"),
    item("composer-rich-text", "Rich text composer", .general, "composer rich text bold italic markdown styled wysiwyg"),
    item("composer-collapse", "Collapse composer on scroll", .general, "composer rest resting scroll wheel conversation timeline shrink minimize"),
    item("send-shortcut", "Send shortcut", .general, "enter return command ctrl multiline prompt new line composer"),
    item("follow-up-behavior", "Follow-up behavior", .general, "queue steer running turn send default behavior composer"),
    item("provider-update-checks", "Provider update checks", .general, "installed cli versions newer available codex claude cursor grok opencode", scope: .environmentDefaults),
    item("continue-threads-after-server-update", "Continue threads after restarts", .general, "resume running active interrupted work restart reboot machine crash desktop update automatically", scope: .projectDefaults),
    item("background-activity", "Background activity", .general, "balanced performance battery saver advanced git fetch provider health refresh host power monitor idle policy", scope: .environmentDefaults),
    item("new-threads", "New threads", .general, "default workspace mode draft local worktree", scope: .projectDefaults),
    item("worktree-submodules", "Submodules", .general, "git submodule init recursive top-level none worktree t3.json", scope: .projectDefaults),
    item("start-from-origin", "Start from origin", .general, "new worktrees latest matching remote branch local", scope: .projectDefaults),
    item("add-project-starts-in", "Add project starts in", .general, "base directory folder browser path home", scope: .environmentDefaults),
    item("unpin-confirmation", "Unpin confirmation", .general, "ask before thread pinned section"),
    item("archive-confirmation", "Archive confirmation", .general, "ask before thread second click inline action"),
    item("delete-confirmation", "Delete confirmation", .general, "ask before thread chat history"),
    item("quit-confirmation", "Quit shortcut", .general, "confirmation app exit direct hold double click press twice"),
    item("text-generation-model", "Text generation model", .general, "generated thread titles source control content default provider", scope: .projectDefaults),
    item("diagnostics", "Diagnostics", .general, "logs traces processes resource history failures spans cpu memory"),
    item("open-source-licenses", "Open source licenses", .general),
    item("legacy-plan-mode", "Plan mode (legacy)", .general, "build plan composer old"),
    item("legacy-context-window-indicator", "Context window indicator (legacy)", .general, "composer meter usage tokens circle old"),
    item("legacy-sidebar", "Sidebar (legacy)", .general, "project thread tree old flat list"),
    item("keybindings", "Keybindings", .keybindings, "keyboard shortcuts hotkeys commands bindings json"),
    item("snap-shot-enabled", "SnapShots", .snapShot, "window capture screenshot"),
    item("snap-shot-accessibility", "Include app text", .snapShot, "capture accessibility data text UI structure elements privacy omit agent context", anchor: "snap-shot-enabled"),
    item("snap-shot-shortcut", "Capture shortcut", .snapShot, anchor: "snap-shot-enabled"),
    item("snap-shot-sound", "Capture sound", .snapShot, anchor: "snap-shot-enabled"),
    item("snap-shot-flash", "Capture flash", .snapShot, anchor: "snap-shot-enabled"),
    item("snap-shot-animations", "Capture animations", .snapShot, anchor: "snap-shot-enabled"),
    item("providers", "Providers", .providers, "agents cli codex claude cursor grok opencode antigravity google sign in sign out install subscription instances authentication api key models configuration binary path config directory endpoint arguments environment variables display name accent color"),
    item("usage-providers", "Usage providers", .providers, "usage sources CLIProxyAPI CLI proxy hub quota subscription limits management key add remove"),
    item("cursor-keychain-usage", "Cursor account usage", .providers, "cursor macOS keychain usage tokens cost limits permission"),
    item("provider-health-check-interval", "Health check interval", .providers, "refresh availability versions auth state models background probes seconds off"),
    item("agent-browser-access", "Agent browser access", .integrations, "allow disable enable open drive preview tools sessions project override", scope: .projectDefaults),
    item("device-hosts", "Device hosts", .integrations, "ssh remote simulator emulator ios android mac mini identity key connection"),
    item("agent-device-access", "Agent device access", .integrations, "allow simulator emulator ios android drive tools sessions", anchor: "devices"),
    item("device-hub", "Device hub", .integrations, "simulator emulator ios android install start", anchor: "devices"),
    item("device-platform-support", "Simulator support", .integrations, "xcode android studio sdk avd runtime", anchor: "devices"),
    item("browser-profiles", "Browser profiles", .integrations, anchor: "browser"),
    item("browser-default-profile", "Default browser profile", .integrations, anchor: "browser-profiles"),
    item("browser-default-viewport", "Default browser viewport", .integrations, "preview size width height device desktop mobile rotate"),
    item("browser-default-zoom", "Default browser zoom", .integrations, "preview page scale tabs percent"),
    item("browser-default-appearance", "Default browser appearance", .integrations, "preview color scheme light dark system os"),
    item("browser-recording-frame-rate", "Browser recording frame rate", .integrations),
    item("browser-recording-key-presses", "Show key presses in recordings", .integrations, "browser preview keyboard shortcuts keystrokes overlay capture"),
    item("browser-recording-mouse-presses", "Show mouse presses in recordings", .integrations, "browser preview clicks buttons drag overlay capture"),
    item("browser-link-target", "Open links in", .integrations, "links default browser in-app browser external open"),
    item("browser-auto-show-floating-preview", "Auto-show floating preview", .integrations, "agent opens browser device simulator pop into view hide"),
    item("automatic-pull", "Automatically pull", .sourceControl, "auto pull default branch current checkout fast forward upstream", scope: .projectDefaults),
    item("pull-request-merge-method", "Default merge method", .sourceControl, "pull request merge squash rebase last selected", scope: .projectDefaults),
    item("remove-agent-credits-on-merge", "Remove agent credits when merging", .sourceControl, "pull request github squash co-authored-by attribution claude codex generated", scope: .projectDefaults),
    item("worktree-branch-naming", "Worktree branch naming", .sourceControl, "static semantic prefix custom prompt instructions feat fix refactor chore", scope: .projectDefaults),
    item("github-accounts", "GitHub accounts and token", .sourceControl, "github gh account login user host enterprise ghes switch multiple accounts disable sign in token personal access token pat api key credential", scope: .environmentDefaults),
    item("bitbucket-credentials", "Bitbucket credentials", .sourceControl, "bitbucket atlassian access token api token email credentials sign in", scope: .environmentDefaults),
    item("source-control", "Source control", .sourceControl, "version control git github gitlab forgejo gitea tea codeberg bitbucket azure devops hosting integrations credentials scan server environment", scope: .environmentDefaults),
    item("git-fetch-interval", "Git fetch interval", .sourceControl, "automatic remote branch refresh background credentials security keys seconds off", scope: .environmentDefaults),
    item("source-control-writing-style", "Source control writing style", .sourceControl, "repository conventions conventional commits custom instructions change descriptions request titles"),
    item("follow-change-request-templates", "Follow change request templates", .sourceControl, "repository pr pull request description structure"),
    item("source-control-writer-model", "Source control writer model", .sourceControl, "override generated commit change request pr titles descriptions branch bookmark", scope: .projectDefaults),
    item("project-actions", "Actions", .projects, "commands scripts setup run dev server checkout worktree t3.json import"),
    item("environment-icon", "Environment icon", .connections, "machine glyph sidebar mac mini studio laptop desktop server cloud vm", anchor: "connections-environment"),
    item("local-environment", "Local environment", .connections, "turn off on disable enable local server agents remote only restart", anchor: "connections-environment"),
    item("network-access", "Network access", .connections, "expose backend remote pairing local machine interfaces host restart", anchor: "connections-environment"),
    item("connections-environment", "This machine", .connections, "connections server backend local remote access administrative permissions scope pairing links qr code authorized clients sessions revoke endpoint"),
    item("tailscale-https", "Tailscale HTTPS", .connections, "tailscale serve magicdns tailnet https certificate remote private network", anchor: "connections-environment"),
    item("publish-agent-activity", "Publish agent activity", .connections, "mobile notifications live activities relay t3 connect phone", anchor: "connections-environment"),
    item("authorized-clients", "Authorized clients", .connections, "pairing links qr code create revoke sessions devices paired scopes permissions access"),
    item("remote-environments", "Environments", .connections, "add pair backend host code ssh config agent tunnel saved t3 connect"),
    item("load-balancing", "Load balancing", .connections, "automatic machine environment resources cpu memory capacity preference weight shared projects"),
    item("github-routing", "GitHub sharing", .connections, "pull request trusted environments shared credentials permissions read actions"),
    item("archive", "Archived threads", .archived, "restore reopen deleted history projects"),
  ] + keybindingItems

  private static func normalize(_ text: String) -> String {
    let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "$/")).inverted
    return text.lowercased().components(separatedBy: separators).filter { !$0.isEmpty }.joined(separator: " ")
  }

  /// Every token must appear in the title, the page name or the terms; title matches rank first.
  static func search(_ query: String, in items: [SettingsSearchItem] = items) -> [SettingsSearchItem] {
    let normalized = normalize(query)
    guard !normalized.isEmpty else { return [] }
    let tokens = normalized.split(separator: " ").map(String.init)
    let matches = items.enumerated().compactMap { index, item -> (item: SettingsSearchItem, index: Int, rank: Int)? in
      let title = normalize(item.title)
      let fields = [title, normalize(item.page.title), normalize(item.terms)]
      guard tokens.allSatisfy({ token in fields.contains { $0.contains(token) } }) else { return nil }
      let rank =
        title == normalized ? 5
        : title.hasPrefix(normalized) ? 4
        : title.contains(normalized) ? 3
        : tokens.allSatisfy({ title.contains($0) }) ? 2
        : fields.contains { $0.contains(normalized) } ? 1 : 0
      return (item, index, rank)
    }
    return matches.sorted { $0.rank != $1.rank ? $0.rank > $1.rank : $0.index < $1.index }.map(\.item)
  }
}
