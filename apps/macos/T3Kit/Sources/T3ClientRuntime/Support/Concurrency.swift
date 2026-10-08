import Foundation
import Synchronization

/// Latest-value hub: the Swift counterpart of `SubscriptionRef.changes`. Subscribers receive the
/// current value first, then every change; a slow consumer only ever sees the newest value.
public final class ValueHub<Value: Sendable>: Sendable {
  private struct State {
    var value: Value
    var subscribers: [Int: AsyncStream<Value>.Continuation] = [:]
    var nextID = 0
  }
  private let state: Mutex<State>
  /// Terminated subscribers. `onTermination` may run synchronously inside `yield`, i.e. while
  /// `state` is held, so it must never take `state`; removals are applied on the next update.
  private let removals = Mutex<[Int]>([])

  public init(_ value: Value) { state = Mutex(State(value: value)) }

  public var value: Value { state.withLock { $0.value } }

  private func drainRemovals(_ state: inout State) {
    for id in removals.withLock({ defer { $0 = [] }; return $0 }) { state.subscribers.removeValue(forKey: id) }
  }

  public func set(_ value: Value) {
    state.withLock { state in
      state.value = value
      drainRemovals(&state)
      for continuation in state.subscribers.values { continuation.yield(value) }
    }
  }

  public func update(_ transform: (inout Value) -> Void) {
    state.withLock { state in
      transform(&state.value)
      drainRemovals(&state)
      for continuation in state.subscribers.values { continuation.yield(state.value) }
    }
  }

  public func changes() -> AsyncStream<Value> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let id = state.withLock { state -> Int in
        drainRemovals(&state)
        state.nextID += 1
        state.subscribers[state.nextID] = continuation
        continuation.yield(state.value)
        return state.nextID
      }
      continuation.onTermination = { [weak self] _ in self?.removals.withLock { $0.append(id) } }
    }
  }
}

/// Unbounded FIFO with cancellation-aware `take`. One consumer loop at a time, but the consumer
/// changes between waits (backoff wait, attempt, monitor), like the Effect queue it replaces.
public final class SignalQueue<Element: Sendable>: Sendable {
  private struct Waiter {
    let id: Int
    let continuation: CheckedContinuation<Element?, Never>
  }
  private struct State {
    var buffer: [Element] = []
    var waiters: [Waiter] = []
    var nextID = 0
    var closed = false
  }
  private let state = Mutex(State())

  public init() {}

  public func offer(_ element: Element) {
    let waiter = state.withLock { state -> Waiter? in
      if state.closed { return nil }
      if state.waiters.isEmpty {
        state.buffer.append(element)
        return nil
      }
      return state.waiters.removeFirst()
    }
    waiter?.continuation.resume(returning: element)
  }

  /// Puts an element back at the head (a race loser that already took it).
  public func pushFront(_ element: Element) {
    let waiter = state.withLock { state -> Waiter? in
      if state.closed { return nil }
      if state.waiters.isEmpty {
        state.buffer.insert(element, at: 0)
        return nil
      }
      return state.waiters.removeFirst()
    }
    waiter?.continuation.resume(returning: element)
  }

  /// The next element, or nil when the calling task was cancelled (or the queue closed).
  public func take() async -> Element? {
    let id = state.withLock { state -> Int in
      state.nextID += 1
      return state.nextID
    }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Element?, Never>) in
        let immediate = state.withLock { state -> Element?? in
          if state.closed || Task.isCancelled { return .some(nil) }
          if !state.buffer.isEmpty { return .some(state.buffer.removeFirst()) }
          state.waiters.append(Waiter(id: id, continuation: continuation))
          return nil
        }
        if let immediate { continuation.resume(returning: immediate) }
      }
    } onCancel: {
      let waiter = state.withLock { state -> Waiter? in
        guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
        return state.waiters.remove(at: index)
      }
      waiter?.continuation.resume(returning: nil)
    }
  }

  public func close() {
    let waiters = state.withLock { state -> [Waiter] in
      state.closed = true
      defer { state.waiters = [] }
      return state.waiters
    }
    for waiter in waiters { waiter.continuation.resume(returning: nil) }
  }
}

