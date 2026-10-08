import Foundation
import T3Contracts

/// What the app knows about the user's presence; the runtime cannot observe windows itself.
public struct ActivityContext: Sendable, Equatable {
  public var visible: Bool
  public var focused: Bool
  /// Epoch milliseconds of the last pointer/keyboard interaction.
  public var lastInteractionAtMs: Int64
  public init(visible: Bool = true, focused: Bool = true, lastInteractionAtMs: Int64) {
    self.visible = visible
    self.focused = focused
    self.lastInteractionAtMs = lastInteractionAtMs
  }
}

/// Background activity lease (apps/web `backgroundActivityReporter.ts`): every 25 seconds, and when the
/// app's presence changes, tell each connected environment this client is looking at it, so the server
/// keeps provider status and similar background work fresh (the lease lives 45 seconds).
public actor ActivityReporter {
  public static let interval: Duration = .seconds(25)
  public static let leaseTTLMs: Double = 45_000
  static let debounce: Duration = .milliseconds(250)

  private let clock: any RuntimeClock
  private let clientId: String
  private let runtimes: @Sendable () -> [EnvironmentRuntime]
  private var context: ActivityContext
  private let requests = SignalQueue<Void>()
  private var task: Task<Void, Never>?

  public init(clock: any RuntimeClock, clientId: String, runtimes: @escaping @Sendable () -> [EnvironmentRuntime]) {
    self.clock = clock
    self.clientId = clientId
    self.runtimes = runtimes
    context = ActivityContext(lastInteractionAtMs: clock.nowMilliseconds())
  }

  /// A stable per-install id, so the server can tell this client's leases apart.
  public static func persistentClientId(defaults: UserDefaults = .standard) -> String {
    let key = "t3.backgroundActivity.clientId"
    if let existing = defaults.string(forKey: key), !existing.isEmpty { return existing }
    let next = UUID().uuidString.lowercased()
    defaults.set(next, forKey: key)
    return next
  }

  public func start() {
    guard task == nil else { return }
    task = Task { await self.run() }
  }

  public func stop() async {
    task?.cancel()
    requests.close()
    await task?.value
    task = nil
  }

  public func update(visible: Bool, focused: Bool) {
    guard visible != context.visible || focused != context.focused else { return }
    context.visible = visible
    context.focused = focused
    requests.offer(())
  }

  /// A pointer or key event; the first one after an idle period reports at once.
  public func recordInteraction() {
    let now = clock.nowMilliseconds()
    let wasRecent = Self.wasRecentlyInteracted(lastInteractionAtMs: context.lastInteractionAtMs, observedAtMs: now)
    context.lastInteractionAtMs = now
    if !wasRecent { requests.offer(()) }
  }

  public func requestReport() { requests.offer(()) }

  static func wasRecentlyInteracted(lastInteractionAtMs: Int64, observedAtMs: Int64) -> Bool {
    lastInteractionAtMs <= observedAtMs && Double(observedAtMs - lastInteractionAtMs) <= leaseTTLMs
  }

  /// The report sent to one environment.
  func makeReport(environmentId: EnvironmentId, observedAtMs: Int64) -> ClientActivityReportInput {
    ClientActivityReportInput(
      environmentId: environmentId, clientId: clientId, clientKind: .desktopRenderer, visible: context.visible, focused: context.focused,
      recentlyInteracted: Self.wasRecentlyInteracted(lastInteractionAtMs: context.lastInteractionAtMs, observedAtMs: observedAtMs),
      appState: context.visible ? .active : .background, scopes: [.providerStatus(BackgroundScopeProviderStatus(instanceId: nil))],
      ttlMs: Self.leaseTTLMs, observedAt: IsoTimestamp.format(milliseconds: Double(observedAtMs)))
  }

  private func report() async {
    let observedAt = clock.nowMilliseconds()
    for runtime in runtimes() {
      await runtime.reportClientActivity(makeReport(environmentId: runtime.entry.environmentId, observedAtMs: observedAt))
    }
  }

  private func run() async {
    enum Event: Sendable { case tick, request, cancelled }
    while !Task.isCancelled {
      await report()
      let clock = clock, requests = requests
      let (winner, losers) = await raceFirst([
        { @Sendable in
          do { try await clock.sleep(for: Self.interval) } catch { return Event.cancelled }
          return .tick
        },
        { @Sendable in await requests.take() == nil ? .cancelled : .request },
      ])
      for case .request in losers { requests.pushFront(()) }
      switch winner {
      case .cancelled: return
      case .tick: break
      case .request:
        // Coalesce a burst of presence changes into one report.
        do { try await clock.sleep(for: Self.debounce) } catch { return }
      }
    }
  }
}
