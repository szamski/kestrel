import Foundation
import Testing
import T3Contracts
@testable import T3ClientRuntime

/// Supervisor behaviour with a manual clock and a scripted driver: no real time, no sockets.
@Suite(.timeLimit(.minutes(1))) struct SupervisorTests {
  func make(
    _ steps: [ScriptedDriver.Step] = [], network: NetworkStatus = .online, desired: Bool = true
  ) async -> (EnvironmentSupervisor, ScriptedDriver, ManualClock) {
    let driver = ScriptedDriver(steps)
    let clock = ManualClock()
    let supervisor = EnvironmentSupervisor(entry: Fixtures.entry(), driver: driver, clock: clock, network: network, initiallyDesired: desired)
    await supervisor.start()
    return (supervisor, driver, clock)
  }

  static let transient = ConnectionAttemptError.transient(.network, detail: "down")

  @Test func backoffLadderIsThreeFourEightSixteenThenFlat() async throws {
    let (supervisor, driver, clock) = await make(Array(repeating: .fail(Self.transient), count: 6))
    var delays: [Int64] = []
    for attempt in 1...5 {
      let state = await waitFor(supervisor.state) { $0.phase == .backoff && $0.attempt == attempt }
      delays.append(try #require(state.retryAt) - clock.nowMilliseconds())
      #expect(state.lastFailure == Self.transient)
      await clock.advance(by: .milliseconds(delays.last!))
    }
    #expect(delays == [3000, 4000, 8000, 16000, 16000])
    await driver.waitForAttempts(6)
    await supervisor.shutdown()
  }

  @Test func offlineWaitsForTheNetworkInsteadOfSpendingAttempts() async {
    let (supervisor, driver, _) = await make([.succeed(StubSession())], network: .offline)
    _ = await waitFor(supervisor.state) { $0.phase == .offline }
    #expect(driver.attempts == 0)
    await supervisor.networkChanged(.online)
    let state = await waitFor(supervisor.state) { $0.phase == .connected }
    #expect(state.generation == 1 && driver.attempts == 1)
    #expect(supervisor.session.value != nil)
    await supervisor.shutdown()
  }

  @Test func goingOfflineWhileConnectedDropsTheSessionAndWaits() async {
    let session = StubSession()
    let (supervisor, driver, _) = await make([.succeed(session), .succeed(StubSession())])
    _ = await waitFor(supervisor.state) { $0.phase == .connected }
    await supervisor.networkChanged(.offline)
    _ = await waitFor(supervisor.state) { $0.phase == .offline }
    #expect(supervisor.session.value == nil)
    #expect(session.closeCount.withLock { $0 } == 1)
    await supervisor.networkChanged(.online)
    _ = await waitFor(supervisor.state) { $0.phase == .connected && $0.generation == 2 }
    #expect(driver.attempts == 2)
    await supervisor.shutdown()
  }

  @Test func authenticationFailureWaitsForAnExplicitWakeup() async throws {
    let blocked = ConnectionAttemptError.blocked(.authentication, detail: "The environment credential is invalid.")
    let (supervisor, driver, clock) = await make([.fail(blocked), .succeed(StubSession())])
    let state = await waitFor(supervisor.state) { $0.phase == .blocked }
    #expect(state.lastFailure == blocked && state.retryAt == nil)
    #expect(clock.sleeperCount == 0, "a blocked connection must not run a retry timer")
    #expect(driver.attempts == 1)
    await supervisor.wake(.applicationActive)
    _ = await waitFor(supervisor.state) { $0.phase == .connected }
    #expect(driver.attempts == 2)
    await supervisor.shutdown()
  }

  @Test func foregroundWakesARetryImmediatelyAndResetsTheLadder() async throws {
    let (supervisor, driver, clock) = await make([.fail(Self.transient), .fail(Self.transient), .fail(Self.transient)])
    _ = await waitFor(supervisor.state) { $0.phase == .backoff && $0.attempt == 1 }
    await clock.advance(by: .seconds(3))
    let second = await waitFor(supervisor.state) { $0.phase == .backoff && $0.attempt == 2 }
    #expect(second.retryAt! - clock.nowMilliseconds() == 4000)
    await supervisor.wake(.applicationActive)  // no clock advance needed
    let third = await waitFor(supervisor.state) { $0.phase == .backoff && $0.attempt == 1 && $0.generation == 0 && driver.attempts == 3 }
    #expect(third.retryAt! - clock.nowMilliseconds() == 3000, "the ladder restarts after a foreground wake")
    await supervisor.shutdown()
  }

  @Test func foregroundLeavesAnInFlightAttemptAlone() async {
    let (supervisor, driver, _) = await make([.hang, .succeed(StubSession())])
    await driver.waitForAttempts(1)
    await supervisor.wake(.applicationActive)
    await supervisor.wake(.applicationActiveProbe)
    #expect(driver.attempts == 1)
    // A long-background reconnect does replace it, without any backoff.
    await supervisor.wake(.applicationActiveReconnect)
    _ = await waitFor(supervisor.state) { $0.phase == .connected }
    #expect(driver.attempts == 2)
    await supervisor.shutdown()
  }

  @Test func attemptsTimeOutAfterFifteenSeconds() async throws {
    let (supervisor, _, clock) = await make([.hang])
    await clock.advance(by: .seconds(14))
    #expect(supervisor.state.value.phase == .connecting)
    await clock.advance(by: .seconds(1))
    let state = await waitFor(supervisor.state) { $0.phase == .backoff }
    guard case .transient(.timeout, _, _)? = state.lastFailure else { Issue.record("expected a timeout, got \(String(describing: state.lastFailure))"); return }
    await supervisor.shutdown()
  }

  @Test func foregroundProbesAnEstablishedSessionAndKeepsItWhenHealthy() async {
    let session = StubSession()
    let (supervisor, driver, _) = await make([.succeed(session)])
    _ = await waitFor(supervisor.state) { $0.phase == .connected }
    await supervisor.wake(.applicationActive)
    while session.probes.withLock({ $0 }) == 0 { await Task.yield() }
    #expect(supervisor.state.value.phase == .connected && supervisor.state.value.generation == 1)
    #expect(session.closeCount.withLock { $0 } == 0)
    #expect(driver.attempts == 1)
    await supervisor.shutdown()
  }

  @Test func aFailedForegroundProbeReconnectsWithoutSleepingTheFirstRung() async throws {
    let dead = StubSession()
    dead.setProbe(.fail)
    let (supervisor, driver, clock) = await make([.succeed(dead), .fail(Self.transient), .succeed(StubSession())])
    _ = await waitFor(supervisor.state) { $0.phase == .connected }
    await supervisor.wake(.applicationActive)
    // The probe failure shows as an immediate attempt (no backoff state in between); that attempt fails normally.
    let state = await waitFor(supervisor.state) { $0.phase == .backoff }
    #expect(driver.attempts == 2)
    #expect(state.retryAt! - clock.nowMilliseconds() == 3000)
    #expect(dead.closeCount.withLock { $0 } >= 1)
    await clock.advance(by: .seconds(3))
    _ = await waitFor(supervisor.state) { $0.phase == .connected && $0.generation == 2 }
    await supervisor.shutdown()
  }

  @Test func aProbeThatNeverAnswersTimesOutAndReplacesTheSession() async {
    let stuck = StubSession()
    stuck.setProbe(.hang)
    let (supervisor, driver, clock) = await make([.succeed(stuck), .succeed(StubSession())])
    _ = await waitFor(supervisor.state) { $0.phase == .connected }
    await supervisor.wake(.applicationActive)
    await clock.advance(by: .seconds(15))
    _ = await waitFor(supervisor.state) { $0.phase == .connected && $0.generation == 2 }
    #expect(driver.attempts == 2)
    await supervisor.shutdown()
  }

  @Test func aDroppedSessionRetriesAndOnlyAStableConnectionResetsTheLadder() async throws {
    let first = StubSession(), second = StubSession()
    let (supervisor, _, clock) = await make([
      .succeed(first), .fail(Self.transient), .succeed(second), .fail(Self.transient), .fail(Self.transient),
    ])
    _ = await waitFor(supervisor.state) { $0.phase == .connected && $0.generation == 1 }
    first.drop()  // connected for 0 s: the ladder is not reset
    let a = await waitFor(supervisor.state) { $0.phase == .backoff && $0.attempt == 1 }
    #expect(a.retryAt! - clock.nowMilliseconds() == 3000)
    await clock.advance(by: .seconds(3))
    let b = await waitFor(supervisor.state) { $0.phase == .backoff && $0.attempt == 2 }
    #expect(b.retryAt! - clock.nowMilliseconds() == 4000)
    await clock.advance(by: .seconds(4))
    _ = await waitFor(supervisor.state) { $0.phase == .connected && $0.generation == 2 }
    // Stable for 30 s: the next failure starts at the first rung again.
    await clock.advance(by: .seconds(31), waitForSleeper: false)
    second.drop()
    let c = await waitFor(supervisor.state) { $0.phase == .backoff && $0.generation == 2 }
    #expect(c.retryAt! - clock.nowMilliseconds() == 3000)
    await supervisor.shutdown()
  }

  @Test func disconnectClosesTheSessionAndStaysAvailable() async {
    let session = StubSession()
    let (supervisor, driver, _) = await make([.succeed(session)])
    _ = await waitFor(supervisor.state) { $0.phase == .connected }
    await supervisor.disconnect()
    let state = await waitFor(supervisor.state) { $0.phase == .available }
    #expect(state.desired == false && supervisor.session.value == nil)
    #expect(session.closeCount.withLock { $0 } >= 1)
    driver.append(.succeed(StubSession()))
    await supervisor.connect()
    _ = await waitFor(supervisor.state) { $0.phase == .connected && $0.generation == 2 }
    await supervisor.shutdown()
  }

  @Test func retryNowSkipsTheRemainingDelayAndResetsTheLadder() async throws {
    let (supervisor, _, clock) = await make(Array(repeating: .fail(Self.transient), count: 4))
    _ = await waitFor(supervisor.state) { $0.phase == .backoff && $0.attempt == 1 }
    await clock.advance(by: .seconds(3))
    _ = await waitFor(supervisor.state) { $0.phase == .backoff && $0.attempt == 2 }
    await supervisor.retryNow()
    let state = await waitFor(supervisor.state) { $0.phase == .backoff && $0.attempt == 1 && $0.retryAt != nil && $0.lastFailure != nil && $0.generation == 0 }
    #expect(state.retryAt! - clock.nowMilliseconds() == 3000)
    await supervisor.shutdown()
  }
}
