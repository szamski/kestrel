import Foundation
import Testing
import T3Contracts
@testable import T3Protocol

private let longInterval = Duration.seconds(3600)

@Suite struct RpcSessionTests {
  @Test func requestEnvelopeAndSuccessExit() async throws {
    let fake = FakeTransport()
    var sent = SentReader(fake)
    let session = try await RpcSession.open(transport: fake, pingInterval: longInterval)
    async let result = session.call(echoSpec, EchoPayload(text: "hi"))

    let request = await sent.next()
    #expect(request == .object([
      "_tag": .string("Request"), "id": .number(0), "tag": .string("test.echo"),
      "payload": .object(["text": .string("hi")]), "headers": .array([]),
    ]))
    fake.push(#"{"_tag":"Exit","requestId":0,"exit":{"_tag":"Success","value":{"text":"hello"}}}"#)
    #expect(try await result == EchoResult(text: "hello"))
    await session.close()
  }

  @Test(arguments: [
    (#"[{"_tag":"Fail","error":{"_tag":"Boom","message":"nope"}}]"#, "failure"),
    (#"[{"_tag":"Die","defect":"kaput"}]"#, "defect"),
    (#"[{"_tag":"Interrupt","fiberId":3}]"#, "interrupted"),
    (#"[{"_tag":"Interrupt"},{"_tag":"Die","defect":{"m":1}},{"_tag":"Fail","error":{"_tag":"Boom","message":"x"}}]"#, "failure"),
    (#"[{"_tag":"Fail","error":{"unexpected":true}}]"#, "defect"),
  ])
  func exitFailureShapes(cause: String, expected: String) async throws {
    let fake = FakeTransport()
    var sent = SentReader(fake)
    let session = try await RpcSession.open(transport: fake, pingInterval: longInterval)
    async let result = attempt(session, "x")
    _ = await sent.next()
    fake.push(#"{"_tag":"Exit","requestId":0,"exit":{"_tag":"Failure","cause":\#(cause)}}"#)
    switch try #require((await result).failureValue) {
    case .failure(let failure): #expect(expected == "failure"); #expect(failure._tag == "Boom")
    case .defect: #expect(expected == "defect")
    case .interrupted: #expect(expected == "interrupted")
    case .transportClosed: Issue.record("unexpected transportClosed")
    }
    await session.close()
  }

  @Test func arrayFrameCompletesSeveralRequests() async throws {
    let fake = FakeTransport()
    var sent = SentReader(fake)
    let session = try await RpcSession.open(transport: fake, pingInterval: longInterval)
    async let first = session.call(echoSpec, EchoPayload(text: "a"))
    _ = await sent.next()
    async let second = session.call(echoSpec, EchoPayload(text: "b"))
    let secondRequest = await sent.next()
    #expect(secondRequest["id"] == .number(1))
    fake.push(
      #"[{"_tag":"Pong"},{"_tag":"Exit","requestId":1,"exit":{"_tag":"Success","value":{"text":"B"}}},"#
        + #"{"_tag":"Exit","requestId":0,"exit":{"_tag":"Success","value":{"text":"A"}}}]"#)
    #expect(try await first == EchoResult(text: "A"))
    #expect(try await second == EchoResult(text: "B"))
    await session.close()
  }

  @Test func streamAcksEveryChunkAndEndsOnExit() async throws {
    let fake = FakeTransport()
    var sent = SentReader(fake)
    let session = try await RpcSession.open(transport: fake, pingInterval: longInterval)
    let stream = session.subscribe(tickSpec, EchoPayload(text: "go"))
    var items = stream.makeAsyncIterator()

    #expect(await sent.next()["tag"] == .string("test.ticks"))
    fake.push(#"{"_tag":"Chunk","requestId":0,"values":[{"n":1},{"n":2}]}"#)
    #expect(try await items.next() == Tick(n: 1))
    #expect(try await items.next() == Tick(n: 2))
    #expect(await sent.next() == .object(["_tag": .string("Ack"), "requestId": .number(0)]))

    fake.push(#"{"_tag":"Chunk","requestId":0,"values":[{"n":3}]}"#)
    #expect(try await items.next() == Tick(n: 3))
    #expect(await sent.next() == .object(["_tag": .string("Ack"), "requestId": .number(0)]))

    // Stream exit has no `value` key (JSON.stringify drops undefined).
    fake.push(#"{"_tag":"Exit","requestId":0,"exit":{"_tag":"Success"}}"#)
    #expect(try await items.next() == nil)
    await session.close()
  }

  @Test func streamFailureIsTyped() async throws {
    let fake = FakeTransport()
    var sent = SentReader(fake)
    let session = try await RpcSession.open(transport: fake, pingInterval: longInterval)
    var items = session.subscribe(tickSpec, EchoPayload(text: "go")).makeAsyncIterator()
    _ = await sent.next()
    fake.push(#"{"_tag":"Exit","requestId":0,"exit":{"_tag":"Failure","cause":[{"_tag":"Fail","error":{"_tag":"Boom","message":"m"}}]}}"#)
    do {
      _ = try await items.next()
      Issue.record("expected failure")
    } catch let error as RpcError<EchoFailure> {
      guard case .failure(let failure) = error else { _ = Issue.record("wrong case \(error)"); return }
      #expect(failure.message == "m")
    }
    await session.close()
  }

  @Test func cancellingTheConsumerSendsInterrupt() async throws {
    let fake = FakeTransport()
    var sent = SentReader(fake)
    let session = try await RpcSession.open(transport: fake, pingInterval: longInterval)
    let stream = session.subscribe(tickSpec, EchoPayload(text: "go"))
    let consumer = Task { for try await _ in stream {} }

    _ = await sent.next()  // Request
    fake.push(#"{"_tag":"Chunk","requestId":0,"values":[{"n":1}]}"#)
    #expect(await sent.next()["_tag"] == .string("Ack"))
    consumer.cancel()
    #expect(await sent.next() == .object(["_tag": .string("Interrupt"), "requestId": .number(0)]))
    await session.close()
  }

  @Test func cancellingAUnaryCallSendsInterrupt() async throws {
    let fake = FakeTransport()
    var sent = SentReader(fake)
    let session = try await RpcSession.open(transport: fake, pingInterval: longInterval)
    let call = Task { try await session.call(echoSpec, EchoPayload(text: "slow")) }
    _ = await sent.next()
    call.cancel()
    #expect(await sent.next() == .object(["_tag": .string("Interrupt"), "requestId": .number(0)]))
    do {
      _ = try await call.value
      Issue.record("expected interruption")
    } catch let error as RpcError<EchoFailure> {
      guard case .interrupted = error else { _ = Issue.record("wrong case \(error)"); return }
    }
    await session.close()
  }

  @Test func missingPongClosesTheSession() async throws {
    let fake = FakeTransport()
    var sent = SentReader(fake)
    let session = try await RpcSession.open(transport: fake, pingInterval: .milliseconds(40))
    async let result = attempt(session, "x")
    #expect(await sent.next(skippingPings: false)["tag"] == .string("test.echo"))
    #expect(await sent.next(skippingPings: false) == .object(["_tag": .string("Ping")]))

    #expect(await session.waitUntilClosed() == .pingTimeout)
    guard case .transportClosed(.pingTimeout) = try #require((await result).failureValue) else {
      _ = Issue.record("pending call should fail with pingTimeout"); return
    }
    #expect(fake.closed.withLock { $0 })
  }

  @Test func pongKeepsTheSessionAlive() async throws {
    let fake = FakeTransport()
    var sent = SentReader(fake)
    let session = try await RpcSession.open(transport: fake, pingInterval: .milliseconds(30))
    for _ in 0..<4 {
      #expect(await sent.next(skippingPings: false) == .object(["_tag": .string("Ping")]))
      fake.push(#"{"_tag":"Pong"}"#)
    }
    #expect(await session.isOpen)
    await session.close()
    #expect(await session.waitUntilClosed() == .closedByClient)
  }

  @Test func defectAndSocketCloseFailPendingRequests() async throws {
    let fake = FakeTransport()
    var sent = SentReader(fake)
    let session = try await RpcSession.open(transport: fake, pingInterval: longInterval)
    async let first = attempt(session, "x")
    _ = await sent.next()
    fake.push(#"{"_tag":"Defect","defect":"server exploded"}"#)
    guard case .defect(.string("server exploded")) = try #require((await first).failureValue) else {
      _ = Issue.record("expected defect"); return
    }

    async let second = attempt(session, "y")
    _ = await sent.next()
    fake.finish()
    guard case .transportClosed(.closed) = try #require((await second).failureValue) else {
      _ = Issue.record("expected transportClosed"); return
    }
    // A closed session rejects new work immediately.
    do throws(RpcError<EchoFailure>) { _ = try await session.call(echoSpec, EchoPayload(text: "z")) }
    catch { guard case .transportClosed = error else { _ = Issue.record("expected transportClosed"); return } }
  }

  @Test func rejectedReadinessClosesTheSession() async throws {
    struct NotReady: Error {}
    let fake = FakeTransport()
    await #expect(throws: NotReady.self) {
      _ = try await RpcSession.open(transport: fake, pingInterval: longInterval) { _ in throw NotReady() }
    }
    #expect(fake.closed.withLock { $0 })
  }
}

extension Result {
  var failureValue: Failure? {
    if case .failure(let error) = self { return error }
    return nil
  }
}
