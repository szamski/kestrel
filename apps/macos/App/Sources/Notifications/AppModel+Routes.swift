import AppKit
import T3ClientRuntime
import T3Contracts

extension AppModel {
  /// Opens where a link or a notification click leads (`AppRouteParser`). Ids come from outside the app, so a route
  /// only selects what already exists, and a pairing link is confirmed before it adds a server.
  func open(_ route: AppRoute) {
    showMainWindow()
    switch route {
    case .thread(let environmentId, let threadId):
      let known = runtime.shells.flatMap { id, state in (state.snapshot?.threads ?? []).map { ScopedThreadKey(environmentId: id, threadId: $0.id) } }
      let match = known.first { $0.threadId.rawValue == threadId && (environmentId == nil || $0.environmentId.rawValue == environmentId) }
      if let match { selection = match } else { errorMessage = "That thread is not available in Kestrel." }
    case .project(let environmentId, let projectId):
      let match = runtime.projects.first { $0.projectId.rawValue == projectId && (environmentId == nil || $0.environmentId.rawValue == environmentId) }
      if let match { startNewThread(in: match, label: match.project.title) } else { errorMessage = "That project is not available in Kestrel." }
    case .pairing(let url):
      let host = URL(string: url)?.host() ?? url
      confirm("Add the server at \u{201C}\(host)\u{201D}?", message: "Kestrel pairs with it and shows its threads. Only continue if you trust whoever sent this link.", confirmTitle: "Pair") { [self] in
        run { [runtime] in try await runtime.addEnvironment(pairingURL: url) }
      }
    }
  }

  func showMainWindow() {
    NSApp.activate()
    guard let window = NSApp.windows.first(where: { $0.title == "Kestrel" }) ?? NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
  }
}
