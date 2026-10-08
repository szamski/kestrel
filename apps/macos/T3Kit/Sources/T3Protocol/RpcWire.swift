import Foundation
import Synchronization

// Effect RPC JSON wire format (effect-smol `RpcSerialization.json`, one message per
// text frame, arrays accepted). Client messages: Request, Ack, Interrupt, Ping, Eof.
// Server messages: Chunk, Exit, Defect, Pong.

// MARK: - Client frames

enum ClientFrame {
  private struct RequestEnvelope<Payload: Encodable>: Encodable {
    let _tag = "Request"
    let id: Int
    let tag: String
    let payload: Payload
    let headers: [[String]] = []
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return encoder
  }()

  /// Effect's client uses a numeric counter for request ids; Ack and Interrupt echo the same value.
  static func request<Payload: Encodable>(id: Int, tag: String, payload: Payload) throws -> String {
    try string(RequestEnvelope(id: id, tag: tag, payload: payload))
  }

  static func ack(id: Int) -> String { #"{"_tag":"Ack","requestId":\#(id)}"# }
  static func interrupt(id: Int) -> String { #"{"_tag":"Interrupt","requestId":\#(id)}"# }
  static let ping = #"{"_tag":"Ping"}"#
  /// The Effect socket client never sends Eof; kept for completeness of the envelope.
  static let eof = #"{"_tag":"Eof"}"#

  private static func string<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try encoder.encode(value), as: UTF8.self)
  }
}

// MARK: - Server messages

enum CauseItem: Sendable {
  case fail(any Error & Sendable)
  case die(RawJSON)
  case interrupt
}

enum ExitValue: Sendable {
  case success(any Sendable)
  case failure([CauseItem])
}

enum RpcEvent: Sendable {
  case chunk([any Sendable])
  case exit(ExitValue)
  case closed(RpcConnectionError)
  case cancelled
}

struct ExitKeys: CodingKey {
  var stringValue: String
  var intValue: Int? { nil }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { nil }
  static let tag = ExitKeys(stringValue: "_tag")!
  static let value = ExitKeys(stringValue: "value")!
  static let cause = ExitKeys(stringValue: "cause")!
  static let error = ExitKeys(stringValue: "error")!
  static let defect = ExitKeys(stringValue: "defect")!
}

/// Decodes the typed parts of one request's responses. Created per request from its `RpcSpec`.
protocol ResponseCodec: Sendable {
  func decodeChunk(_ values: inout any UnkeyedDecodingContainer) throws -> [any Sendable]
  func decodeExit(_ exit: KeyedDecodingContainer<ExitKeys>) throws -> ExitValue
}

struct SpecCodec<Success: Decodable & Sendable, Failure: Decodable & Sendable & Error>: ResponseCodec {
  let isStream: Bool

  func decodeChunk(_ values: inout any UnkeyedDecodingContainer) throws -> [any Sendable] {
    var decoded: [any Sendable] = []
    while !values.isAtEnd { decoded.append(try values.decode(Success.self)) }
    return decoded
  }

  func decodeExit(_ exit: KeyedDecodingContainer<ExitKeys>) throws -> ExitValue {
    switch try exit.decode(String.self, forKey: .tag) {
    case "Success":
      // A stream's final Exit carries no value; JSON.stringify also drops `value: undefined`.
      if isStream { return .success(()) }
      if exit.contains(.value), !(try exit.decodeNil(forKey: .value)) {
        return .success(try exit.decode(Success.self, forKey: .value))
      }
      return .success(try JSONDecoder().decode(Success.self, from: Data("null".utf8)))
    case "Failure":
      var causes = try exit.nestedUnkeyedContainer(forKey: .cause)
      var items: [CauseItem] = []
      while !causes.isAtEnd {
        let cause = try causes.nestedContainer(keyedBy: ExitKeys.self)
        switch try cause.decode(String.self, forKey: .tag) {
        case "Fail":
          if let error = try? cause.decode(Failure.self, forKey: .error) {
            items.append(.fail(error))
          } else {
            // Declared error shape did not match: surface the raw payload as a defect.
            items.append(.die((try? cause.decode(RawJSON.self, forKey: .error)) ?? .null))
          }
        case "Die":
          items.append(.die((try? cause.decode(RawJSON.self, forKey: .defect)) ?? .null))
        default:
          items.append(.interrupt)
        }
      }
      return .failure(items)
    case let other:
      throw DecodingError.dataCorruptedError(
        forKey: .tag, in: exit, debugDescription: "Unknown Exit tag \(other)")
    }
  }
}

