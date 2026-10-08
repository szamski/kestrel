import Foundation

/// `Schema.Struct({})` and friends: encodes as `{}`, ignores whatever it decodes.
public struct EmptyObject: Sendable, Hashable, Codable {
  public init() {}
  public init(from decoder: any Decoder) throws {}
  public func encode(to encoder: any Encoder) throws {
    _ = encoder.container(keyedBy: AnyKey.self)
  }
  private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }
}

/// `Schema.Void`: the server sends nothing meaningful; we accept anything and encode `null`.
public struct VoidValue: Sendable, Hashable, Codable {
  public init() {}
  public init(from decoder: any Decoder) throws {}
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encodeNil()
  }
}

/// Failure type of an RPC or endpoint that cannot fail (`Schema.Never`).
public struct NeverFailure: Error, Sendable, Hashable, Decodable {
  public init(from decoder: any Decoder) throws {
    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Schema.Never cannot be decoded"))
  }
}

/// Defaults for keys the server may omit (`withDecodingDefault`). The default is the
/// schema's own JSON, decoded through the same type, so it cannot drift from the wire shape.
public enum WireDefault {
  public static func value<T: Decodable>(_ type: T.Type, json: String) -> T {
    do { return try JSONDecoder().decode(T.self, from: Data(json.utf8)) }
    catch { fatalError("Invalid generated default \(json) for \(T.self): \(error)") }
  }
}

/// `ForwardCompatibleArray`: elements this build cannot decode are skipped, not fatal.
struct LossyArray<Element: Decodable>: Decodable {
  var value: [Element]
  init(from decoder: any Decoder) throws {
    var c = try decoder.unkeyedContainer()
    var out: [Element] = []
    while !c.isAtEnd {
      if let item = try? c.decode(Lossy<Element>.self).value { out.append(item) }
    }
    value = out
  }
  private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
  }
}

/// `Schema.Option` on the JSON codec: `{"_tag":"Some","value":…}` or `{"_tag":"None"}`.
struct WireOption<Value: Codable>: Codable {
  var value: Value?
  init(_ value: Value?) { self.value = value }
  private enum Keys: String, CodingKey { case tag = "_tag", value }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    value = try c.decode(String.self, forKey: .tag) == "Some" ? try c.decode(Value.self, forKey: .value) : nil
  }
  func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: Keys.self)
    if let value {
      try c.encode("Some", forKey: .tag)
      try c.encode(value, forKey: .value)
    } else {
      try c.encode("None", forKey: .tag)
    }
  }
}

extension KeyedDecodingContainer {
  /// A `Schema.Literal` member: the key must be present with exactly this value.
  func expectConstant<T: Decodable & Equatable>(_ expected: T, forKey key: Key) throws {
    guard try decode(T.self, forKey: key) == expected else {
      throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Expected literal \(expected)")
    }
  }
  func decodeLossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> [T] {
    try decode(LossyArray<T>.self, forKey: key).value
  }
  func decodeLossyArrayIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> [T]? {
    try decodeIfPresent(LossyArray<T>.self, forKey: key)?.value
  }
  func decodeWireOption<T: Codable>(_ type: T.Type, forKey key: Key) throws -> T? {
    try decode(WireOption<T>.self, forKey: key).value
  }
  /// Optional key whose value may also be an explicit `null`: absent -> nil, null -> .some(nil).
  func decodeTriState<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T?? {
    guard contains(key) else { return nil }
    if try decodeNil(forKey: key) { return .some(nil) }
    return .some(try decode(T.self, forKey: key))
  }
}

extension KeyedEncodingContainer {
  mutating func encodeWireOption<T: Codable>(_ value: T?, forKey key: Key) throws {
    try encode(WireOption(value), forKey: key)
  }
  mutating func encodeTriState<T: Encodable>(_ value: T??, forKey key: Key) throws {
    switch value {
    case .none: break
    case .some(.none): try encodeNil(forKey: key)
    case .some(.some(let v)): try encode(v, forKey: key)
    }
  }
}
