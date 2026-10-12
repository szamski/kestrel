import Foundation
import T3Contracts

/// The checked-in `t3.json` of a project (`packages/contracts/src/t3ProjectFile.ts`), as far as the settings page needs it.
public enum T3ProjectFile {
  /// `missing`: no readable file. `invalid`: the file exists but fails to decode, so the server ignores all of it.
  public enum State: Equatable, Sendable {
    case missing
    case invalid
    case valid(scripts: [ProjectScript])
  }

  /// Decodes the file the way the web does: JSONC (comments, trailing commas) accepted, every field type-checked.
  /// The returned scripts have no id; importing one assigns it.
  public static func parse(_ contents: String) -> State {
    guard let data = lenient(contents).data(using: .utf8), let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .invalid }
    for key in ["iconPath", "$schema"] where root[key] != nil && !(root[key] is String) { return .invalid }
    if let path = root["iconPath"] as? String, path.trimmingCharacters(in: .whitespaces).isEmpty || path.count > 512 { return .invalid }
    if let mode = root["defaultThreadEnvMode"], !["local", "worktree"].contains(mode as? String ?? "") { return .invalid }
    if let mode = root["worktreeSubmodules"], !["recursive", "top-level", "none"].contains(mode as? String ?? "") { return .invalid }
    guard let list = root["scripts"] else { return .valid(scripts: []) }
    guard let entries = list as? [[String: Any]], entries.count <= 50 else { return .invalid }
    var scripts: [ProjectScript] = []
    for entry in entries {
      guard let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
        let command = (entry["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty
      else { return .invalid }
      let icon = entry["icon"] as? String
      if entry["icon"] != nil, !["play", "test", "lint", "configure", "build", "debug"].contains(icon ?? "") { return .invalid }
      for key in ["runOnWorktreeCreate", "runOnSettle", "async", "autoOpenPreview"] where entry[key] != nil && !(entry[key] is Bool) { return .invalid }
      let preview = (entry["previewUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      if entry["previewUrl"] != nil, preview?.isEmpty != false { return .invalid }
      scripts.append(
        ProjectScript(
          id: "", name: name, command: command, icon: ProjectScriptIcon(rawValue: icon ?? "play"), runOnWorktreeCreate: entry["runOnWorktreeCreate"] as? Bool ?? false,
          runOnSettle: entry["runOnSettle"] as? Bool, async: entry["async"] as? Bool, previewUrl: preview, autoOpenPreview: entry["autoOpenPreview"] as? Bool))
    }
    return .valid(scripts: scripts)
  }

  /// Drops `//` and `/* */` comments and trailing commas outside strings.
  static func lenient(_ text: String) -> String {
    let chars = Array(text)
    var out = ""
    var index = 0
    var inString = false
    while index < chars.count {
      let c = chars[index]
      if inString {
        out.append(c)
        if c == "\\", index + 1 < chars.count {
          out.append(chars[index + 1])
          index += 1
        } else if c == "\"" {
          inString = false
        }
      } else if c == "\"" {
        inString = true
        out.append(c)
      } else if c == "/", index + 1 < chars.count, chars[index + 1] == "/" {
        while index < chars.count, chars[index] != "\n" { index += 1 }
        continue
      } else if c == "/", index + 1 < chars.count, chars[index + 1] == "*" {
        index += 2
        while index + 1 < chars.count, !(chars[index] == "*" && chars[index + 1] == "/") { index += 1 }
        index += 2
        continue
      } else if c == "," {
        // A comma followed only by whitespace, comments and a closing bracket is trailing.
        var look = index + 1
        while look < chars.count, chars[look].isWhitespace { look += 1 }
        if look < chars.count, chars[look] == "]" || chars[look] == "}" {
          index += 1
          continue
        }
        out.append(c)
      } else {
        out.append(c)
      }
      index += 1
    }
    return out
  }
}
