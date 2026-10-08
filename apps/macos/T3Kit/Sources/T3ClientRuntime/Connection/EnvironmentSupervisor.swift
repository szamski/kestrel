import Foundation
import T3Contracts

/// The single owner of transport retry for one environment (port of connection/supervisor.ts).
///
/// - Transient failures retry with capped backoff (3/4/8/16 s); a connection that stayed up for
///   30 s resets the ladder.
/// - Offline waits for the network; blocked (authentication, permission, ...) waits for an
///   explicit wakeup, because retrying cannot change the outcome.
/// - Foregrounding wakes a pending retry immediately, leaves an ordinary in-flight attempt alone
///   and probes an established session before replacing it.
/// - A session is ready only after its first `subscribeServerConfig` snapshot (the driver's job).
/// - Mutations are never replayed here; their retry rules belong to the operation.
public actor EnvironmentSupervisor {
  public static let retryDelaysMs: [Int64] = [3_000, 4_000, 8_000, 16_000]
  public static let establishmentTimeout: Duration = .seconds(15)
  public static let probeTimeout: Duration = .seconds(15)
  public static let probeTimeoutAfterLongBackground: Duration = .seconds(3)
  public static let backoffResetAfterMs: Int64 = 30_000

  public nonisolated let entry: EnvironmentConnectionEntry
  public nonisolated let state: ValueHub<SupervisorConnectionState>
  /// The current ready session, nil while connecting, backing off or blocked.
  public nonisolated let session = ValueHub<(any EnvironmentSession)?>(nil)
  public nonisolated let prepared = ValueHub<PreparedConnection?>(nil)

  private enum Signal: Sendable {
    case connectRequested, disconnectRequested, retryRequested
    case networkChanged(NetworkStatus)
    case wakeup(ConnectionWakeup)
  }

  private struct Intent { var desired: Bool; var network: NetworkStatus }

  private let driver: any ConnectionDriving
  private let clock: any RuntimeClock
  private let onConfigEvent: @Sendable (ServerConfigStreamEvent) -> Void
  private let signals = SignalQueue<Signal>()
  private var intent: Intent
  private var resetRetryState = false
  /// Set when a foreground probe fails or times out: the follow-up reconnect skips the first backoff rung.
  private var wakeProbeFailed = false
  private var runTask: Task<Void, Never>?

  public init(
    entry: EnvironmentConnectionEntry, driver: any ConnectionDriving, clock: any RuntimeClock = SystemClock(),
    network: NetworkStatus = .unknown, initiallyDesired: Bool = false,
    onConfigEvent: @escaping @Sendable (ServerConfigStreamEvent) -> Void = { _ in }
  ) {
    self.entry = entry
    self.driver = driver
    self.clock = clock
    self.onConfigEvent = onConfigEvent
    intent = Intent(desired: initiallyDesired, network: network)
    state = ValueHub(
      !initiallyDesired
        ? Self.availableState(network: network, generation: 0)
        : network == .offline
          ? Self.offlineState(network: network, generation: 0, attempt: 0, lastFailure: nil)
          : Self.connectingState(network: network, generation: 0, attempt: 1, lastFailure: nil, stage: .preparing))
  }

  // MARK: Public intents

  /// Starts the retry loop. Idempotent.
  public func start() {
    guard runTask == nil else { return }
    runTask = Task { await self.run() }
  }

  public func connect() {
    intent.desired = true
    signals.offer(.connectRequested)
  }

  public func disconnect() {
    intent.desired = false
    signals.offer(.disconnectRequested)
  }

  /// Retry now, resetting the backoff ladder.
  public func retryNow() {
    resetRetryState = true
    signals.offer(.retryRequested)
  }

  public func networkChanged(_ network: NetworkStatus) {
    guard intent.network != network else { return }
    intent.network = network
    signals.offer(.networkChanged(network))
  }

  public func wake(_ reason: ConnectionWakeup) { signals.offer(.wakeup(reason)) }

  /// Stops the loop and closes the current session.
  public func shutdown() async {
    runTask?.cancel()
    signals.close()
    await runTask?.value
    runTask = nil
    await clearLease(close: true)
  }

  // MARK: States

  private static func availableState(network: NetworkStatus, generation: Int) -> SupervisorConnectionState {
    SupervisorConnectionState(desired: false, network: network, phase: .available, stage: nil, attempt: 0, generation: generation, lastFailure: nil, retryAt: nil)
  }
  private static func offlineState(network: NetworkStatus, generation: Int, attempt: Int, lastFailure: ConnectionAttemptError?) -> SupervisorConnectionState {
    SupervisorConnectionState(desired: true, network: network, phase: .offline, stage: nil, attempt: attempt, generation: generation, lastFailure: lastFailure, retryAt: nil)
  }
  private static func connectingState(
    network: NetworkStatus, generation: Int, attempt: Int, lastFailure: ConnectionAttemptError?, stage: ConnectionStage?
  ) -> SupervisorConnectionState {
    SupervisorConnectionState(desired: true, network: network, phase: .connecting, stage: stage, attempt: attempt, generation: generation, lastFailure: lastFailure, retryAt: nil)
  }

  private func retryDelayMs(failureCount: Int) -> Int64 {
    Self.retryDelaysMs[min(failureCount, Self.retryDelaysMs.count - 1)]
  }

  private func clearLease(close: Bool = false) async {
    let current = session.value
    session.set(nil)
    prepared.set(nil)
    if close { await current?.close() }
  }

  // MARK: Loop

  private enum AttemptOutcome {
    case interrupted(established: Bool, stable: Bool, resetRetry: Bool)
    case failure(established: Bool, stable: Bool, error: ConnectionAttemptError)
    var established: Bool {
      switch self {
      case .interrupted(let e, _, _), .failure(let e, _, _): e
      }
    }
    var stable: Bool {
      switch self {
      case .interrupted(_, let s, _), .failure(_, let s, _): s
      }
    }
  }

  private func run() async {
    var failureCount = 0
    var generation = 0
    var latestFailure: ConnectionAttemptError?

    while !Task.isCancelled {
      if resetRetryState {
        resetRetryState = false
        failureCount = 0
        latestFailure = nil
      }
      let current = intent
      if !current.desired {
        failureCount = 0
        latestFailure = nil
        await clearLease()
        state.set(Self.availableState(network: current.network, generation: generation))
        guard await waitForSignal() != nil else { return }
        continue
      }
      if current.network == .offline {
        await clearLease()
        state.set(Self.offlineState(network: current.network, generation: generation, attempt: failureCount + 1, lastFailure: latestFailure))
        guard let activated = await waitForSignal() else { return }
        if activated { failureCount = 0 }
        continue
      }

      let attempt = failureCount + 1
      let nextGeneration = generation + 1
      let outcome = await runAttempt(attempt: attempt, generation: nextGeneration, lastFailure: latestFailure)
      if Task.isCancelled { return }
      // Consumed on every iteration so a stale marker can never leak into a later, unrelated failure.
      let failedWakeProbe = wakeProbeFailed
      wakeProbeFailed = false
      if outcome.established {
        generation = nextGeneration
        if outcome.stable {
          failureCount = 0
          latestFailure = nil
        }
      }
      switch outcome {
      case .interrupted(_, _, let resetRetry):
        if resetRetry { failureCount = 0 }
        continue
      case .failure(_, _, let error):
        latestFailure = error
        if error.isBlocked {
          let blocked = intent
          state.set(
            SupervisorConnectionState(
              desired: blocked.desired, network: blocked.network, phase: .blocked, stage: nil, attempt: attempt, generation: generation,
              lastFailure: error, retryAt: nil))
          guard let activated = await waitForSignal() else { return }
          if activated { failureCount = 0 }
          continue
        }
        if failedWakeProbe {
          // The wake probe found a dead transport while the user is returning to the app: reconnect
          // at once instead of sleeping the first backoff rung. Only this attempt skips the ladder.
          failureCount = 0
          state.set(Self.connectingState(network: intent.network, generation: generation, attempt: 1, lastFailure: error, stage: .preparing))
          continue
        }
        failureCount += 1
        let delay = retryDelayMs(failureCount: failureCount - 1)
        let failed = intent
        state.set(
          SupervisorConnectionState(
            desired: failed.desired, network: failed.network, phase: .backoff, stage: nil, attempt: attempt, generation: generation,
            lastFailure: error, retryAt: clock.nowMilliseconds() + delay))
        guard let activated = await waitForRetrySignal(delayMs: delay) else { return }
        if activated { failureCount = 0 }
      }
    }
  }

  /// Waits for any signal. True when it was an application-active wakeup; nil when cancelled.
  private func waitForSignal() async -> Bool? {
    guard let signal = await signals.take() else { return nil }
    if case .wakeup(let reason) = signal { return reason.isApplicationActive }
    return false
  }

  private func waitForRetrySignal(delayMs: Int64) async -> Bool? {
    enum Event: Sendable { case elapsed, signal(Signal), cancelled }
    let clock = clock, signals = signals
    let (winner, losers) = await raceFirst([
      { @Sendable in
        do { try await clock.sleep(for: .milliseconds(delayMs)) } catch { return Event.cancelled }
        return .elapsed
      },
      { @Sendable in await signals.take().map(Event.signal) ?? .cancelled },
    ])
    for case .signal(let signal) in losers { signals.pushFront(signal) }
    switch winner {
    case .elapsed: return false
    case .cancelled: return nil
    case .signal(let signal):
      if case .wakeup(let reason) = signal { return reason.isApplicationActive }
      return false
    }
  }

  // MARK: Attempt

  private enum EstablishmentEvent: Sendable {
    case completed(Result<ConnectionLease, ConnectionAttemptError>)
    case interrupted(resetRetry: Bool, signal: Signal)
    case timedOut
    case cancelled
  }

  private func runAttempt(attempt: Int, generation: Int, lastFailure: ConnectionAttemptError?) async -> AttemptOutcome {
    prepared.set(nil)
    let driver = driver, entry = entry, clock = clock, signals = signals
    let hub = state, preparedHub = prepared
    let sink = onConfigEvent
    let networkNow = intent.network
    hub.set(Self.connectingState(network: networkNow, generation: generation, attempt: attempt, lastFailure: lastFailure, stage: .preparing))

    let (winner, losers) = await raceFirst([
      { @Sendable in
        do {
          let lease = try await driver.connect(
            entry,
            progress: { progress in
              let stage: ConnectionStage
              switch progress {
              case .preparing: stage = .preparing
              case .opening(let p): stage = .opening; preparedHub.set(p)
              case .synchronizing(let p): stage = .synchronizing; preparedHub.set(p)
              }
              hub.set(Self.connectingState(network: networkNow, generation: generation, attempt: attempt, lastFailure: lastFailure, stage: stage))
            }, onConfigEvent: sink)
          if Task.isCancelled {
            await lease.session.close()
            return EstablishmentEvent.cancelled
          }
          return .completed(.success(lease))
        } catch let error as ConnectionAttemptError {
          return .completed(.failure(error))
        } catch is CancellationError {
          return .cancelled
        } catch {
          return .completed(.failure(.transient(.transport, detail: "\(entry.label) connection failed unexpectedly.")))
        }
      },
      { @Sendable in
        // Anything that makes the attempt pointless interrupts it; a plain foreground wake does not.
        while let signal = await signals.take() {
          switch signal {
          case .disconnectRequested, .retryRequested: return .interrupted(resetRetry: false, signal: signal)
          case .networkChanged(.offline): return .interrupted(resetRetry: false, signal: signal)
          case .wakeup(.applicationActiveReconnect): return .interrupted(resetRetry: true, signal: signal)
          default: continue
          }
        }
        return .cancelled
      },
      { @Sendable in
        do { try await clock.sleep(for: Self.establishmentTimeout) } catch { return .cancelled }
        return .timedOut
      },
    ])
    // Put back what a losing waiter consumed; release what a losing attempt opened.
    for loser in losers {
      switch loser {
      case .interrupted(_, let signal): signals.pushFront(signal)
      case .completed(.success(let lease)): await lease.session.close()
      default: break
      }
    }

    switch winner {
    case .cancelled:
      return .interrupted(established: false, stable: false, resetRetry: false)
    case .interrupted(let resetRetry, _):
      return .interrupted(established: false, stable: false, resetRetry: resetRetry)
    case .timedOut:
      return .failure(established: false, stable: false, error: .transient(.timeout, detail: "\(entry.label) did not respond during connection setup."))
    case .completed(.failure(let error)):
      return .failure(established: false, stable: false, error: error)
    case .completed(.success(let lease)):
      let current = intent
      if !current.desired || current.network == .offline {
        await lease.session.close()
        return .interrupted(established: false, stable: false, resetRetry: false)
      }
      let connectedAt = clock.nowMilliseconds()
      prepared.set(lease.prepared)
      session.set(lease.session)
      state.set(
        SupervisorConnectionState(
          desired: true, network: current.network, phase: .connected, stage: nil, attempt: attempt, generation: generation,
          lastFailure: nil, retryAt: nil))
      let result = await superviseConnected(lease)
      await clearLease(close: true)
      let stable = clock.nowMilliseconds() - connectedAt >= Self.backoffResetAfterMs
      switch result {
      case .stop(let resetRetry): return .interrupted(established: true, stable: stable, resetRetry: resetRetry)
      case .failed(let error): return .failure(established: true, stable: stable, error: error)
      }
    }
  }

  // MARK: Established connection

  private enum ConnectedResult: Sendable { case stop(resetRetry: Bool), failed(ConnectionAttemptError) }
  private enum MonitorEvent: Sendable {
    case closed(ConnectionAttemptError)
    case monitored(ConnectedResult, taken: Signal?)
    case cancelled
  }

  private func superviseConnected(_ lease: ConnectionLease) async -> ConnectedResult {
    let signals = signals
    let (winner, losers) = await raceFirst([
      { @Sendable in .closed(await lease.session.waitUntilClosed()) },
      { @Sendable in await self.monitor(lease) },
    ])
    for case .monitored(_, let taken?) in losers { signals.pushFront(taken) }
    switch winner {
    case .closed(let error): return .failed(error)
    case .monitored(let result, _): return result
    case .cancelled: return .stop(resetRetry: false)
    }
  }

  private func monitor(_ lease: ConnectionLease) async -> MonitorEvent {
    while true {
      guard let signal = await signals.take() else { return .cancelled }
      switch signal {
      case .disconnectRequested, .retryRequested: return .monitored(.stop(resetRetry: false), taken: signal)
      case .networkChanged(let network):
        if network == .offline { return .monitored(.stop(resetRetry: false), taken: signal) }
      case .connectRequested: break
      case .wakeup(let reason):
        if reason == .applicationActiveReconnect {
          // A long background suspension can leave a dead socket without a close event: replace it.
          return .monitored(.stop(resetRetry: true), taken: signal)
        }
        if reason == .applicationActive || reason == .applicationActiveProbe {
          let timeout = reason == .applicationActiveProbe ? Self.probeTimeoutAfterLongBackground : Self.probeTimeout
          switch await probe(lease, timeout: timeout) {
          case .ok: break
          case .failed(let error):
            wakeProbeFailed = true
            return .monitored(.failed(error), taken: nil)
          case .stop(let resetRetry, let signal): return .monitored(.stop(resetRetry: resetRetry), taken: signal)
          case .cancelled: return .cancelled
          }
        }
      }
    }
  }

  private enum ProbeOutcome: Sendable {
    case ok, failed(ConnectionAttemptError), cancelled
    case stop(resetRetry: Bool, signal: Signal)
  }

  /// Probes while still reacting to signals, like the TypeScript `raceFirst(probe, take)` loop.
  private func probe(_ lease: ConnectionLease, timeout: Duration) async -> ProbeOutcome {
    enum ProbeResult: Sendable { case ok, failed(ConnectionAttemptError), cancelled }
    let clock = clock, signals = signals, label = entry.label
    let done = Deferred<ProbeResult>()
    let probeTask = Task {
      let (winner, _) = await raceFirst([
        { @Sendable in
          do throws(ConnectionAttemptError) { try await lease.session.probe() } catch { return ProbeResult.failed(error) }
          return .ok
        },
        { @Sendable in
          do { try await clock.sleep(for: timeout) } catch { return .cancelled }
          return .failed(.transient(.timeout, detail: "\(label) did not respond to a connection health check."))
        },
      ])
      done.complete(.success(winner))
    }
    enum Step: Sendable { case probe(ProbeResult), signal(Signal), cancelled }
    while true {
      let (winner, losers) = await raceFirst([
        { @Sendable in (try? await done.value()).map(Step.probe) ?? .cancelled },
        { @Sendable in await signals.take().map(Step.signal) ?? .cancelled },
      ])
      for case .signal(let signal) in losers { signals.pushFront(signal) }
      switch winner {
      case .cancelled:
        probeTask.cancel()
        return .cancelled
      case .probe(.ok): return .ok
      case .probe(.failed(let error)): return .failed(error)
      case .probe(.cancelled): return .cancelled
      case .signal(let signal):
        switch signal {
        case .disconnectRequested, .retryRequested:
          probeTask.cancel()
          return .stop(resetRetry: false, signal: signal)
        case .networkChanged(.offline):
          probeTask.cancel()
          return .stop(resetRetry: false, signal: signal)
        case .wakeup(.applicationActiveReconnect):
          probeTask.cancel()
          return .stop(resetRetry: true, signal: signal)
        default: continue
        }
      }
    }
  }
}
