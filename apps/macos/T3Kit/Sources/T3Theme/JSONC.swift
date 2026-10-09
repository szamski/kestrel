import Foundation

/// JSON with comments and trailing commas, the dialect VS Code theme and manifest files are written in
/// (`jsonc-parser` with `allowTrailingComma`).
public enum JSONC {
  /// Strips `//` and `/* */` comments and commas before a closing bracket, leaving string contents untouched.
  static func normalize(_ source: String) -> String {
    var out = [UInt8]()
    let bytes = Array(source.utf8)
    out.reserveCapacity(bytes.count)
    var i = 0
    var start = 0
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { start = 3 }
    i = start
    while i < bytes.count {
      let c = bytes[i]
      if c == UInt8(ascii: "\"") {
        out.append(c)
        i += 1
        while i < bytes.count {
          out.append(bytes[i])
          if bytes[i] == UInt8(ascii: "\\"), i + 1 < bytes.count {
            out.append(bytes[i + 1])
            i += 2
            continue
          }
          if bytes[i] == UInt8(ascii: "\"") { i += 1; break }
          i += 1
        }
      } else if c == UInt8(ascii: "/"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "/") {
        while i < bytes.count, bytes[i] != 0x0A, bytes[i] != 0x0D { i += 1 }
      } else if c == UInt8(ascii: "/"), i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "*") {
        i += 2
        while i + 1 < bytes.count, !(bytes[i] == UInt8(ascii: "*") && bytes[i + 1] == UInt8(ascii: "/")) { i += 1 }
        i = min(i + 2, bytes.count)
        out.append(0x20)
      } else if c == UInt8(ascii: "}") || c == UInt8(ascii: "]") {
        // Drop a trailing comma (and the whitespace after it) that sits right before the closer.
        var j = out.count - 1
        while j >= 0, [0x20, 0x09, 0x0A, 0x0D].contains(out[j]) { j -= 1 }
        if j >= 0, out[j] == UInt8(ascii: ",") { out.remove(at: j) }
        out.append(c)
        i += 1
      } else {
        out.append(c)
        i += 1
      }
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// The top-level object, or an error naming `description`.
  public static func parseObject(_ source: String, description: String) throws -> [String: Any] {
    guard let value = try? JSONSerialization.jsonObject(with: Data(normalize(source).utf8)), let object = value as? [String: Any] else {
      throw ThemeError("\(description) is not valid JSON.")
    }
    return object
  }
}
