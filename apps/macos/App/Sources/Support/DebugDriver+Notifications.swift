#if DEBUG
import AppKit
import T3ClientRuntime
import T3Contracts
import UserNotifications

/// Driver steps of the notification and onboarding checks (`-T3Driver`):
/// - `onboard:<connection|agents|projects>` shows the setup sheet at that step (launch with `-T3ForceOnboarding 1` so
///   nothing is saved), `shotonboard:<name>` captures the sheet.
/// - `notifydemo:<project label>` creates a scratch thread, sends one tiny turn, leaves the thread, waits for the in-app
///   banner (launch with `-T3NotifyInApp 1 -T3NotifyAssumeFocused 1`), captures it, opens the thread from the banner and
///   deletes the thread again.
/// - `route:<url>` runs a link through the route parser and opens it; `notifystatus` logs the system permission.
extension DebugDriver {
  func runNotificationStep(_ name: String, _ arg: String) async -> Bool {
    switch name {
    case "onboard":
      let model = app.onboarding
      if !model.isPresented { model.present() }
      switch arg {
      case "agents": model.go(to: .agents)
      case "projects": model.go(to: .projects)
      default: model.go(to: .connection)
      }
      await sleep(arg == "projects" ? 6 : 1.5)
    case "shotonboard":
      if let sheet = window?.attachedSheet { capture(sheet, name: arg) } else { say("no onboarding sheet") }
    case "notifystatus":
      let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus.rawValue
      say("notification permission=\(status) dockBadge=\(NSApp.dockTile.badgeLabel ?? "nil") banners=\(app.notifications.banners.count)")
    case "route":
      if let route = AppRouteParser.parse(arg) {
        app.open(route)
        say("route \(route) selection=\(app.selection.map(\.description) ?? "nil") error=\(app.errorMessage ?? "-")")
      } else { say("route not parsed: \(arg)") }
    case "notifydemo": await notifyDemo(arg)
    default: return false
    }
    return true
  }

  private func notifyDemo(_ projectLabel: String) async {
    guard let group = app.runtime.projectGroups.first(where: { $0.label == projectLabel }), let model = app.runtime.sidebar.rows.first?.thread.shell.modelSelection else {
      say("notifydemo: no project \(projectLabel) or no model")
      return
    }
    let project = group.representative
    // Cached rows show before the server answers; the thread needs a live connection.
    for _ in 0..<300 where app.runtime.environments.first(where: { $0.environmentId == project.environmentId })?.connection.phase != .connected { await sleep(0.2) }
    for _ in 0..<100 where app.runtime.shells[project.environmentId]?.status != .live { await sleep(0.2) }
    let key: ScopedThreadKey
    do {
      let id = try await app.runtime.createThread(environmentId: project.environmentId, projectId: project.projectId, title: "[notify] scratch", modelSelection: model)
      key = ScopedThreadKey(environmentId: project.environmentId, threadId: id)
    } catch { say("notifydemo: create failed: \(AppModel.describe(error))"); return }
    app.selection = key
    for _ in 0..<100 where app.detail?.thread == nil { await sleep(0.1) }
    do { _ = try await app.runtime.sendMessage(key, text: "Reply with the single word OK.") } catch { say("notifydemo: send failed: \(AppModel.describe(error))") }
    await sleep(0.5)
    app.selection = nil  // the thread is no longer the one in view, so its completion may announce itself
    say("notifydemo: left the thread; waiting for the banner")
    for _ in 0..<240 where app.notifications.banners.isEmpty { await sleep(0.5) }
    await sleep(0.6)
    if let banner = app.notifications.banners.first {
      say("notifydemo: banner \(banner.event.kind) \"\(banner.event.threadTitle)\" count=\(app.notifications.banners.count)")
      capture(window, name: "notify-banner")
      app.notifications.open(banner)
      await sleep(0.5)
      say("notifydemo: opened from banner, selection matches=\(app.selection == key) banners left=\(app.notifications.banners.count)")
    } else { say("notifydemo: no banner appeared") }
    app.selection = nil
    do { try await app.runtime.deleteThread(key); say("notifydemo: scratch thread deleted") } catch { say("notifydemo: delete failed: \(AppModel.describe(error))") }
  }
}
#endif
