import Foundation

// Pure file-surface logic (Foundation only, so it can be checked with a bare swiftc harness; see
// apps/macos/scripts/check-file-logic.sh). Ports of `filePreview.ts`, `delimitedPreview.ts`,
// `ProjectFilePicker.logic.ts` and `reviewCommentContext.ts` (file part) from the web.

/// How a file is shown. Same extension classification as the web's `filePreviewKind` for workspace files.
enum FilePreviewKind: Equatable {
  case image, video, audio, pdf, html, markdown, text
  case delimited(Character)

  /// Media and PDFs render from asset bytes and never read the file as text.
  var isBinaryAsset: Bool {
    switch self {
    case .image, .video, .audio, .pdf: true
    default: false
    }
  }
}

enum FileLogic {
  /// Past this the server truncates and the preview is read-only (`FILE_TEXT_PREVIEW_MAX_BYTES`).
  static let textPreviewMaxBytes = 1024 * 1024

  private static let imageExtensions: Set<String> = ["avif", "gif", "ico", "jpeg", "jpg", "png", "svg", "webp"]
  private static let videoExtensions: Set<String> = ["avi", "m4v", "mkv", "mov", "mp4", "ogv", "webm"]
  private static let audioExtensions: Set<String> = ["mp3", "wav", "ogg", "oga", "flac", "aac", "m4a", "opus", "aiff"]

  static func kind(of path: String) -> FilePreviewKind {
    let ext = (path as NSString).pathExtension.lowercased()
    if videoExtensions.contains(ext) { return .video }
    if audioExtensions.contains(ext) { return .audio }
    if imageExtensions.contains(ext) { return .image }
    switch ext {
    case "pdf": return .pdf
    case "html", "htm": return .html
    case "md", "markdown", "mdown", "mkd", "mdx": return .markdown
    case "csv": return .delimited(",")
    case "tsv": return .delimited("\t")
    default: return .text
    }
  }

  /// The workspace-relative form of an absolute path, or nil when it is outside every root.
  static func relativePath(_ path: String, roots: [String]) -> String? {
    guard path.hasPrefix("/") else { return path.isEmpty ? nil : path }
    for root in roots where !root.isEmpty {
      let base = root.hasSuffix("/") ? String(root.dropLast()) : root
      if path.hasPrefix(base + "/") { return String(path.dropFirst(base.count + 1)) }
    }
    return nil
  }

  static func absolutePath(_ relative: String, root: String) -> String {
    relative.hasPrefix("/") ? relative : (root as NSString).appendingPathComponent(relative)
  }

  static func basename(_ path: String) -> String { (path as NSString).lastPathComponent }

  /// `Sources/App` for `Sources/App/main.swift`, empty at the root.
  static func directory(_ path: String) -> String { (path as NSString).deletingLastPathComponent }

  /// SF Symbol for the tree and the picker, by extension.
  static func symbol(for path: String, isDirectory: Bool = false) -> String {
    if isDirectory { return "folder" }
    switch kind(of: path) {
    case .image: return "photo"
    case .video: return "film"
    case .audio: return "waveform"
    case .pdf: return "doc.richtext"
    case .markdown: return "doc.text"
    case .delimited: return "tablecells"
    case .html: return "chevron.left.forwardslash.chevron.right"
    case .text: break
    }
    switch (path as NSString).pathExtension.lowercased() {
    case "swift", "rs", "go", "py", "rb", "js", "jsx", "ts", "tsx", "java", "kt", "c", "h", "cc", "cpp", "hpp", "cs", "php", "sh", "zsh", "bash", "lua", "sql":
      return "chevron.left.forwardslash.chevron.right"
    case "json", "yaml", "yml", "toml", "plist", "xml", "ini", "conf", "env": return "curlybraces"
    case "zip", "gz", "tar", "tgz": return "doc.zipper"
    default: return "doc"
    }
  }

  /// highlight.js language for the file, by extension or well-known name (nil: plain).
  static func language(forPath path: String) -> String? {
    let name = basename(path).lowercased()
    if name == "makefile" { return "makefile" }
    let ext = (name as NSString).pathExtension
    return ext.isEmpty ? nil : ext
  }

