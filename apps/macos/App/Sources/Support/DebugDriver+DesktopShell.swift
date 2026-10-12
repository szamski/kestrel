#if DEBUG
import AppKit
import T3ClientRuntime
import T3Contracts

/// Driver steps of the desktop-shell checks (`-T3Driver`), as `shell:<step>`:
/// - `shell:status` logs the updater (feed configured, state line, channel), the "Check for Updates…" menu item and the `t3 app` socket.
/// - `shell:settingspage:<raw page name>` switches the open Settings window to that page; `shell:deleteproject:<path>` removes the project at that
///   path from the local environment (the cleanup of what `t3 app` created in a check).
/// - `shell:serverupdate` asks the local server to update (`server.updateServer`), as a remote client's "Update server" does: the server sends
///   `requestDesktopUpdate` over the control channel and waits for this app's report. Without a feed the answer is the app's refusal.
/// - `shell:tallsettings` grows the Settings window to the screen height; `shell:scrollsettings[:<0..1>]` scrolls its page to that fraction (default
///   the bottom, where the About section of General is); `shell:shotsettings:<name>` captures the window as it is.
extension DebugDriver {
  func runDesktopShellStep(_ step: String) async {
    let updates = UpdateController.shared
    let bits = step.split(separator: ":", maxSplits: 1).map(String.init)
    let arg = bits.first ?? "", value = bits.count > 1 ? bits[1] : ""
    let pages = SettingsPage.allCases.map(\.title)
    let settingsWindow = NSApp.windows.first { $0.isVisible && pages.contains($0.title) }
    switch arg {
    case "status":
      say("updates available=\(updates.isAvailable) enabled=\(updates.state.enabled) status=\(updates.state.status.rawValue) channel=\(updates.channel.rawValue) auto=\(updates.automaticChecks) summary=\(updates.state.summary)")
      let appMenu = NSApp.mainMenu?.items.first?.submenu
      for item in appMenu?.items ?? [] where item.title.contains("Update") || item.title.hasPrefix("About") || item.title.hasPrefix("Settings") {
        say("menu item \(item.title) enabled=\(item.isEnabled)")
      }
      let path = DesktopActivation.shared.socketPath
      var info = stat()
      say("activation socket=\(path ?? "none") exists=\(path.map { lstat($0, &info) == 0 } ?? false)")
    case "settingspage":
      app.settingsPageRequest = SettingsPage(rawValue: value)
      await sleep(1)
    case "deleteproject":
      let path = ProjectGrouping.normalizePath(value)
      guard let id = AppModel.storedLocalEnvironmentId, let project = app.runtime.projects.first(where: { $0.environmentId == id && ProjectGrouping.normalizePath($0.project.workspaceRoot) == path }) else {
        return say("shell: no project at \(value)")
      }
      do { try await app.runtime.deleteProject(environmentId: id, projectId: project.projectId); say("deleted project \(project.project.title)") } catch { say("shell: delete failed: \(AppModel.describe(error))") }
    case "serverupdate":
      guard let id = AppModel.storedLocalEnvironmentId, let session = await app.runtime.runtime(for: id)?.supervisor.session.value else { return say("shell: no local session") }
      do {
        let result = try await session.call(Rpc.serverUpdateServer, ServerSelfUpdateInput(targetVersion: "9.9.9"))
        say("shell: serverupdate succeeded unexpectedly: \(result)")
      } catch { say("shell: serverupdate failed as expected: \(error)") }
    case "tallsettings":
      guard let settings = settingsWindow else { return say("shell: no settings window") }
      settings.setContentSize(NSSize(width: 1040, height: ((settings.screen ?? NSScreen.main)?.visibleFrame.height ?? 900) - 60))
      await sleep(1.5)
    case "shotsettings":
      guard let settings = settingsWindow else { return say("shell: no settings window") }
      capture(settings, name: value)
    case "scrollsettings":
      guard let settings = settingsWindow else { return say("shell: no settings window") }
      let fraction = Double(value) ?? 1
      func scrollViews(in view: NSView) -> [NSScrollView] { ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) } }
      for scroll in scrollViews(in: settings.contentView!) {
        guard let document = scroll.documentView else { continue }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height) * fraction))
        scroll.reflectScrolledClipView(scroll.contentView)
      }
      await sleep(1)
    default:
      say("shell: unknown step \(step)")
    }
  }
}
#endif
