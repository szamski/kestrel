import Foundation

/// The percent-encoding flavors the composer's wire formats are written in. They match the
/// JavaScript built-ins byte for byte so links produced here parse on web and mobile.
enum URICodec {
  private static func isAlnum(_ byte: UInt8) -> Bool {
    (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
  }

  private static let hex = Array("0123456789ABCDEF".utf8)

  private static func encode(_ text: String, keep: (UInt8) -> Bool) -> String {
    var out: [UInt8] = []
    out.reserveCapacity(text.utf8.count)
    for byte in text.utf8 {
      if keep(byte) {
        out.append(byte)
      } else {
        out.append(0x25)
        out.append(hex[Int(byte >> 4)])
        out.append(hex[Int(byte & 0xF)])
      }
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// `encodeURI(path)` followed by the composer's `(`, `)`, `#`, `?`, `\` escapes.
  static func encodeFileLinkDestination(_ path: String) -> String {
    let keep = Set(";,/:@&=+$-_.!~*'".utf8)
    return encode(path) { isAlnum($0) || keep.contains($0) }
  }

  /// `encodeURIComponent` then every `!'()*` escaped (the citation path-segment rule).
  static func encodeStrictComponent(_ text: String) -> String {
    let keep = Set("-_.~".utf8)
    return encode(text) { isAlnum($0) || keep.contains($0) }
  }

  /// `encodeURIComponent`.
  static func encodeComponent(_ text: String) -> String {
    let keep = Set("-_.!~*'()".utf8)
    return encode(text) { isAlnum($0) || keep.contains($0) }
  }

  /// `URLSearchParams.toString()` value/name encoding.
  static func encodeFormComponent(_ text: String) -> String {
    var out: [UInt8] = []
    let keep = Set("*-._".utf8)
    for byte in text.utf8 {
      if isAlnum(byte) || keep.contains(byte) {
        out.append(byte)
      } else if byte == 0x20 {
        out.append(0x2B)
      } else {
        out.append(0x25)
        out.append(hex[Int(byte >> 4)])
        out.append(hex[Int(byte & 0xF)])
      }
    }
    return String(decoding: out, as: UTF8.self)
  }

  private static func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 0x30...0x39: byte - 0x30
    case 0x41...0x46: byte - 0x41 + 10
    case 0x61...0x66: byte - 0x61 + 10
    default: nil
    }
  }

  /// `decodeURIComponent`; nil where JavaScript throws `URIError`.
  static func decodeComponent(_ text: String) -> String? {
    let input = Array(text.utf8)
    guard input.contains(0x25) else { return text }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(input.count)
    var index = 0
    while index < input.count {
      let byte = input[index]
      if byte != 0x25 {
        bytes.append(byte)
        index += 1
        continue
      }
      guard index + 2 < input.count, let high = hexValue(input[index + 1]), let low = hexValue(input[index + 2]) else {
        return nil
      }
      bytes.append(high << 4 | low)
      index += 3
    }
    // Invalid UTF-8 (overlong forms, surrogates, > U+10FFFF) is a URIError in JavaScript too.
    return String(validating: bytes, as: UTF8.self)
  }

  /// `URLSearchParams` decoding of one name or value: `+` is a space and malformed escapes stay
  /// literal; invalid UTF-8 becomes U+FFFD.
  static func decodeFormComponent(_ text: String) -> String {
    let input = Array(text.utf8)
    var bytes: [UInt8] = []
    var index = 0
    while index < input.count {
      let byte = input[index]
      if byte == 0x2B {
        bytes.append(0x20)
      } else if byte == 0x25, index + 2 < input.count,
        let high = hexValue(input[index + 1]), let low = hexValue(input[index + 2])
      {
        bytes.append(high << 4 | low)
        index += 3
        continue
      } else {
        bytes.append(byte)
      }
      index += 1
    }
    return String(decoding: bytes, as: UTF8.self)
  }
}