  /// `inferReviewCommentFenceLanguage`.
  static func fenceLanguage(forPath path: String) -> String {
    let name = basename(path.replacingOccurrences(of: "\\", with: "/")).lowercased()
    if let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex {
      return String(name[name.index(after: dot)...])
    }
    if name.hasPrefix("."), name.count > 1 { return String(name.dropFirst()) }
    return "text"
  }

  /// 1-based inclusive line numbers covered by a UTF-16 selection. A selection that ends right after a
  /// newline does not include the following line.
  static func lineRange(in text: NSString, selection: NSRange) -> (start: Int, end: Int) {
    func line(at location: Int) -> Int {
      var count = 1
      var index = 0
      let limit = min(location, text.length)
      while index < limit {
        let found = text.range(of: "\n", range: NSRange(location: index, length: limit - index))
        if found.location == NSNotFound { break }
        count += 1
        index = found.location + 1
      }
      return count
    }
    let start = line(at: selection.location)
    var endLocation = selection.location + selection.length
    if selection.length > 0, endLocation > 0, endLocation <= text.length, text.character(at: endLocation - 1) == 0x0A { endLocation -= 1 }
    return (start, max(start, line(at: endLocation)))
  }

  /// `L12` or `L12 to L20`, the web's range label.
  static func rangeLabel(start: Int, end: Int) -> String { start == end ? "L\(start)" : "L\(start) to L\(end)" }

  /// The lines `start...end` (1-based) of `text`.
  static func lines(_ text: String, from start: Int, to end: Int) -> String {
    let all = text.split(separator: "\n", omittingEmptySubsequences: false)
    let lo = max(1, start), hi = min(all.count, max(lo, end))
    guard lo <= hi else { return "" }
    return all[(lo - 1)..<hi].joined(separator: "\n")
  }

  /// Highlight positions of `query` (a subsequence) inside `value`, case-insensitive; empty when absent.
  static func matchIndices(of value: String, query: String) -> [Int] {
    let needle = Array(query.lowercased().filter { !$0.isWhitespace })
    guard !needle.isEmpty else { return [] }
    var result: [Int] = []
    var next = 0
    for (index, character) in value.lowercased().enumerated() where next < needle.count && character == needle[next] {
      result.append(index)
      next += 1
    }
    return next == needle.count ? result : []
  }

  /// Quoted delimiters, escaped quotes and multiline cells; at most 100 rows, 30 columns, 2000 characters
  /// per cell (`parseDelimitedPreview`). The source view keeps every byte.
  static func parseDelimited(_ text: String, delimiter: Character) -> (rows: [[String]], truncated: Bool) {
    let scalars = Array(text.unicodeScalars)
    let delimiterScalar = delimiter.unicodeScalars.first!
    var rows: [[String]] = []
    var row: [String] = []
    var cell = String.UnicodeScalarView()
    var cellLength = 0
    var quoted = false
    var truncated = false
    var rowStart = scalars.first == "\u{FEFF}" ? 1 : 0
    func endCell() {
      if row.count < 30 { row.append(String(cell)) } else { truncated = true }
      cell = String.UnicodeScalarView()
      cellLength = 0
    }
    func append(_ scalar: Unicode.Scalar) {
      if cellLength < 2000 {
        cell.append(scalar)
        cellLength += 1
      } else {
        truncated = true
      }
    }
    var index = rowStart
    while index < scalars.count {
      let char = scalars[index]
      if char == "\"" {
        if quoted, index + 1 < scalars.count, scalars[index + 1] == "\"" {
          append("\"")
          index += 2
          continue
        }
        if quoted || cellLength == 0 {
          quoted.toggle()
          index += 1
          continue
        }
      }
      if !quoted, char == delimiterScalar || char == "\n" || char == "\r" {
        endCell()
        if char != delimiterScalar {
          rows.append(row)
          row = []
          if char == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" { index += 1 }
          rowStart = index + 1
          if rows.count == 100 { return (rows, truncated || index < scalars.count - 1) }
        }
      } else {
        append(char)
      }
      index += 1
    }
    if rowStart < scalars.count {
      endCell()
      rows.append(row)
    }
    return (rows, truncated || quoted)
  }
}
