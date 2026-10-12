import AppKit
import Observation
import SwiftUI
import T3ClientRuntime
import T3Contracts
import UserNotifications

/// Thread notifications (the web's `ThreadNotificationCoordinator` and the desktop's badge): watches every live
/// environment's shell, lets `ThreadNotificationTracker` decide what happened, and delivers it by Settings › General:
/// a sound, an in-app banner while the app has focus on another thread, a system notification while it does not.
/// Pending system notifications count on the Dock badge until the app is focused again.
@MainActor @Observable
final class ThreadNotifications: NSObject, UNUserNotificationCenterDelegate {
  struct Banner: Identifiable, Equatable {
    let id = UUID()
    let event: ThreadNotificationEvent
  }

  private(set) var banners: [Banner] = []
  /// System permission of the Notifications mode; Settings shows a hint when it is denied.
  private(set) var permission: UNAuthorizationStatus = .notDetermined

  @ObservationIgnored weak var app: AppModel?
  @ObservationIgnored private let runtime: ClientRuntime
  @ObservationIgnored private let store: ClientSettingsStore
  @ObservationIgnored private var tracker = ThreadNotificationTracker()
  /// Identifiers of the system notifications posted since the app was last focused (the Dock badge count).
  @ObservationIgnored private var pending: Set<String> = []
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var sounds: [String: NSSound] = [:]
  @ObservationIgnored private static let bannerSeconds = 8.0
  @ObservationIgnored private static let maxBanners = 3

  init(runtime: ClientRuntime, store: ClientSettingsStore = .shared) {
    self.runtime = runtime
    self.store = store
  }

