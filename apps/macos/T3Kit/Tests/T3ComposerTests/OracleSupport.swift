import Foundation
import Testing

/// Reads the expected files written by apps/macos/scripts/composer-oracle/oracle.ts and compares
/// Swift output against them. Fixtures sit next to the sources, so the lookup uses `#filePath`.
enum Oracle {
  static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures/oracle/expected")

  struct Case {
    let input: [String: Any]
    let output: Any
  }

  static func cases(_ group: String) throws -> [Case] {
    let data = try Data(contentsOf: directory.appendingPathComponent("\(group).json"))
    let array = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    return array.map { Case(input: $0["input"] as? [String: Any] ?? [:], output: $0["output"] ?? NSNull()) }
  }

  /// Runs `body` on every case and records the first few mismatches (with the input) as issues.
  static func check(
    _ group: String, nullEqualsMissing: Bool = false, limit: Int = 6,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: ([String: Any]) throws -> Any?
  ) throws {
    let all = try cases(group)
    var failures = 0
    for item in all {
      let actual = try body(item.input) ?? NSNull()
      let diffs = jsonDiff(item.output, actual, nullEqualsMissing: nullEqualsMissing)
      if !diffs.isEmpty {
        failures += 1
        if failures <= limit {
          let inputText = String(describing: item.input).prefix(300)
          Issue.record("\(group): \(diffs.prefix(3).joined(separator: "; ")) for input \(inputText)", sourceLocation: sourceLocation)
        }
      }
    }
    #expect(failures == 0, "\(group): \(failures) of \(all.count) cases differ", sourceLocation: sourceLocation)
    #expect(!all.isEmpty, "\(group): empty corpus", sourceLocation: sourceLocation)
  }
}

private func isBool(_ value: Any) -> Bool { (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }

/// Structural differences between two JSON documents. `null` and a missing key differ unless
/// `nullEqualsMissing` is set (generated record types encode explicit nulls).
func jsonDiff(_ expected: Any, _ actual: Any, path: String = "$", nullEqualsMissing: Bool = false, limit: Int = 4) -> [String] {
  var out: [String] = []
  func walk(_ a: Any, _ b: Any, _ path: String) {
    if out.count >= limit { return }
    switch (a, b) {
    case (let a as [String: Any], let b as [String: Any]):
      for key in Set(a.keys).union(b.keys).sorted() {
        switch (a[key], b[key]) {
        case (let x?, let y?): walk(x, y, "\(path).\(key)")
        case (let x?, nil):
          if !(nullEqualsMissing && x is NSNull) { out.append("\(path).\(key): missing in Swift (TS \(String(describing: x).prefix(60)))") }
        case (nil, let y?):
          if !(nullEqualsMissing && y is NSNull) { out.append("\(path).\(key): extra in Swift (\(String(describing: y).prefix(60)))") }
        default: break
        }
      }
    case (let a as [Any], let b as [Any]):
      if a.count != b.count {
        out.append("\(path): array length TS \(a.count) != Swift \(b.count)")
        return
      }
      for (index, pair) in zip(a, b).enumerated() { walk(pair.0, pair.1, "\(path)[\(index)]") }
    case (is NSNull, is NSNull): break
    case (let a as String, let b as String):
      if a != b { out.append("\(path): TS \(a.debugDescription.prefix(80)) != Swift \(b.debugDescription.prefix(80))") }
    case (let a as NSNumber, let b as NSNumber):
      if isBool(a) != isBool(b) || a.doubleValue != b.doubleValue { out.append("\(path): TS \(a) != Swift \(b)") }
    default:
      out.append("\(path): TS \(String(describing: a).prefix(60)) is not Swift \(String(describing: b).prefix(60))")
    }
  }
  walk(expected, actual, path)
  return out
}

extension Dictionary where Key == String, Value == Any {
  func int(_ key: String) -> Int { (self[key] as! NSNumber).intValue }
  func string(_ key: String) -> String { self[key] as! String }
  func bool(_ key: String) -> Bool { (self[key] as! NSNumber).boolValue }
  func optionalString(_ key: String) -> String? { self[key] as? String }
  func optionalBool(_ key: String) -> Bool? { (self[key] as? NSNumber)?.boolValue }
}

func json<T: Encodable>(_ value: T) throws -> Any {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.withoutEscapingSlashes]
  return try JSONSerialization.jsonObject(with: encoder.encode(value), options: [.fragmentsAllowed])
}
