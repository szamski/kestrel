import Foundation
import T3Contracts
import T3Protocol

/// Handlers of one durable subscription (`subscribeDynamic` in client-runtime/rpc/client.ts).
struct DurableSubscription<Payload: Encodable & Sendable, Item: Decodable & Sendable, Failure: Decodable & Sendable & Error>: Sendable {
  let spec: RpcSpec<Payload, Item, Failure>
  /// Runs before each (re)subscribe on a session; the payload may depend on state (a resume cursor).
  let makeInput: @Sendable (any EnvironmentSession) async -> Payload
  let onItem: @Sendable (any EnvironmentSession, Item) async -> Void
  /// A declared domain failure (not a transport failure): reported, then resubscribed after `retryAfter`.
  let onExpectedFailure: @Sendable (any Error) async -> Void
  /// A protocol defect (undecodable item): reported; the subscription waits for the next session or wake.
  let onDefect: @Sendable () async -> Void
  var retryAfter: Duration = .milliseconds(250)
}

private enum Trigger: Sendable { case session((any EnvironmentSession)?), resubscribe }

/// Follows replacement sessions like `switchMap`: each session change or foreground
/// resubscribe cancels the running subscription and starts a new one on the current session.
/// A transport failure is not retried here; the supervisor opens the next session.
func runDurableSubscription<Payload, Item, Failure>(
  _ subscription: DurableSubscription<Payload, Item, Failure>,
  sessions: AsyncStream<(any EnvironmentSession)?>,
  resubscribe: AsyncStream<Void>,
  clock: any RuntimeClock
) async {
  let (triggers, continuation) = AsyncStream<Trigger>.makeStream()
  let feeders = [
    Task { for await session in sessions { continuation.yield(.session(session)) } },
    Task { for await _ in resubscribe { continuation.yield(.resubscribe) } },
  ]
  defer { feeders.forEach { $0.cancel() } }

  var latest: (any EnvironmentSession)?
  var current: Task<Void, Never>?
  for await trigger in triggers {
    if Task.isCancelled { break }
    if case .session(let session) = trigger { latest = session }
    current?.cancel()
    await current?.value
    guard let session = latest else {
      current = nil
      continue
    }
    current = Task { await subscribeToSession(subscription, session: session, clock: clock) }
  }
  current?.cancel()
  await current?.value
}

private func subscribeToSession<Payload, Item, Failure>(
  _ subscription: DurableSubscription<Payload, Item, Failure>, session: any EnvironmentSession, clock: any RuntimeClock
) async {
  while !Task.isCancelled {
    let input = await subscription.makeInput(session)
    if Task.isCancelled { return }
    do {
      for try await item in session.subscribe(subscription.spec, input) {
        await subscription.onItem(session, item)
      }
      return  // completed: wait for the next session
    } catch let error as RpcError<Failure> {
      if Task.isCancelled { return }
      switch error {
      case .transportClosed, .interrupted:
        return
      case .failure:
        await subscription.onExpectedFailure(error)
        do { try await clock.sleep(for: subscription.retryAfter) } catch { return }
      case .defect:
        await subscription.onDefect()
        return
      }
    } catch {
      return
    }
  }
}