  func start() {
    guard tasks.isEmpty else { return }
    UNUserNotificationCenter.current().delegate = self
    refreshPermission()
    tasks.append(
      Task { @MainActor [self] in
        // Every shell change rescans: the tracker only reads a few fields per thread.
        for await _ in Observations({ self.runtime.shells }) { scan() }
      })
    tasks.append(
      Task { @MainActor [self] in
        var last: ClientSettingsSchemaNotificationMode?
        for await mode in Observations({ self.effective.mode }) where mode != last {
          last = mode
          modeChanged(mode)
        }
      })
    observers.append(
      NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.clearPending()
          self?.refreshPermission()
        }
      })
  }

  // MARK: Settings

  /// The device settings; Debug builds can override them per launch (`-T3NotifyMode`, `-T3NotifyInApp`) without touching the saved file.
  private var effective: (mode: ClientSettingsSchemaNotificationMode, inApp: Bool) {
    var client = store.client
    #if DEBUG
    let defaults = UserDefaults.standard
    if let raw = defaults.string(forKey: "T3NotifyMode") { client.notificationMode = .init(rawValue: raw) }
    if defaults.object(forKey: "T3NotifyInApp") != nil { client.inAppNotificationsEnabled = defaults.bool(forKey: "T3NotifyInApp") }
    #endif
    return (client.notificationMode, client.inAppNotificationsEnabled)
  }

  /// Choosing a mode with system notifications is the moment to ask for permission; no other mode ever prompts.
  private func modeChanged(_ mode: ClientSettingsSchemaNotificationMode) {
    clearPending()
    guard mode == .notifications || mode == .notificationsAndSound else { return }
    Task { await requestAuthorizationIfNeeded() }
  }

  func requestAuthorizationIfNeeded() async {
    let center = UNUserNotificationCenter.current()
    permission = await center.notificationSettings().authorizationStatus
    guard permission == .notDetermined else { return }
    // The sound is ours (the web's notifications are silent too), so the system only needs to show and badge.
    _ = try? await center.requestAuthorization(options: [.alert, .badge])
    permission = await center.notificationSettings().authorizationStatus
  }

  func refreshPermission() {
    Task { permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
  }

  // MARK: Events

  private func scan() {
    tracker.retain(Set(runtime.shells.keys))
    var events: [ThreadNotificationEvent] = []
    for (id, state) in runtime.shells {
      events += tracker.scan(environmentId: id, threads: state.status == .live ? state.v2?.threads : nil)
    }
    for event in events { deliver(event) }
  }

  private func deliver(_ event: ThreadNotificationEvent) {
    let settings = effective
    let decision = ThreadNotificationDelivery.decide(
      mode: settings.mode, inApp: settings.inApp, appFocused: Self.appIsFocused, isOpenThread: app?.selection == event.key)
    if decision.sound { play(event.kind) }
    switch decision.surface {
    case .banner: show(event)
    case .system: post(event)
    case .none: break
    }
  }

  /// The app is active and a window is on screen: the web's `visibilityState === "visible" && hasFocus()`.
  static var appIsFocused: Bool {
    #if DEBUG
    if UserDefaults.standard.bool(forKey: "T3NotifyAssumeFocused") { return true }  // automated runs: the app may not be frontmost
    #endif
    return NSApp.isActive && NSApp.windows.contains { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
  }

  // MARK: Sound

  private func play(_ kind: ThreadNotificationKind) {
    let name = kind.soundIsCompletion ? "notification-completion" : "notification-input"
    if sounds[name] == nil, let url = Bundle.main.url(forResource: name, withExtension: "mp3") { sounds[name] = NSSound(contentsOf: url, byReference: true) }
    guard let sound = sounds[name] else { return }
    sound.stop()
    sound.play()
  }

  // MARK: Banners

  private func show(_ event: ThreadNotificationEvent) {
    let banner = Banner(event: event)
    withAnimation(.snappy(duration: 0.25)) {
      banners.removeAll { $0.event.key == event.key }
      banners.insert(banner, at: 0)
      if banners.count > Self.maxBanners { banners.removeLast(banners.count - Self.maxBanners) }
    }
    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: "\(event.kind.title): \(event.threadTitle)"])
    Task { [id = banner.id] in
      try? await Task.sleep(for: .seconds(Self.bannerSeconds))
      dismiss(id)
    }
  }

  func dismiss(_ id: UUID) {
    guard banners.contains(where: { $0.id == id }) else { return }
    withAnimation(.snappy(duration: 0.2)) { banners.removeAll { $0.id == id } }
  }

  func open(_ banner: Banner) {
    dismiss(banner.id)
    app?.open(.thread(environmentId: banner.event.key.environmentId.rawValue, threadId: banner.event.key.threadId.rawValue))
  }

  // MARK: System notifications and the Dock badge

  private func post(_ event: ThreadNotificationEvent) {
    guard let link = AppRouteParser.url(for: .thread(environmentId: event.key.environmentId.rawValue, threadId: event.key.threadId.rawValue)) else { return }
    Task {
      let center = UNUserNotificationCenter.current()
      let status = await center.notificationSettings().authorizationStatus
      permission = status
      guard status == .authorized || status == .provisional else { return }
      let content = UNMutableNotificationContent()
      content.title = event.kind.title
      content.body = event.threadTitle
      content.userInfo = ["route": link.absoluteString]
      // A newer notification of the same thread replaces the older one.
      guard (try? await center.add(UNNotificationRequest(identifier: event.id, content: content, trigger: nil))) != nil else { return }
      pending.insert(event.id)
      updateBadge()
    }
  }

  /// Focusing the app answers what the notifications announced (the desktop clears its badge the same way).
  private func clearPending() {
    guard !pending.isEmpty else { return }
    pending.removeAll()
    UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    updateBadge()
  }

  private func updateBadge() { NSApp.dockTile.badgeLabel = pending.isEmpty ? nil : String(pending.count) }

  private func clicked(id: String, route: String?) {
    pending.remove(id)
    updateBadge()
    if let route, let route = AppRouteParser.parse(route) { app?.open(route) }
  }

  // MARK: UNUserNotificationCenterDelegate

  /// The app is frontmost: the banner covers it, so the system shows nothing.
  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [] }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    let content = response.notification.request.content
    let (id, route) = (response.notification.request.identifier, content.userInfo["route"] as? String)
    await MainActor.run { clicked(id: id, route: route) }
  }
}
