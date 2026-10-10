import Foundation
import Testing
@testable import T3Contracts

/// JSON helpers shared by the fixture and corpus tests.
enum JSONCheck {
  static func parse(_ data: Data) throws -> Any {
    try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  }

  static func data(_ any: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed, .sortedKeys])
  }

  /// Structural differences (at most `limit`), with numbers compared by value so `1` equals `1.0`.
  static func diff(_ a: Any, _ b: Any, path: String = "$", limit: Int = 8) -> [String] {
    var out: [String] = []
    func walk(_ a: Any, _ b: Any, _ path: String) {
      if out.count >= limit { return }
      switch (a, b) {
      case (let a as [String: Any], let b as [String: Any]):
        for key in Set(a.keys).union(b.keys).sorted() {
          switch (a[key], b[key]) {
          case (let x?, let y?): walk(x, y, "\(path).\(key)")
          case (let x?, nil): out.append("\(path).\(key): missing after re-encode (was \(String(describing: x).prefix(60)))")
          case (nil, let y?): out.append("\(path).\(key): extra after re-encode (\(String(describing: y).prefix(60)))")
          default: break
          }
        }
      case (let a as [Any], let b as [Any]):
        if a.count != b.count { out.append("\(path): array length \(a.count) != \(b.count)"); return }
        for (i, pair) in zip(a, b).enumerated() { walk(pair.0, pair.1, "\(path)[\(i)]") }
      case (is NSNull, is NSNull): break
      default:
        if !(a as AnyObject).isEqual(b as AnyObject) { out.append("\(path): \(String(describing: a).prefix(60)) != \(String(describing: b).prefix(60))") }
      }
    }
    walk(a, b, path)
    return out
  }

  /// Decodes `input` as `T`, re-encodes it and returns the differences against `expected`
  /// (what Effect's own encoder produced for the same input).
  static func reencode<T: Codable>(_ type: T.Type, _ input: Data, expecting expected: Data) throws -> [String] {
    let value = try JSONDecoder().decode(T.self, from: input)
    return diff(try parse(expected), try parse(try JSONEncoder().encode(value)))
  }

  /// Decodes `data` as `T`, re-encodes it and returns the differences against the input.
  static func roundTrip<T: Codable>(_ type: T.Type, _ data: Data) throws -> [String] {
    let value = try JSONDecoder().decode(T.self, from: data)
    let again = try JSONEncoder().encode(value)
    return diff(try parse(data), try parse(again))
  }
}

/// A directory laid out like the raw recordings (and like the sanitized fixtures):
///
///     descriptor.json  session.json  shell.json  threads/*.json  rpc/<name>.json
///
/// `rpc/*.json` hold the raw message arrays: `Exit` for unary calls, `Chunk` for streams.
struct FixtureTree {
  let root: URL

  struct Failure: CustomStringConvertible {
    let file: String
    let message: String
    var description: String { "\(file): \(message)" }
  }

  private func files(_ dir: String, prefix: String = "") -> [URL] {
    let url = dir.isEmpty ? root : root.appendingPathComponent(dir)
    let all = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    return all.filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix(prefix) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  /// Decodes and round-trips every file. Returns the number of decoded values and all failures.
  func verifyAll() -> (decoded: Int, failures: [Failure]) {
    var decoded = 0
    var failures: [Failure] = []

    /// `addedDefaults`: the recording predates the contract. Keys the current schema adds with a default
    /// (settings added after protocol 1) show up after the re-encode, and the legacy per-driver
    /// `settings.providers` blob that orchestrator V2 removed no longer survives it.
    func check<T: Codable>(_ type: T.Type, _ data: Data, _ name: String, addedDefaults: Bool = false) {
      do {
        var diffs = try JSONCheck.roundTrip(T.self, data)
        if addedDefaults {
          diffs.removeAll { $0.contains("extra after re-encode") || $0.hasSuffix(".providers: missing after re-encode") || $0.contains(".providers: missing after re-encode (was") }
        }
        decoded += 1
        if !diffs.isEmpty { failures.append(.init(file: name, message: "round trip differs: " + diffs.joined(separator: "; "))) }
      } catch {
        failures.append(.init(file: name, message: "decode failed: \(error)"))
      }
    }
    func whole<T: Codable>(_ type: T.Type, _ url: URL) {
      guard let data = try? Data(contentsOf: url) else { return }
      check(T.self, data, url.lastPathComponent)
    }
    /// Every value inside `Chunk` messages, or the value of a `Success` exit.
    func messages<T: Codable>(_ type: T.Type, _ url: URL, addedDefaults: Bool = false) {
      guard let data = try? Data(contentsOf: url), let msgs = (try? JSONCheck.parse(data)) as? [[String: Any]] else {
        failures.append(.init(file: url.lastPathComponent, message: "not a message array"))
        return
      }
      for (i, m) in msgs.enumerated() {
        let name = "\(url.lastPathComponent)#\(i)"
        var values: [Any] = []
        switch m["_tag"] as? String {
        case "Chunk": values = m["values"] as? [Any] ?? []
        case "Exit":
          if let exit = m["exit"] as? [String: Any], exit["_tag"] as? String == "Success", let v = exit["value"] { values = [v] }
          else { failures.append(.init(file: name, message: "unexpected exit \(String(describing: m["exit"]).prefix(120))")) }
        default: continue
        }
        for (j, v) in values.enumerated() {
          guard let d = try? JSONCheck.data(v) else { continue }
          check(T.self, d, "\(name)[\(j)]", addedDefaults: addedDefaults)
        }
      }
    }

    for url in files("", prefix: "descriptor") { whole(ExecutionEnvironmentDescriptor.self, url) }
    for url in files("", prefix: "session") { whole(AuthSessionState.self, url) }
    for url in files("", prefix: "shell") { whole(V1.OrchestrationShellSnapshot.self, url) }
    for url in files("threads") { whole(V1.OrchestrationThreadDetailSnapshot.self, url) }
    for url in files("rpc") {
      let n = url.lastPathComponent
      if n.hasPrefix("server.getConfig") { messages(ServerConfig.self, url, addedDefaults: true) }
      else if n.hasPrefix("server.getSettings") { messages(ServerSettings.self, url, addedDefaults: true) }
      else if n.hasPrefix("subscribeServerConfig") { messages(ServerConfigStreamEvent.self, url, addedDefaults: true) }
      else if n.hasPrefix("orchestration.getArchivedShellSnapshot") { messages(V1.OrchestrationShellSnapshot.self, url) }
      else if n.hasPrefix("orchestration.subscribeShell") { messages(V1.OrchestrationShellStreamItem.self, url) }
      else if n.hasPrefix("orchestration.subscribeThread") { messages(V1.OrchestrationThreadStreamItem.self, url) }
    }
    return (decoded, failures)
  }
}