enum ServerMessage: Decodable, Sendable {
  case chunk(id: Int, values: [any Sendable])
  case exit(id: Int, ExitValue)
  /// The payload of a known request did not decode into the spec's types.
  case decodeFailure(id: Int, String)
  case defect(RawJSON)
  case pong
  /// Unknown request id (already cancelled) or a message type clients do not handle.
  case ignored

  private enum Keys: String, CodingKey {
    case tag = "_tag", requestId, values, exit, defect
  }

  /// Decodes with the pending-request registry in `decoder.userInfo`, so each Chunk/Exit
  /// is decoded straight into its spec's types on whatever thread runs the decoder.
  init(from decoder: any Decoder) throws {
    guard let registry = decoder.userInfo[RpcRegistry.userInfoKey] as? RpcRegistry else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: [], debugDescription: "RpcRegistry missing from decoder userInfo"))
    }
    let c = try decoder.container(keyedBy: Keys.self)
    switch try c.decode(String.self, forKey: .tag) {
    case "Pong":
      self = .pong
    case "Defect":
      self = .defect((try? c.decode(RawJSON.self, forKey: .defect)) ?? .null)
    case "Chunk":
      let id = try Self.requestID(c)
      guard let codec = registry.codec(for: id) else { self = .ignored; return }
      do {
        var values = try c.nestedUnkeyedContainer(forKey: .values) as any UnkeyedDecodingContainer
        self = .chunk(id: id, values: try codec.decodeChunk(&values))
      } catch {
        self = .decodeFailure(id: id, "Chunk decode failed: \(error)")
      }
    case "Exit":
      let id = try Self.requestID(c)
      guard let codec = registry.codec(for: id) else { self = .ignored; return }
      do {
        self = .exit(id: id, try codec.decodeExit(try c.nestedContainer(keyedBy: ExitKeys.self, forKey: .exit)))
      } catch {
        self = .decodeFailure(id: id, "Exit decode failed: \(error)")
      }
    default:
      self = .ignored
    }
  }

  private static func requestID(_ c: KeyedDecodingContainer<Keys>) throws -> Int {
    if let id = try? c.decode(Int.self, forKey: .requestId) { return id }
    let text = try c.decode(String.self, forKey: .requestId)
    guard let id = Int(text) else {
      throw DecodingError.dataCorruptedError(
        forKey: .requestId, in: c, debugDescription: "Unsupported request id \(text)")
    }
    return id
  }

  /// A frame is one message or an array of messages.
  static func decodeFrame(_ data: Data, registry: RpcRegistry) throws -> [ServerMessage] {
    let decoder = JSONDecoder()
    decoder.userInfo[RpcRegistry.userInfoKey] = registry
    let first = data.first { $0 != 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }
    if first == UInt8(ascii: "[") { return try decoder.decode([ServerMessage].self, from: data) }
    return [try decoder.decode(ServerMessage.self, from: data)]
  }
}

// MARK: - Pending request table

/// Pending requests, shared between the actor (register/cancel) and the decode pump (codec lookup).
final class RpcRegistry: Sendable {
  struct Entry: Sendable {
    let codec: any ResponseCodec
    let deliver: @Sendable (RpcEvent) -> Void
    var sent = false
  }

  private struct State {
    var nextID = 0
    var entries: [Int: Entry] = [:]
    var closed: RpcConnectionError?
  }

  static let userInfoKey = CodingUserInfoKey(rawValue: "codes.t3.rpc.registry")!
  private let state = Mutex(State())

  func register(
    codec: any ResponseCodec, deliver: @escaping @Sendable (RpcEvent) -> Void
  ) -> Result<Int, RpcConnectionError> {
    state.withLock { state in
      if let closed = state.closed { return .failure(closed) }
      let id = state.nextID
      state.nextID += 1
      state.entries[id] = Entry(codec: codec, deliver: deliver)
      return .success(id)
    }
  }

  func codec(for id: Int) -> (any ResponseCodec)? { state.withLock { $0.entries[id]?.codec } }
  func entry(_ id: Int) -> Entry? { state.withLock { $0.entries[id] } }
  func remove(_ id: Int) -> Entry? { state.withLock { $0.entries.removeValue(forKey: id) } }

  /// False when the request was cancelled before its frame left.
  func markSent(_ id: Int) -> Bool {
    state.withLock { state in
      guard state.entries[id] != nil else { return false }
      state.entries[id]?.sent = true
      return true
    }
  }

  func drain() -> [Entry] {
    state.withLock { state in
      defer { state.entries.removeAll() }
      return Array(state.entries.values)
    }
  }

  /// Rejects further registrations and returns what was pending.
  func close(_ reason: RpcConnectionError) -> [Entry] {
    state.withLock { state in
      if state.closed == nil { state.closed = reason }
      defer { state.entries.removeAll() }
      return Array(state.entries.values)
    }
  }
}
