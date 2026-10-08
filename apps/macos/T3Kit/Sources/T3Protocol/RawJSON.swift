import Foundation

/// Untyped JSON value. Used for defect payloads, readiness checks and tests that
/// run before typed contracts exist.
public enum RawJSON: Codable, Sendable, Equatable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([RawJSON])
  case object([String: RawJSON])

  public init(from decoder: any Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let value = try? c.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? c.decode(Double.self) {
      self = .number(value)
    } else if let value = try? c.decode(String.self) {
      self = .string(value)
    } else if let value = try? c.decode([RawJSON].self) {
      self = .array(value)
    } else {
      self = .object(try c.decode([String: RawJSON].self))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let value): try c.encode(value)
    case .number(let value): try c.encode(value)
    case .string(let value): try c.encode(value)
    case .array(let value): try c.encode(value)
    case .object(let value): try c.encode(value)
    }
  }

  public subscript(key: String) -> RawJSON? {
    if case .object(let object) = self { return object[key] }
    return nil
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var numberValue: Double? {
    if case .number(let value) = self { return value }
    return nil
  }
}

/// Failure type for specs whose typed error is not modelled yet.
public struct RpcUntypedFailure: Error, Decodable, Sendable, Equatable {
  public let raw: RawJSON

  public init(raw: RawJSON) { self.raw = raw }

  public init(from decoder: any Decoder) throws {
    raw = try decoder.singleValueContainer().decode(RawJSON.self)
  }
}
