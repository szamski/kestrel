import Foundation
import T3Contracts
import T3Protocol

/// What an opened protocol-2 work entry shows beyond the timeline: the wire projection withholds a
/// command's output and a dynamic tool's output and large input, and `orchestration.getTurnItem`
/// returns them (`turnItemOutputText` in the web's work-log/itemDetail.ts).
public struct TurnItemDetail: Sendable, Hashable {
  /// The full command of a command execution.
  public var command: String?
  /// A dynamic tool's arguments: `key value` lines for a flat object, else formatted text.
  public var call: String?
  public var output: String?
  public var exitCode: Int?

  public init(command: String? = nil, call: String? = nil, output: String? = nil, exitCode: Int? = nil) {
    self.command = command
    self.call = call
    self.output = output
    self.exitCode = exitCode
  }

  public init(item: OrchestrationV2TurnItem) {
    switch item {
    case .commandExecution(let value):
      let command = value.input.trimmingCharacters(in: .whitespacesAndNewlines)
      self.init(
        command: command.isEmpty ? nil : command,
        output: value.output.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : Self.commandOutput($0) },
        exitCode: value.exitCode)
    case .dynamicTool(let value):
      self.init(call: Self.callText(value.input), output: value.output.flatMap(Self.format))
    default:
      self.init()
    }
  }

  // MARK: Formatting (itemDetail.ts)

  /// Older Claude bash rows stored the raw `{ stdout, stderr, interrupted, ... }` result.
  private static func commandOutput(_ output: String) -> String? {
    guard output.drop(while: \.isWhitespace).hasPrefix("{\"stdout\""),
      let object = try? JSONDecoder().decode(JSONValue.self, from: Data(output.utf8)),
      let stdout = object["stdout"]?.stringValue, let stderr = object["stderr"]?.stringValue,
      case .bool? = object["interrupted"]
    else { return output }
    let text = [stdout, stderr].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
    return text.isEmpty ? nil : text
  }

  /// `toolCallLines` for a dynamic tool: a flat record as `key value` lines, anything else formatted.
  public static func callText(_ input: JSONValue) -> String? {
    if case .object(let record) = input, !(input["truncated"] == .bool(true) && input["summary"]?.stringValue != nil) {
      let lines = record.sorted { $0.key < $1.key }.map { key, value in
        "\(key) \(value.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? json(value, pretty: false))"
      }
      return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
    return format(input)
  }

  private static func json(_ value: JSONValue, pretty: Bool) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
  }

  /// `formatToolValue`: text blocks as text (JSON text indented), the rest as JSON.
  public static func format(_ value: JSONValue) -> String? {
    if value == .null { return nil }
    if let text = text(fromBlocks: value, depth: 0) {
      return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prettyJSONText(text)
    }
    let text = json(value, pretty: true)
    return text.isEmpty || text == "{}" || text == "[]" ? nil : text
  }

  private static func text(fromBlocks value: JSONValue, depth: Int) -> String? {
    if depth > 4 { return nil }
    switch value {
    case .string(let text): return text
    case .array(let blocks):
      let parts = blocks.map { text(fromBlocks: $0, depth: depth + 1) }
      return parts.contains { $0 == nil } ? nil : parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    case .object(let record):
      switch record["type"]?.stringValue {
      case "text": if let text = record["text"]?.stringValue { return text }
      case "image": return "[image]"
      case "resource_link": if let uri = record["uri"]?.stringValue { return uri }
      case "resource":
        if let resource = record["resource"], let text = resource["text"]?.stringValue ?? resource["uri"]?.stringValue { return text }
      default: break
      }
      // MCP results wrap their text in `content`; `structuredContent` repeats it as data, so it only shows when the text is empty.
      let keys = Set(record.keys).subtracting(["isError", "is_error"])
      if keys == ["content"] { return text(fromBlocks: record["content"]!, depth: depth + 1) }
      if keys == ["content", "structuredContent"] {
        let text = text(fromBlocks: record["content"]!, depth: depth + 1)
        return text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? text : nil
      }
      return nil
    default: return nil
    }
  }

  /// MCP tools often return JSON as minified text, one document per line. Indent each.
  private static func prettyJSONText(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("[") || trimmed.hasPrefix("{") else { return text }
    func parse(_ text: String) -> JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
    if let whole = parse(trimmed) { return json(whole, pretty: true) }
    let documents = trimmed.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map(parse)
    return documents.contains { $0 == nil } ? text : documents.compactMap { $0 }.map { json($0, pretty: true) }.joined(separator: "\n\n")
  }
}

/// On-demand `orchestration.getTurnItem` with a small cache, so reopening an entry or scrolling it back
/// into view costs nothing. Entries are keyed by (thread, item, revision): a finished item never changes,
/// and a running one keeps one key (see `V2WorkItem.detailRevision`). Concurrent loads of one key share a request.
public actor TurnItemDetailLoader {
  public typealias Fetch = @Sendable (ThreadId, TurnItemId, String) async throws -> OrchestrationV2TurnItem?

  public struct Offline: Error, LocalizedError {
    public var errorDescription: String? { "The environment is not connected." }
  }

  private struct Key: Hashable {
    var thread: ThreadId
    var item: TurnItemId
    var revision: String
  }

  private let fetch: Fetch
  private let capacity: Int
  /// A nil value is the server's "no longer available"; failures are not cached.
  private var cache: [Key: TurnItemDetail?] = [:]
  private var order: [Key] = []
  private var inflight: [Key: Task<TurnItemDetail?, any Error>] = [:]

  /// A detail is at most 256 KB on the wire, so the cache stays within a few megabytes.
  public init(capacity: Int = 32, fetch: @escaping Fetch) {
    self.capacity = capacity
    self.fetch = fetch
  }

  public init(runtime: ClientRuntime, environment: EnvironmentId, capacity: Int = 32) {
    self.init(capacity: capacity) { thread, item, revision in
      guard let session = await runtime.runtime(for: environment)?.supervisor.session.value else { throw Offline() }
      return try await session.call(Rpc.orchestrationGetTurnItem, OrchestrationV2GetTurnItemInput(threadId: thread, itemId: item, revision: revision)).item
    }
  }

  /// The detail of one item; nil when the server no longer has it.
  public func detail(thread: ThreadId, item: TurnItemId, revision: String) async throws -> TurnItemDetail? {
    let key = Key(thread: thread, item: item, revision: revision)
    if let hit = cache[key] { return hit }
    if let running = inflight[key] { return try await running.value }
    let fetch = fetch
    let task = Task { try await fetch(thread, item, revision).map { TurnItemDetail(item: $0) } }
    inflight[key] = task
    defer { inflight[key] = nil }
    let value = try await task.value
    cache[key] = .some(value)
    order.append(key)
    if order.count > capacity { cache[order.removeFirst()] = nil }
    return value
  }
}
