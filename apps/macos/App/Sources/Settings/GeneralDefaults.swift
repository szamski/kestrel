import Foundation
import T3ClientRuntime
import T3Contracts

/// What "Restore defaults" resets on the General page, mirroring the web's device-defaults list: device preferences
/// always, server settings on the current target (project overrides are dropped at a project scope).
@MainActor
enum GeneralDefaults {
  private static let dc = ClientSettingsSchema()
  private static let ds = ServerSettings()

  /// Server keys a project may hold an override for.
  private static let projectKeys = [
    "responseStreamingMode", "continueThreadsAfterServerUpdate", "defaultThreadEnvMode", "newWorktreesStartFromOrigin", "sidebarAutoSettleAfterDays",
    "sidebarAutoSettleOnMerge", "textGenerationModelSelection",
  ]

  static func changedLabels(_ model: SettingsModel) -> [String] {
    let c = model.client
    var labels: [(String, Bool)] = [
      ("Thread notifications", c.notificationMode != dc.notificationMode),
      ("In-app notifications", c.inAppNotificationsEnabled != dc.inAppNotificationsEnabled),
      ("Time format", c.timestampFormat != dc.timestampFormat),
      ("Diff whitespace changes", c.diffIgnoreWhitespace != dc.diffIgnoreWhitespace),
      ("Default diff file state", c.diffFilesCollapsed != dc.diffFilesCollapsed),
      ("Diff layout", c.diffLayout != dc.diffLayout),
      ("Proactive panels", c.proactivePanelsEnabled != dc.proactivePanelsEnabled),
      ("Show skills in slash menu", c.showSkillsInSlashMenu != dc.showSkillsInSlashMenu),
      ("Rich text composer", c.composerRichTextEnabled != dc.composerRichTextEnabled),
      ("Collapse composer on scroll", c.composerCollapseOnScroll != dc.composerCollapseOnScroll),
      ("Send shortcut", c.sendShortcut != dc.sendShortcut),
      ("Follow-up behavior", c.followUpBehavior != dc.followUpBehavior),
      ("Project grouping", c.sidebarProjectGroupingMode != dc.sidebarProjectGroupingMode),
      ("Unpin confirmation", c.confirmThreadUnpin != dc.confirmThreadUnpin),
      ("Archive confirmation", c.confirmThreadArchive != dc.confirmThreadArchive),
      ("Delete confirmation", c.confirmThreadDelete != dc.confirmThreadDelete),
      ("Quit shortcut", c.confirmQuit != dc.confirmQuit),
      ("Context window indicator", c.contextWindowMeterEnabled != dc.contextWindowMeterEnabled),
    ]
    if !model.targets.isEmpty {
      let s = model.server
      labels += [
        ("Response streaming", s.responseStreamingMode != ds.responseStreamingMode),
        ("Provider update checks", s.enableProviderUpdateChecks != ds.enableProviderUpdateChecks),
        ("Continue threads after restarts", s.continueThreadsAfterServerUpdate != ds.continueThreadsAfterServerUpdate),
        ("Auto-settle inactive threads", s.sidebarAutoSettleAfterDays != ds.sidebarAutoSettleAfterDays),
        ("Auto-settle merged threads", s.sidebarAutoSettleOnMerge != ds.sidebarAutoSettleOnMerge),
        ("Background activity", !BackgroundActivityPolicy.isDefault(s)),
        ("New thread mode", s.defaultThreadEnvMode != nil),
        ("New worktrees start from origin", s.newWorktreesStartFromOrigin != ds.newWorktreesStartFromOrigin),
        ("Add project base directory", s.addProjectBaseDirectory != ds.addProjectBaseDirectory),
        ("Text generation model", s.textGenerationModelSelection != ds.textGenerationModelSelection),
      ]
    }
    return labels.filter(\.1).map(\.0)
  }

  static func restore(_ model: SettingsModel) {
    model.updateClient { c in
      c.notificationMode = dc.notificationMode
      c.inAppNotificationsEnabled = dc.inAppNotificationsEnabled
      c.timestampFormat = dc.timestampFormat
      c.diffIgnoreWhitespace = dc.diffIgnoreWhitespace
      c.diffFilesCollapsed = dc.diffFilesCollapsed
      c.diffLayout = dc.diffLayout
      c.proactivePanelsEnabled = dc.proactivePanelsEnabled
      c.showSkillsInSlashMenu = dc.showSkillsInSlashMenu
      c.composerRichTextEnabled = dc.composerRichTextEnabled
      c.composerCollapseOnScroll = dc.composerCollapseOnScroll
      c.sendShortcut = dc.sendShortcut
      c.followUpBehavior = dc.followUpBehavior
      c.sidebarProjectGroupingMode = dc.sidebarProjectGroupingMode
      c.confirmThreadUnpin = dc.confirmThreadUnpin
      c.confirmThreadArchive = dc.confirmThreadArchive
      c.confirmThreadDelete = dc.confirmThreadDelete
      c.confirmQuit = dc.confirmQuit
      c.contextWindowMeterEnabled = dc.contextWindowMeterEnabled
    }
    guard !model.targets.isEmpty else { return }
    if model.scope.isProject {
      model.clearOverrides(projectKeys)
      return
    }
    var patch = BackgroundActivityPolicy.profilePatch(.balanced)
    patch.responseStreamingMode = ds.responseStreamingMode
    patch.enableProviderUpdateChecks = ds.enableProviderUpdateChecks
    patch.continueThreadsAfterServerUpdate = ds.continueThreadsAfterServerUpdate
    patch.sidebarAutoSettleAfterDays = .some(ds.sidebarAutoSettleAfterDays)
    patch.sidebarAutoSettleOnMerge = ds.sidebarAutoSettleOnMerge
    patch.defaultThreadEnvMode = .some(nil)
    patch.newWorktreesStartFromOrigin = ds.newWorktreesStartFromOrigin
    patch.addProjectBaseDirectory = ds.addProjectBaseDirectory
    let text = ds.textGenerationModelSelection
    patch.textGenerationModelSelection = ServerSettingsPatchTextGenerationModelSelection(instanceId: text.instanceId, model: text.model, options: text.options ?? [])
    model.edit(patch)
  }
}
