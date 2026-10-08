import Foundation
import Synchronization
import T3Contracts
@testable import T3Protocol

struct EchoPayload: Codable, Sendable, Equatable { let text: String }
struct EchoResult: Codable, Sendable, Equatable { let text: String }
struct EchoFailure: Error, Codable, Sendable, Equatable {
  let _tag: String
  let message: String
}
struct Tick: Codable, Sendable, Equatable { let n: Int }

let echoSpec = RpcSpec<EchoPayload, EchoResult, EchoFailure>(tag: "test.echo", isStream: false)
let tickSpec = RpcSpec<EchoPayload, Tick, EchoFailure>(tag: "test.ticks", isStream: true)

/// In-process peer: tests read what the session sent and push server frames back.
final class FakeTransport: RpcTransport {
  let frames: AsyncThrowingStream<Data, any Error>
  private let incoming: AsyncThrowingStream<Data, any Error>.Continuation
  let sent: AsyncStream<String>
  private let sentContinuation: AsyncStream<String>.Continuation
  let closed = Mutex(false)

  init() {
    (frames, incoming) = AsyncThrowingStream.makeStream()
    (sent, sentContinuation) = AsyncStream.makeStream()
  }

  func send(_ text: String) async throws {
    sentContinuation.yield(text)
  }

  func close() { closed.withLock { $0 = true } }

  func push(_ json: String) { incoming.yield(Data(json.utf8)) }
  func finish(throwing error: (any Error)? = nil) { incoming.finish(throwing: error) }
}

/// Reads frames the session sent, skipping Ping unless asked otherwise.
struct SentReader {
  private var iterator: AsyncStream<String>.Iterator
  init(_ transport: FakeTransport) { iterator = transport.sent.makeAsyncIterator() }

  mutating func next(skippingPings: Bool = true) async -> RawJSON {
    while let text = await iterator.next() {
      let json = try! JSONDecoder().decode(RawJSON.self, from: Data(text.utf8))
      if skippingPings, json["_tag"]?.stringValue == "Ping" { continue }
      return json
    }
    fatalError("transport sent nothing more")
  }
}

func attempt(_ session: RpcSession, _ text: String) async -> Result<EchoResult, RpcError<EchoFailure>> {
  do { return .success(try await session.call(echoSpec, EchoPayload(text: text))) } catch { return .failure(error) }
}