/// Runs every operation concurrently, returns the first result and cancels (and awaits) the rest.
/// Results of the losers are returned too, so callers can put back anything they consumed
/// (a signal taken from a queue) or release anything they opened (a connection).
func raceFirst<T: Sendable>(_ operations: [@Sendable () async -> T]) async -> (winner: T, losers: [T]) {
  await withTaskGroup(of: T.self) { group in
    for operation in operations { group.addTask { await operation() } }
    let winner = await group.next()!
    group.cancelAll()
    var losers: [T] = []
    for await result in group { losers.append(result) }
    return (winner, losers)
  }
}

/// A one-shot async value (`Deferred`): awaiters suspend until `succeed`/`fail`; later awaiters get the same result.
public final class Deferred<Value: Sendable>: Sendable {
  private struct State {
    var result: Result<Value, any Error>?
    var waiters: [Int: CheckedContinuation<Value, any Error>] = [:]
    var nextID = 0
  }
  private let state = Mutex(State())
  public init() {}

  public func complete(_ result: Result<Value, any Error>) {
    let waiters = state.withLock { state -> [CheckedContinuation<Value, any Error>] in
      guard state.result == nil else { return [] }
      state.result = result
      defer { state.waiters = [:] }
      return Array(state.waiters.values)
    }
    for waiter in waiters { waiter.resume(with: result) }
  }

  public func value() async throws -> Value {
    let id = state.withLock { state -> Int in
      state.nextID += 1
      return state.nextID
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let immediate = state.withLock { state -> Result<Value, any Error>? in
          if let result = state.result { return result }
          if Task.isCancelled { return .failure(CancellationError()) }
          state.waiters[id] = continuation
          return nil
        }
        if let immediate { continuation.resume(with: immediate) }
      }
    } onCancel: {
      let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
      waiter?.resume(throwing: CancellationError())
    }
  }
}

/// Fan-out of discrete events (no replay of past values).
public final class EventHub<Event: Sendable>: Sendable {
  private struct State {
    var subscribers: [Int: AsyncStream<Event>.Continuation] = [:]
    var nextID = 0
  }
  private let state = Mutex(State())
  private let removals = Mutex<[Int]>([])  // see ValueHub.removals
  public init() {}

  public func emit(_ event: Event) {
    state.withLock { state in
      for id in removals.withLock({ defer { $0 = [] }; return $0 }) { state.subscribers.removeValue(forKey: id) }
      for continuation in state.subscribers.values { continuation.yield(event) }
    }
  }

  public func events() -> AsyncStream<Event> {
    AsyncStream { continuation in
      let id = state.withLock { state -> Int in
        state.nextID += 1
        state.subscribers[state.nextID] = continuation
        return state.nextID
      }
      continuation.onTermination = { [weak self] _ in self?.removals.withLock { $0.append(id) } }
    }
  }
}

/// Trailing debounce for cache writes: a burst of updates writes once, `delay` after the last one.
/// `flush` writes the pending value at once (scope teardown).
actor DebouncedWriter<Value: Sendable> {
  private let delay: Duration
  private let clock: any RuntimeClock
  private let write: @Sendable (Value) async -> Void
  private var pending: Value?
  private var task: Task<Void, Never>?

  init(delay: Duration = .milliseconds(500), clock: any RuntimeClock, write: @escaping @Sendable (Value) async -> Void) {
    self.delay = delay
    self.clock = clock
    self.write = write
  }

  func submit(_ value: Value) {
    pending = value
    task?.cancel()
    task = Task {
      do { try await clock.sleep(for: delay) } catch { return }
      await self.flushPending()
    }
  }

  private func flushPending() async {
    guard let value = pending else { return }
    pending = nil
    await write(value)
  }

  func flush() async {
    task?.cancel()
    task = nil
    await flushPending()
  }

  func cancel() {
    task?.cancel()
    task = nil
    pending = nil
  }
}
