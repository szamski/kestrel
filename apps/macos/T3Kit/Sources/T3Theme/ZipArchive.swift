import Compression
import Foundation

/// A minimal read-only ZIP reader for `.vsix` packages, with the web importer's limits: 5000 entries, 100 MB uncompressed in
/// total, a 200:1 compression ratio per entry, no ZIP64, stored and deflate entries only. The central directory is validated
/// up front; an entry is only inflated when asked for, capped at the caller's byte limit.
public struct ZipArchive: Sendable {
  public static let maxEntries = 5_000
  public static let maxUncompressedBytes = 100 * 1024 * 1024
  public static let maxCompressionRatio = 200

  struct Entry: Sendable {
    var name: String
    var method: UInt16
    var compressedSize: Int
    var uncompressedSize: Int
    var localOffset: Int
  }

  private let bytes: [UInt8]
  private let entries: [String: Entry]
  public var names: [String] { Array(entries.keys) }

  private static func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
  private static func u32(_ b: [UInt8], _ o: Int) -> Int { u16(b, o) | u16(b, o + 2) << 16 }

  public init(data: Data) throws {
    let b = [UInt8](data)
    let invalid = ThemeError("That extension package has an invalid ZIP directory.")
    guard b.count >= 22 else { throw ThemeError("That extension package has no ZIP directory.") }
    let minimumOffset = max(0, b.count - 65_557)
    var end = b.count - 22
    while end >= minimumOffset, !(Self.u32(b, end) == 0x0605_4b50 && end + 22 + Self.u16(b, end + 20) == b.count) { end -= 1 }
    guard end >= minimumOffset else { throw ThemeError("That extension package has no ZIP directory.") }
    let directorySize = Self.u32(b, end + 12), directoryOffset = Self.u32(b, end + 16)
    let directoryEnd = directoryOffset + directorySize
    guard directoryEnd == end, directoryEnd <= b.count else { throw invalid }

    var parsed: [String: Entry] = [:]
    var count = 0, total = 0, offset = directoryOffset
    while offset < directoryEnd {
      guard offset + 46 <= directoryEnd, Self.u32(b, offset) == 0x0201_4b50 else { throw invalid }
      count += 1
      guard count <= Self.maxEntries else { throw ThemeError("That extension package has too many files.") }
      let compressed = Self.u32(b, offset + 20), uncompressed = Self.u32(b, offset + 24)
      guard compressed != 0xffff_ffff, uncompressed != 0xffff_ffff else { throw ThemeError("That extension package has unsupported ZIP64 metadata.") }
      total += uncompressed
      guard total <= Self.maxUncompressedBytes else { throw ThemeError("That extension package expands beyond the safe import limit.") }
      if uncompressed > 0, compressed == 0 || uncompressed / compressed > Self.maxCompressionRatio {
        throw ThemeError("That extension package has an unsafe compression ratio.")
      }
      let nameLength = Self.u16(b, offset + 28), extraLength = Self.u16(b, offset + 30), commentLength = Self.u16(b, offset + 32)
      guard offset + 46 + nameLength <= directoryEnd else { throw invalid }
      let name = String(decoding: b[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
      try Self.checkPath(name)
      parsed[name] = Entry(
        name: name, method: UInt16(Self.u16(b, offset + 10)), compressedSize: compressed, uncompressedSize: uncompressed,
        localOffset: Self.u32(b, offset + 42))
      offset += 46 + nameLength + extraLength + commentLength
    }
    guard offset == directoryEnd else { throw invalid }
    bytes = b
    entries = parsed
  }

  public func contains(_ path: String) -> Bool { entries[path] != nil }

  /// The entry's bytes, refusing anything larger than `maxBytes` before it is inflated.
  public func read(_ path: String, description: String, maxBytes: Int) throws -> Data {
    guard let entry = entries[path] else { throw ThemeError("\(description) is missing from the extension package.") }
    guard entry.uncompressedSize <= maxBytes else { throw ThemeError("\(description) is too large.") }
    let unreadable = ThemeError("\(description) could not be read from the extension package.")
    let o = entry.localOffset
    guard o + 30 <= bytes.count, Self.u32(bytes, o) == 0x0403_4b50 else { throw unreadable }
    let start = o + 30 + Self.u16(bytes, o + 26) + Self.u16(bytes, o + 28)
    guard start + entry.compressedSize <= bytes.count else { throw unreadable }
    let packed = bytes[start..<(start + entry.compressedSize)]
    switch entry.method {
    case 0:
      guard entry.compressedSize == entry.uncompressedSize else { throw unreadable }
      return Data(packed)
    case 8:
      if entry.uncompressedSize == 0 { return Data() }
      var out = [UInt8](repeating: 0, count: entry.uncompressedSize)
      let written = packed.withUnsafeBufferPointer { source in
        out.withUnsafeMutableBufferPointer { target in
          compression_decode_buffer(target.baseAddress!, target.count, source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
        }
      }
      guard written == entry.uncompressedSize else { throw unreadable }
      return Data(out)
    default:
      throw ThemeError("\(description) uses an unsupported compression method.")
    }
  }

  // MARK: Paths

  private static func checkPath(_ name: String) throws {
    _ = try normalizePackagePath(name)
  }

  /// `normalizePackagePath`: a relative path inside the package (anchored at `extension/`), never escaping it.
  public static func normalizePackagePath(_ path: String, relativeTo base: String = "extension/") throws -> String {
    if path.count > 1_024 || path.contains("\0") || path.hasPrefix("/") || path.range(of: #"^[a-zA-Z]:"#, options: .regularExpression) != nil {
      throw ThemeError("Theme path is not a safe relative package path.")
    }
    var segments = Array(base.split(separator: "/", omittingEmptySubsequences: false).dropLast()).map(String.init)
    for segment in path.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false) {
      if segment.isEmpty || segment == "." { continue }
      if segment == ".." {
        if segments.count <= 1 { throw ThemeError("Theme path escapes the extension package.") }
        segments.removeLast()
        continue
      }
      segments.append(String(segment))
    }
    if segments.first != "extension" { segments.insert("extension", at: 0) }
    return segments.joined(separator: "/")
  }
}
