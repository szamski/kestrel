import Foundation
import Testing
import T3Contracts
@testable import T3ClientRuntime

/// `getTurnItem` on demand: one request per (thread, item, revision), the withheld output formatted like the web.
@Suite struct TurnItemDetailLoaderTests {
  static func item(_ extra: String) throws -> OrchestrationV2TurnItem {
    let json = #"{"id":"item-1","threadId":"thread-1","runId":null,"nodeId":null,"ordinal":1,"status":"completed","updatedAt":"2026-10-10T10:00:00.000Z",\#(extra)}"#
    return try JSONDecoder().decode(OrchestrationV2TurnItem.self, from: Data(json.utf8))
  }

  actor Calls {
    var count = 0
    func hit() { count += 1 }
  }

  @Test func commandDetailCarriesFullCommandAndOutput() throws {
    let detail = TurnItemDetail(item: try Self.item(#""type":"command_execution","input":"ls -la","output":"a\nb\n","exitCode":1"#))
    #expect(detail == TurnItemDetail(command: "ls -la", output: "a\nb\n", exitCode: 1))
  }

  @Test func dynamicToolOutputUnwrapsTextBlocksAndIndentsJSON() throws {
    let blocks = TurnItemDetail(item: try Self.item(#""type":"dynamic_tool","input":{"path":"a.txt","force":true},"output":{"content":[{"type":"text","text":"{\"ok\":1}"}]}"#))
    #expect(blocks.call == "force true\npath a.txt")
    #expect(blocks.output?.contains("\"ok\"") == true && blocks.output?.contains("\n") == true)
    let plain = TurnItemDetail(item: try Self.item(#""type":"dynamic_tool","input":{},"output":{"rows":[1]}"#))
    #expect(plain.call == nil && plain.output?.contains("rows") == true)
  }

  @Test func loadsOncePerRevisionAndSharesConcurrentRequests() async throws {
    let calls = Calls()
    let item = try Self.item(#""type":"command_execution","input":"ls","output":"x""#)
    let loader = TurnItemDetailLoader { _, _, _ in
      await calls.hit()
      try await Task.sleep(for: .milliseconds(20))
      return item
    }
    let thread = ThreadId(rawValue: "thread-1"), id = TurnItemId(rawValue: "item-1")
    async let first = loader.detail(thread: thread, item: id, revision: "r1")
    async let second = loader.detail(thread: thread, item: id, revision: "r1")
    let (a, b) = try await (first, second)
    #expect(a?.output == "x" && b?.output == "x")
    _ = try await loader.detail(thread: thread, item: id, revision: "r1")
    #expect(await calls.count == 1)
    _ = try await loader.detail(thread: thread, item: id, revision: "r2")
    #expect(await calls.count == 2)
  }

  @Test func failuresAreNotCachedAndMissingItemsAre() async throws {
    let calls = Calls()
    let loader = TurnItemDetailLoader { _, _, _ in
      await calls.hit()
      if await calls.count == 1 { throw TurnItemDetailLoader.Offline() }
      return nil
    }
    let thread = ThreadId(rawValue: "thread-1"), id = TurnItemId(rawValue: "item-1")
    await #expect(throws: TurnItemDetailLoader.Offline.self) { try await loader.detail(thread: thread, item: id, revision: "r") }
    #expect(try await loader.detail(thread: thread, item: id, revision: "r") == nil)
    #expect(try await loader.detail(thread: thread, item: id, revision: "r") == nil)
    #expect(await calls.count == 2)
  }

  @Test func evictsTheOldestEntryPastCapacity() async throws {
    let calls = Calls()
    let item = try Self.item(#""type":"command_execution","input":"ls""#)
    let loader = TurnItemDetailLoader(capacity: 1) { _, _, _ in await calls.hit(); return item }
    let thread = ThreadId(rawValue: "thread-1")
    for revision in ["a", "b", "a"] { _ = try await loader.detail(thread: thread, item: TurnItemId(rawValue: "item-1"), revision: revision) }
    #expect(await calls.count == 3)
  }
}
