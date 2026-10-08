import Foundation

/// An ISO-8601 timestamp exactly as the server sent it (`IsoDateTime` / `DateTime.Utc`).
/// The raw string is the source of truth so re-encoding never changes precision or format.
public struct IsoDateTime: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
  public var rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ rawValue: String) { self.rawValue = rawValue }
  public init(stringLiteral value: String) { rawValue = value }
  public init(date: Date) { rawValue = date.formatted(Self.format(fractional: true)) }

  public init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(rawValue)
  }

  public var description: String { rawValue }

  /// Parsed instant; nil if the string is not ISO-8601 (with or without fractional seconds).
  public var date: Date? {
    (try? Date(rawValue, strategy: Self.format(fractional: true)))
      ?? (try? Date(rawValue, strategy: Self.format(fractional: false)))
  }

  private static func format(fractional: Bool) -> Date.ISO8601FormatStyle {
    Date.ISO8601FormatStyle(includingFractionalSeconds: fractional)
  }
}
