import Foundation

// Port of packages/client-runtime/src/work-log/commandLabel.ts: the program a shell or
// PowerShell command line runs, for labels such as "Running git". The TypeScript works on UTF-16
// indices and JavaScript regular expressions, so this port does too (`[UInt16]` and
// NSRegularExpression, with `\z` where JavaScript's `$` means end of input).

/// The program a command runs, or nil when the line gives no reliable answer.
public func commandProgramName(_ command: String) -> String? {
  CommandLabel.programName(command, depth: 0, context: .shell, segmentsRemaining: CommandLabel.maxSegments)
}

private struct Rx: @unchecked Sendable {
  let regex: NSRegularExpression

  init(_ pattern: String, ignoreCase: Bool = false, dotAll: Bool = false) {
    var options: NSRegularExpression.Options = []
    if ignoreCase { options.insert(.caseInsensitive) }
    if dotAll { options.insert(.dotMatchesLineSeparators) }
    regex = try! NSRegularExpression(pattern: pattern, options: options)
  }

  func firstMatch(_ string: String) -> [String?]? {
    let ns = string as NSString
    guard let match = regex.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return (0..<match.numberOfRanges).map { index in
      let range = match.range(at: index)
      return range.location == NSNotFound ? nil : ns.substring(with: range)
    }
  }

  func test(_ string: String) -> Bool { firstMatch(string) != nil }
}

private enum Patterns {
  static let windowsPathSoFar = Rx("^(?:[A-Za-z]:|\\.{1,2})(?:\\\\[^\\s]*)?\\z")
  static let processSubstitution = Rx("^[<>]\\(")
  static let redirection = Rx(
    "^(?:(?:(?:\\d+|\\*|\\{[A-Za-z_][A-Za-z0-9_]*\\})?(?:<<<|<<-|<<|<>|>>|>\\||<&|>&|<|>))|&>>|&>)(.*)\\z")
  static let scriptOption = Rx("^-[adkpqr]+\\z")
  static let archOption = Rx("^-(?:arm64|arm64e|i386|x86_64)\\z")
  static let timeoutDuration = Rx("^(?:\\d+(?:\\.\\d*)?|\\.\\d+)[smhd]?\\z")
  static let urlScheme = Rx("^[A-Za-z][A-Za-z0-9+.-]*:(?![\\\\/])")
  static let nonSpace = Rx("^\\S+")
  static let callOperator = Rx("^\\s*&\\s+([\\s\\S]*)\\z")
  static let powerShellAssignment = Rx("^\\s*\\$(?:(env|global|local|script):)?[A-Za-z_][A-Za-z0-9_]*\\s*=\\s*([\\s\\S]*)\\z", ignoreCase: true)
  static let collectionLiteral = Rx("^(?:\\[ordered\\]\\s*)?@\\s*[{(]", ignoreCase: true)
  static let directCommand = Rx("^(?:@?\\(\\s*)?([A-Za-z][A-Za-z0-9_.-]*)\\b")
  static let literalAssignment = Rx("^([A-Za-z_][A-Za-z0-9_]*)=(.*)\\z", dotAll: true)
  static let aliasReference = Rx("^\\$(?:([A-Za-z_][A-Za-z0-9_]*)|\\{([A-Za-z_][A-Za-z0-9_]*)(?:\\[@\\])?\\})\\z")
  static let assignmentPrefix = Rx("^[A-Za-z_][A-Za-z0-9_]*\\+?=")
  static let controlKeyword = Rx("^(?:catch|finally|for|foreach|function|if|param|switch|try|while)\\s*[{(]", ignoreCase: true)
  static let functionDefinition = Rx("^[A-Za-z_][A-Za-z0-9_]*\\s*\\(\\s*\\)\\s*\\{")
  static let hereStringStart = Rx("^@[\"'](?:\\r?\\n)")
  static let windowsPathProgram = Rx("^\\s*((?:\\.{1,2}|%[A-Za-z_][A-Za-z0-9_]*%|\\$env:[A-Za-z_][A-Za-z0-9_]*)\\\\\\S+)", ignoreCase: true)
  static let quotedWithSyntax = Rx("[\\s()=]")
  static let execAlias = Rx("^-a.+")
  static let execFlags = Rx("^-[cl]+\\z")
  static let shellCommandFlag = Rx("^-[a-zA-Z]*c[a-zA-Z]*\\z")
  static let combinedShortOptions = Rx("^-[A-Za-z].+")
  static let functionBraceToken = Rx("^[A-Za-z_][A-Za-z0-9_]*\\(\\)\\{\\z")
  static let dollarOrBacktick = Rx("[$`]")
}

private typealias Units = [UInt16]

private func units(_ string: String) -> Units { Array(string.utf16) }
private func text(_ units: some Collection<UInt16>) -> String { String(decoding: units, as: UTF16.self) }
private func unit(_ character: Character) -> UInt16 { character.utf16.first! }

private let quoteDouble = unit("\"")
private let quoteSingle = unit("'")
private let backslash = unit("\\")
private let backtick = unit("`")
private let dollar = unit("$")
private let braceOpen = unit("{")
private let braceClose = unit("}")
private let parenOpen = unit("(")
private let parenClose = unit(")")
private let newline = unit("\n")
private let carriageReturn = unit("\r")
private let hash = unit("#")
private let at = unit("@")
private let lessThan = unit("<")
private let greaterThan = unit(">")
private let ampersand = unit("&")
private let pipe = unit("|")
private let semicolon = unit(";")
private let dash = unit("-")

private func isSpace(_ code: UInt16?) -> Bool {
  guard let code, let scalar = Unicode.Scalar(code) else { return false }
  return isJSWhitespace(scalar)
}

private func contains(_ set: String, _ code: UInt16?) -> Bool {
  guard let code else { return false }
  return set.utf16.contains(code)
}

private extension Array where Element == UInt16 {
  subscript(safe index: Int) -> UInt16? { index >= 0 && index < count ? self[index] : nil }
}

private func jsTrimStart(_ value: String) -> String {
  let scalars = value.unicodeScalars
  guard let start = scalars.firstIndex(where: { !isJSWhitespace($0) }) else { return "" }
  return String(scalars[start...])
}

private func jsTrimStartUnits(_ value: Units) -> Units { Array(units(jsTrimStart(text(value)))) }

private enum CommandLabel {
  static let maxSegments = 64

  enum Context { case exec, shell }
  enum Wrapper: String { case env, sudo }

  static let shellPrograms: Set<String> = ["sh", "bash", "zsh", "dash", "ash", "ksh", "fish"]
  static let windowsShellPrograms: Set<String> = ["cmd", "cmd.exe", "powershell", "powershell.exe", "pwsh", "pwsh.exe"]
  static let shellOptionsWithValue: Set<String> = ["-o", "-O", "--rcfile", "--init-file"]
  static let shellCommandWrappers: Set<String> = ["builtin", "command", "exec"]
  static let shellPrecommandModifiers: Set<String> = ["nocorrect", "noglob", "time"]
  static let powershellSetupPrograms: Set<String> = ["pop-location", "push-location", "set-location"]
  static let powershellFlags: Set<String> = ["-mta", "-nologo", "-noninteractive", "-noprofile", "-sta"]
  static let powershellOptionsWithValue: Set<String> = [
    "-configurationname", "-executionpolicy", "-inputformat", "-outputformat", "-version", "-windowstyle", "-workingdirectory",
  ]
  static let startProcessFlags: Set<String> = [
    "-confirm", "-debug", "-loaduserprofile", "-nonewwindow", "-passthru", "-usenewenvironment", "-verbose", "-wait", "-whatif",
  ]
  static let startProcessOptionsWithValue: Set<String> = [
    "-argumentlist", "-credential", "-environment", "-erroraction", "-errorvariable", "-informationaction",
    "-informationvariable", "-outbuffer", "-outvariable", "-pipelinevariable", "-progressaction", "-redirectstandarderror",
    "-redirectstandardinput", "-redirectstandardoutput", "-verb", "-warningaction", "-warningvariable", "-windowstyle",
    "-workingdirectory",
  ]
  static let skippableSudoProbes: Set<String> = ["[", "[[", "test", "true"]
  static let nonProgramPrefixCharacters = "<>(){}[];|&$`#!%@:"
  static let nonProgramSuffixCharacters = "){]}`"

  // These tokens describe shell syntax or shell-local control flow, not a useful executable
  // name. Falling back to "command" is less misleading than labels such as "Ran if".
  static let nonDescriptiveShellPrograms: Set<String> = [
    "!", "#", ".", ":", "[", "[[", "alias", "and", "autoload", "begin", "bg", "bind", "bindkey", "break", "builtin", "caller",
    "case", "catch", "cd", "command", "compgen", "complete", "compopt", "continue", "coproc", "declare", "dirs", "disown", "do",
    "done", "elif", "else", "enable", "end", "esac", "eval", "exec", "exit", "export", "false", "fc", "fg", "fi", "finally",
    "for", "foreach", "function", "getopts", "history", "if", "in", "jobs", "let", "local", "logout", "mapfile", "nocorrect",
    "noglob", "not", "or", "popd", "pushd", "read", "readarray", "readonly", "repeat", "return", "select", "set", "setopt",
    "shift", "shopt", "source", "switch", "suspend", "test", "then", "time", "times", "trap", "try", "true", "type", "typeset",
    "ulimit", "umask", "unalias", "until", "unset", "unsetopt", "wait", "while",
  ]

  // Unlike setup builtins, these can make later segments part of control flow or otherwise
  // unreachable, so a later program is not used as the command label.
  static let terminalShellPrograms: Set<String> = [
    "and", "begin", "break", "case", "catch", "continue", "coproc", "do", "done", "elif", "else", "end", "esac", "eval", "exec",
    "exit", "false", "fi", "finally", "for", "foreach", "function", "if", "in", "not", "or", "repeat", "return", "select",
    "switch", "then", "try", "until", "while",
  ]

  static let wrapperOptionsWithValue: [Wrapper: Set<String>] = [
    .env: ["-C", "--chdir", "-S", "--split-string", "-u", "--unset"],
    .sudo: ["-C", "--close-from", "-D", "--chdir", "-g", "--group", "-u", "--user"],
  ]
  static let wrapperFlags: [Wrapper: Set<String>] = [
    .env: ["-0", "--null", "-i", "--ignore-environment", "--debug", "-v"],
    .sudo: ["-A", "--askpass", "-b", "--background", "-E", "-H", "-i", "-n", "-S"],
  ]

  static func shellCommandArgumentIndex(_ tokens: [String], start: Int) -> Int? {
    var index = start
    while index < tokens.count {
      let option = tokens[index]
      if option == "--" || !option.hasPrefix("-") { return nil }
      if shellOptionsWithValue.contains(option) {
        index += 2
        continue
      }
      if option == "--command" || Patterns.shellCommandFlag.test(option) { return index + 1 }
      index += 1
    }
    return nil
  }

  // MARK: Tokenizing

  static func tokenize(_ command: String) -> [String]? {
    let input = units(command.jsTrimmed)
    var tokens: [String] = []
    var current = Units()
    var quote: UInt16?
    var escaping = false
    var inBackticks = false
    var substitutionDepth = 0
    var parameterExpansionDepth = 0
    var tokenStarted = false

    var index = 0
    while index < input.count {
      defer { index += 1 }
      let character = input[index]
      if escaping {
        current.append(character)
        escaping = false
        tokenStarted = true
        continue
      }
      if character == backslash && quote != quoteSingle {
        let next = input[safe: index + 1]
        let isWindowsPath = quote == nil && Patterns.windowsPathSoFar.test(text(current))
        if (quote == quoteDouble || isWindowsPath), let next, next != quoteDouble, next != backslash, next != dollar,
          next != backtick, next != newline
        {
          current.append(character)
          tokenStarted = true
          continue
        }
        escaping = true
        tokenStarted = true
        continue
      }
      if inBackticks {
        current.append(character)
        if character == backtick { inBackticks = false }
        tokenStarted = true
        continue
      }
      if let activeQuote = quote {
        if character == activeQuote { quote = nil } else { current.append(character) }
        tokenStarted = true
        continue
      }
      if character == backtick {
        current.append(character)
        inBackticks = true
        tokenStarted = true
        continue
      }
      if character == dollar && input[safe: index + 1] == braceOpen {
        current.append(contentsOf: [dollar, braceOpen])
        parameterExpansionDepth += 1
        tokenStarted = true
        index += 1
        continue
      }
      if character == braceOpen && parameterExpansionDepth > 0 {
        current.append(character)
        parameterExpansionDepth += 1
        tokenStarted = true
        continue
      }
      if character == braceClose && parameterExpansionDepth > 0 {
        current.append(character)
        parameterExpansionDepth -= 1
        tokenStarted = true
        continue
      }
      if character == dollar && input[safe: index + 1] == parenOpen {
        current.append(contentsOf: [dollar, parenOpen])
        substitutionDepth += 1
        tokenStarted = true
        index += 1
        continue
      }
      if character == parenOpen {
        current.append(character)
        substitutionDepth += 1
        tokenStarted = true
        continue
      }
      if character == parenClose && substitutionDepth > 0 {
        current.append(character)
        substitutionDepth -= 1
        tokenStarted = true
        continue
      }
      if character == quoteDouble || character == quoteSingle {
        quote = character
        tokenStarted = true
        continue
      }
      if isSpace(character) {
        if substitutionDepth > 0 || parameterExpansionDepth > 0 {
          current.append(character)
          tokenStarted = true
          continue
        }
        if tokenStarted {
          tokens.append(text(current))
          current = []
          tokenStarted = false
        }
        continue
      }
      current.append(character)
      tokenStarted = true
    }

    if quote != nil || escaping || inBackticks || substitutionDepth > 0 || parameterExpansionDepth > 0 { return nil }
    if tokenStarted { tokens.append(text(current)) }
    return tokens
  }

  // MARK: Splitting at the first top-level separator

  struct Heredoc {
    var delimiter: String
    var stripTabs: Bool
  }

  struct Split {
    var firstCommand: String
    var remainingCommand: String?
    var separator: String?
  }

  static func withoutComments(_ command: Units, end: Int, comments: [(start: Int, end: Int)]) -> String {
    var result = Units()
    var cursor = 0
    for comment in comments {
      if comment.start >= end { break }
      result.append(contentsOf: command[cursor..<max(cursor, comment.start)])
      cursor = min(comment.end, end)
    }
    result.append(contentsOf: command[min(cursor, end)..<end])
    return text(result)
  }

  static func readHeredocDelimiter(_ command: Units, start: Int, stripTabs: Bool) -> (heredoc: Heredoc, end: Int)? {
    var index = start
    while command[safe: index] == unit(" ") || command[safe: index] == unit("\t") { index += 1 }
    var delimiter = Units()
    var quote: UInt16?
    var escaping = false
    while index < command.count {
      let character = command[index]
      defer { index += 1 }
      if escaping {
        delimiter.append(character)
        escaping = false
        continue
      }
      if character == backslash && quote != quoteSingle {
        escaping = true
        continue
      }
      if let activeQuote = quote {
        if character == activeQuote { quote = nil } else { delimiter.append(character) }
        continue
      }
      if character == quoteDouble || character == quoteSingle {
        quote = character
        continue
      }
      if isSpace(character) || contains(";&|<>()", character) {
        // `break` leaves `index` on the delimiter terminator.
        return finishHeredoc(delimiter, quote, escaping, index, stripTabs)
      }
      delimiter.append(character)
    }
    return finishHeredoc(delimiter, quote, escaping, index, stripTabs)
  }

  private static func finishHeredoc(_ delimiter: Units, _ quote: UInt16?, _ escaping: Bool, _ index: Int, _ stripTabs: Bool)
    -> (Heredoc, Int)?
  {
    if delimiter.isEmpty || quote != nil || escaping { return nil }
    return (Heredoc(delimiter: text(delimiter), stripTabs: stripTabs), index)
  }

  static func commandAfterHeredocs(_ command: Units, start: Int, heredocs: [Heredoc]) -> String? {
    var cursor = start
    for heredoc in heredocs {
      var foundDelimiter = false
      while cursor <= command.count {
        let newlineIndex = command[min(cursor, command.count)...].firstIndex(of: newline)
        let lineEnd = newlineIndex ?? command.count
        var line = text(command[min(cursor, lineEnd)..<lineEnd])
        if line.hasSuffix("\r") { line.removeLast() }
        var comparable = line
        if heredoc.stripTabs { while comparable.hasPrefix("\t") { comparable.removeFirst() } }
        cursor = newlineIndex.map { $0 + 1 } ?? command.count
        if comparable == heredoc.delimiter {
          foundDelimiter = true
          break
        }
        if newlineIndex == nil { break }
      }
      if !foundDelimiter { return nil }
    }
    let rest = text(command[min(cursor, command.count)...]).jsTrimmed
    return rest.isEmpty ? nil : rest
  }

  static func splitFirst(_ commandString: String) -> Split {
    let command = units(commandString)
    var quote: UInt16?
    var powerShellHereStringQuote: UInt16?
    var escaping = false
    var inBackticks = false
    var inComment = false
    var substitutionDepth = 0
    var parameterExpansionDepth = 0
    var heredocs: [Heredoc] = []
    var comments: [(start: Int, end: Int)] = []
    var commentStart = 0
    var separatorBeforeHeredocs: (index: Int, length: Int)?

    var index = 0
    while index < command.count {
      defer { index += 1 }
      let character = command[index]
      if let hereQuote = powerShellHereStringQuote {
        if character == hereQuote && command[safe: index + 1] == at && (index == 0 || command[safe: index - 1] == newline) {
          powerShellHereStringQuote = nil
          index += 1
        }
        continue
      }
      if inComment {
        if character != newline { continue }
        inComment = false
        comments.append((commentStart, index))
      }
      if escaping {
        escaping = false
        continue
      }
      if character == backslash && quote != quoteSingle {
        escaping = true
        continue
      }
      if inBackticks {
        if character == backtick { inBackticks = false }
        continue
      }
      if let activeQuote = quote {
        if character == activeQuote { quote = nil }
        continue
      }
      if character == at, command[safe: index + 1] == quoteDouble || command[safe: index + 1] == quoteSingle,
        command[safe: index + 2] == newline || (command[safe: index + 2] == carriageReturn && command[safe: index + 3] == newline)
      {
        powerShellHereStringQuote = command[index + 1]
        index += 1
        continue
      }
      if character == quoteDouble || character == quoteSingle {
        quote = character
        continue
      }
      if character == backtick {
        inBackticks = true
        continue
      }
      if character == hash && (index == 0 || isSpace(command[index - 1]) || contains(";&|(", command[index - 1])) {
        inComment = true
        commentStart = index
        continue
      }
      if character == dollar && command[safe: index + 1] == braceOpen {
        parameterExpansionDepth += 1
        index += 1
        continue
      }
      if character == braceOpen && parameterExpansionDepth > 0 {
        parameterExpansionDepth += 1
        continue
      }
      if character == braceClose && parameterExpansionDepth > 0 {
        parameterExpansionDepth -= 1
        continue
      }
      if character == parenOpen {
        substitutionDepth += 1
        continue
      }
      if character == parenClose && substitutionDepth > 0 {
        substitutionDepth -= 1
        continue
      }
      if substitutionDepth > 0 || parameterExpansionDepth > 0 { continue }

      if character == lessThan && command[safe: index + 1] == lessThan && command[safe: index + 2] != lessThan {
        let stripTabs = command[safe: index + 2] == dash
        guard let delimiter = readHeredocDelimiter(command, start: index + (stripTabs ? 3 : 2), stripTabs: stripTabs) else {
          return Split(firstCommand: commandString.jsTrimmed, remainingCommand: nil, separator: nil)
        }
        heredocs.append(delimiter.heredoc)
        index = delimiter.end - 1
        continue
      }

      let next = command[safe: index + 1]
      let isDoubleOperator =
        (character == ampersand && next == ampersand) || (character == pipe && (next == pipe || next == ampersand))
      let previous = command[safe: index - 1]
      let isRedirectionAmpersand = character == ampersand && (previous == greaterThan || previous == lessThan || next == greaterThan)
      if (!isDoubleOperator && !contains(";&|\n", character)) || isRedirectionAmpersand { continue }

      if character == newline && !heredocs.isEmpty {
        let separator = separatorBeforeHeredocs
        let firstCommand = jsTrimStart(withoutComments(command, end: separator?.index ?? index, comments: comments))
        let commandBeforeHeredocs = separator.map { text(command[($0.index + $0.length)..<max($0.index + $0.length, index)]).jsTrimmed } ?? ""
        let commandFollowingHeredocs = commandAfterHeredocs(command, start: index + 1, heredocs: heredocs)
        let remaining = [commandBeforeHeredocs, commandFollowingHeredocs].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        return Split(
          firstCommand: firstCommand,
          remainingCommand: remaining.isEmpty ? nil : remaining,
          separator: separator.map { text(command[$0.index..<min(command.count, $0.index + $0.length)]) } ?? "\n"
        )
      }
      if !heredocs.isEmpty {
        if separatorBeforeHeredocs == nil { separatorBeforeHeredocs = (index, isDoubleOperator ? 2 : 1) }
        if isDoubleOperator { index += 1 }
        continue
      }

      let firstCommand = jsTrimStart(withoutComments(command, end: index, comments: comments))
      var nextCommandIndex = index + (isDoubleOperator ? 2 : 1)
      while isSpace(command[safe: nextCommandIndex]) { nextCommandIndex += 1 }
      let nextCommand = text(command[min(nextCommandIndex, command.count)...]).jsTrimmed
      return Split(
        firstCommand: firstCommand,
        remainingCommand: nextCommand.isEmpty ? nil : nextCommand,
        separator: isDoubleOperator ? text(command[index..<min(command.count, index + 2)]) : text([character])
      )
    }

    if inComment { comments.append((commentStart, command.count)) }
    return Split(firstCommand: withoutComments(command, end: command.count, comments: comments).jsTrimmed, remainingCommand: nil, separator: nil)
  }

  static func withoutLeadingComments(_ command: String) -> String? {
    var remaining = jsTrimStart(command)
    while remaining.hasPrefix("#") {
      guard let newlineIndex = remaining.firstIndex(of: "\n") else { return nil }
      remaining = jsTrimStart(String(remaining[remaining.index(after: newlineIndex)...]))
    }
    return remaining.isEmpty ? nil : remaining
  }

  static func withoutLineContinuations(_ commandString: String) -> String {
    let command = units(commandString)
    var normalized = Units()
    var quote: UInt16?
    var escaping = false
    var index = 0
    while index < command.count {
      defer { index += 1 }
      let character = command[index]
      if escaping {
        normalized.append(character)
        escaping = false
        continue
      }
      if character == backslash && quote != quoteSingle {
        if command[safe: index + 1] == newline {
          index += 1
          continue
        }
        if command[safe: index + 1] == carriageReturn && command[safe: index + 2] == newline {
          index += 2
          continue
        }
        normalized.append(character)
        escaping = true
        continue
      }
      if let activeQuote = quote {
        if character == activeQuote { quote = nil }
      } else if character == quoteDouble || character == quoteSingle {
        quote = character
      }
      normalized.append(character)
    }
    return text(normalized)
  }

  /// Index after a redirection starting at `index`; nil when the token is not one. A value past
  /// `tokens.count` means the redirection's target is missing.
  static func indexAfterRedirection(_ tokens: [String], _ index: Int) -> Int? {
    guard index < tokens.count else { return nil }
    let token = tokens[index]
    if token.isEmpty || Patterns.processSubstitution.test(token) { return nil }
    guard let match = Patterns.redirection.firstMatch(token) else { return nil }
    if let rest = match[1], !rest.isEmpty { return index + 1 }
    return index + 1 < tokens.count ? index + 2 : tokens.count + 1
  }

  static func serialize(_ tokens: ArraySlice<String>) -> String {
    tokens.map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: " ")
  }

  static func transparentWrapperCommandIndex(_ wrapper: String, _ tokens: [String], _ index: Int) -> Int? {
    func token(_ offset: Int) -> String? { index + offset < tokens.count ? tokens[index + offset] : nil }
    switch wrapper {
    case "bundle":
      return token(1) == "exec" && token(2) != nil ? index + 2 : nil
    case "nohup":
      var target = index + 1
      if token(1) == "--" { target += 1 }
      guard target < tokens.count else { return nil }
      let candidate = tokens[target]
      return !candidate.isEmpty && !candidate.hasPrefix("-") ? target : nil
    case "script":
      // BSD `script` takes an output file before the optional command.
      return Patterns.scriptOption.test(token(1) ?? "") && token(3) != nil ? index + 3 : nil
    case "arch":
      if Patterns.archOption.test(token(1) ?? "") { return token(2) != nil ? index + 2 : nil }
      return token(1) == "-arch" && token(3) != nil ? index + 3 : nil
    case "timeout", "gtimeout":
      return Patterns.timeoutDuration.test(token(1) ?? "") && token(2) != nil ? index + 2 : nil
    default:
      return nil
    }
  }

  // MARK: Program names

  static func lastPathSegment(_ value: String) -> String {
    let parts = value.split(omittingEmptySubsequences: false) { $0 == "\\" || $0 == "/" }
    return parts.last.map(String.init) ?? value
  }

  static func staticProgramName(_ value: String) -> String? {
    let trimmed = value.jsTrimmed
    if trimmed.isEmpty || Patterns.urlScheme.test(trimmed) { return nil }
    let program = lastPathSegment(trimmed)
    let hasSeparator = trimmed.contains("\\") || trimmed.contains("/")
    if program.isEmpty
      || (program.unicodeScalars.contains(where: isJSWhitespace) && !hasSeparator)
      || contains(nonProgramPrefixCharacters, program.utf16.first)
      || contains(nonProgramSuffixCharacters, program.utf16.last)
    {
      return nil
    }
    return program
  }

  static func leadingPowerShellLiteral(_ command: String) -> String? {
    let input = units(jsTrimStart(command))
    guard let quote = input.first, quote == quoteDouble || quote == quoteSingle else {
      return staticProgramName(Patterns.nonSpace.firstMatch(text(input))?[0] ?? "")
    }
    var value = Units()
    var index = 1
    while index < input.count {
      defer { index += 1 }
      let character = input[index]
      if character == backtick, let next = input[safe: index + 1] {
        value.append(next)
        index += 1
        continue
      }
      if character == quote {
        if quote == quoteSingle && input[safe: index + 1] == quoteSingle {
          value.append(quoteSingle)
          index += 1
          continue
        }
        return staticProgramName(text(value))
      }
      value.append(character)
    }
    return nil
  }

  /// `nil` outer: the command is not a `& program` call; `.some(nil)`: it is, with no usable name.
  static func callOperatorProgramName(_ command: String) -> String?? {
    guard let match = Patterns.callOperator.firstMatch(command) else { return .none }
    return .some(leadingPowerShellLiteral(match[1] ?? ""))
  }

  static func powerShellAssignment(
    _ command: String, depth: Int, remaining: String?, segmentsRemaining: Int
  ) -> (matched: Bool, program: String?) {
    guard let assignment = Patterns.powerShellAssignment.firstMatch(command) else { return (false, nil) }
    // Environment assignments are setup. Their right-hand side is a value, not a command.
    if assignment[1]?.lowercased() == "env" {
      return (true, remaining.flatMap { programName($0, depth: depth, context: .shell, segmentsRemaining: segmentsRemaining - 1) })
    }
    let value = (assignment[2] ?? "").jsTrimmed
    // The POSIX-oriented splitter does not balance PowerShell arrays or hashtables.
    if Patterns.collectionLiteral.test(value) { return (true, nil) }
    if let called = callOperatorProgramName(value) { return (true, called) }
    if let direct = Patterns.directCommand.firstMatch(value)?[1], !nonDescriptiveShellPrograms.contains(direct.lowercased()) {
      let parsed = programName(value, depth: depth + 1, context: .shell, segmentsRemaining: segmentsRemaining)
      return (true, parsed ?? direct)
    }
    return (true, remaining.flatMap { programName($0, depth: depth, context: .shell, segmentsRemaining: segmentsRemaining - 1) })
  }

  static func windowsShellPayload(
    shell: String, tokens: [String], start: Int, depth: Int, remaining: String?, separator: String?, segmentsRemaining: Int
  ) -> (matched: Bool, program: String?) {
    func parsePayload(_ payload: String?) -> String? {
      guard let payload, !payload.isEmpty else { return nil }
      let command = remaining != nil && separator != nil && !remaining!.isEmpty && !separator!.isEmpty ? "\(payload) \(separator!) \(remaining!)" : payload
      return programName(command, depth: depth + 1, context: .shell, segmentsRemaining: segmentsRemaining)
    }
    func token(_ index: Int) -> String? { index < tokens.count ? tokens[index] : nil }
    if shell == "cmd" || shell == "cmd.exe" {
      var index = start
      while index < tokens.count {
        let option = tokens[index].lowercased()
        if option == "/c" || option == "/k" { return (true, parsePayload(token(index + 1))) }
        index += 1
      }
      return (false, nil)
    }
    var index = start
    while index < tokens.count {
      let option = tokens[index].lowercased()
      if option == "-command" || option == "-c" { return (true, parsePayload(token(index + 1))) }
      if option == "-file" || option == "-f" { return (true, staticProgramName(token(index + 1) ?? "")) }
      if option == "-encodedcommand" || option == "-enc" || option == "-e" { return (true, nil) }
      if powershellOptionsWithValue.contains(option) {
        index += 2
        continue
      }
      if powershellFlags.contains(option) {
        index += 1
        continue
      }
      if !option.hasPrefix("-") { return (true, staticProgramName(tokens[index])) }
      index += 1
    }
    return (false, nil)
  }

  static func startProcessProgramName(_ tokens: [String], start: Int) -> String? {
    var index = start
    while index < tokens.count {
      let token = tokens[index]
      let option = token.lowercased()
      if option == "-filepath" { return staticProgramName(index + 1 < tokens.count ? tokens[index + 1] : "") }
      if startProcessFlags.contains(option) {
        index += 1
        continue
      }
      if startProcessOptionsWithValue.contains(option) {
        if index + 1 >= tokens.count { return nil }
        index += 2
        continue
      }
      if token.hasPrefix("-") { return nil }
      return staticProgramName(token)
    }
    return nil
  }

  static func literalAssignmentProgram(_ token: String) -> (name: String, program: String?)? {
    guard let assignment = Patterns.literalAssignment.firstMatch(token), let name = assignment[1] else { return nil }
    var value = (assignment[2] ?? "").jsTrimmed
    if value.isEmpty || Patterns.dollarOrBacktick.test(value) { return (name, nil) }
    if value.hasPrefix("(") && value.hasSuffix(")") {
      let inner = String(value.dropFirst().dropLast())
      value = tokenize(inner)?.first ?? ""
    } else if value.unicodeScalars.contains(where: isJSWhitespace) && !value.contains("\\") && !value.contains("/") {
      return (name, nil)
    }
    return (name, staticProgramName(value))
  }

  static func referencedAlias(_ token: String) -> String? {
    guard let reference = Patterns.aliasReference.firstMatch(token) else { return nil }
    return reference[1] ?? reference[2]
  }

  // Recover only literal aliases declared by an earlier top-level shell segment.
  static func literalAliasProgramName(_ command: String) -> String? {
    var aliases: [String: String] = [:]
    var remaining: String? = command
    var controlFlowDepth = 0
    var segmentCount = 0
    while let current = remaining, !current.isEmpty, segmentCount < 64 {
      defer { segmentCount += 1 }
      guard let withoutComments = withoutLeadingComments(current) else { return nil }
      let split = splitFirst(withoutComments)
      guard let tokens = tokenize(withoutLineContinuations(split.firstCommand)) else { return nil }

      var commandIndex = tokens.first == "do" || tokens.first == "then" ? 1 : 0
      while commandIndex < tokens.count {
        if let after = indexAfterRedirection(tokens, commandIndex), after <= tokens.count {
          commandIndex = after
          continue
        }
        if Patterns.assignmentPrefix.test(tokens[commandIndex]) {
          commandIndex += 1
          continue
        }
        break
      }

      if let name = referencedAlias(commandIndex < tokens.count ? tokens[commandIndex] : ""), let aliased = aliases[name], !aliased.isEmpty {
        return aliased
      }

      let leading = tokens.first
      if leading == "fi" || leading == "done" || leading == "esac" { controlFlowDepth = max(0, controlFlowDepth - 1) }
      if let leading, ["if", "for", "while", "until", "select", "case"].contains(leading) { controlFlowDepth += 1 }
      if controlFlowDepth == 0 && leading == "unset" { for name in tokens.dropFirst() { aliases[name] = nil } }

      let assignmentStart = tokens.first == "export" ? 1 : 0
      let assignments = tokens.dropFirst(assignmentStart).map(literalAssignmentProgram)
      if controlFlowDepth == 0 && !assignments.isEmpty && assignments.allSatisfy({ $0 != nil }) {
        for assignment in assignments.compactMap({ $0 }) {
          if let program = assignment.program, !program.isEmpty { aliases[assignment.name] = program } else { aliases[assignment.name] = nil }
        }
      }
      remaining = split.remainingCommand
    }
    return nil
  }

  static func wrappedShellCommandProgramName(
    wrapper: String, tokens: [String], start: Int, depth: Int, remaining: String?, segmentsRemaining: Int
  ) -> String? {
    var index = start
    if wrapper == "command" {
      while index < tokens.count {
        let option = tokens[index]
        if option == "--" {
          index += 1
          break
        }
        if !option.hasPrefix("-") || option == "-" { break }
        if option != "-p" { return nil }
        index += 1
      }
    } else if wrapper == "builtin" {
      if index < tokens.count && tokens[index] == "--" {
        index += 1
      } else if index < tokens.count && tokens[index].hasPrefix("-") {
        return nil
      }
    } else if wrapper == "exec" {
      while index < tokens.count {
        let option = tokens[index]
        if option == "--" {
          index += 1
          break
        }
        if option == "-a" {
          if index + 1 >= tokens.count { return nil }
          index += 2
          continue
        }
        if Patterns.execAlias.test(option) || Patterns.execFlags.test(option) {
          index += 1
          continue
        }
        if option.hasPrefix("-") && option != "-" { return nil }
        break
      }
    }

    let wrappedTokens = Array(tokens[min(index, tokens.count)...])
    if wrappedTokens.isEmpty { return nil }
    var targetIndex = 0
    while targetIndex < wrappedTokens.count {
      guard let after = indexAfterRedirection(wrappedTokens, targetIndex), after <= wrappedTokens.count else { break }
      targetIndex = after
    }
    let target = targetIndex < wrappedTokens.count ? wrappedTokens[targetIndex] : nil
    if let target, Patterns.assignmentPrefix.test(target) { return nil }

    if let wrappedProgram = programName(
      serialize(wrappedTokens[...]), depth: depth + 1, context: wrapper == "exec" ? .exec : .shell, segmentsRemaining: segmentsRemaining)
    {
      return wrappedProgram
    }
    if wrapper != "exec", let target, !target.isEmpty, target == target.lowercased(), nonDescriptiveShellPrograms.contains(target),
      !terminalShellPrograms.contains(target), let remaining
    {
      return programName(remaining, depth: depth, context: .shell, segmentsRemaining: segmentsRemaining - 1)
    }
    return nil
  }

  static func parse(_ command: String, depth: Int, context: Context, segmentsRemaining: Int) -> String? {
    if depth >= 8 || segmentsRemaining <= 0 { return nil }
    guard let withoutComments = withoutLeadingComments(command) else { return nil }
    if Patterns.controlKeyword.test(withoutComments) { return nil }
    if Patterns.functionDefinition.test(withoutComments) { return nil }
    // `&&` and `||` inside a `[[ ... ]]` expression are not top-level command separators.
    if withoutComments.hasPrefix("[[") { return nil }
    let split = splitFirst(withoutComments)
    if Patterns.hereStringStart.test(jsTrimStart(split.firstCommand)) {
      return split.remainingCommand.flatMap { programName($0, depth: depth, context: .shell, segmentsRemaining: segmentsRemaining - 1) }
    }
    let assignment = powerShellAssignment(split.firstCommand, depth: depth, remaining: split.remainingCommand, segmentsRemaining: segmentsRemaining)
    if assignment.matched { return assignment.program }
    if let windowsPath = Patterns.windowsPathProgram.firstMatch(split.firstCommand)?[1] { return staticProgramName(windowsPath) }
    guard let tokens = tokenize(withoutLineContinuations(split.firstCommand)) else { return nil }
    let firstCharacter = jsTrimStart(split.firstCommand).utf16.first
    if tokens.count == 1, firstCharacter == quoteDouble || firstCharacter == quoteSingle,
      Patterns.quotedWithSyntax.test(tokens[0]), !(tokens[0].contains("\\") || tokens[0].contains("/"))
    {
      return split.remainingCommand.flatMap { programName($0, depth: depth, context: context, segmentsRemaining: segmentsRemaining - 1) }
    }

    var index = 0
    var wrapper: Wrapper?
    var executionContext = context
    var sawAssignment = false
    var sawRedirection = false

    while index < tokens.count {
      let token = tokens[index]
      if token.isEmpty { return nil }
      if let after = indexAfterRedirection(tokens, index) {
        if after > tokens.count { return nil }
        sawRedirection = true
        index = after
        continue
      }
      if Patterns.assignmentPrefix.test(token) {
        sawAssignment = true
        index += 1
        continue
      }
      if executionContext == .shell && token == ":" {
        return split.remainingCommand.flatMap {
          programName($0, depth: depth, context: executionContext, segmentsRemaining: segmentsRemaining - 1)
        }
      }
      if contains(nonProgramPrefixCharacters, token.utf16.first), !(token.hasPrefix("$") && token.contains("/")) {
        return executionContext == .shell && token.hasPrefix("[") && split.remainingCommand != nil
          ? programName(split.remainingCommand!, depth: depth, context: executionContext, segmentsRemaining: segmentsRemaining - 1) : nil
      }
      let tokenProgram = lastPathSegment(token)
      let isUnqualifiedToken = token == tokenProgram
      if tokenProgram == "env" || tokenProgram == "sudo" {
        wrapper = Wrapper(rawValue: tokenProgram)
        executionContext = .exec
        index += 1
        continue
      }
      if wrapper != nil && token == "--" {
        wrapper = nil
        index += 1
        continue
      }
      if let activeWrapper = wrapper, token.hasPrefix("-") {
        let withValue = wrapperOptionsWithValue[activeWrapper]!
        let flags = wrapperFlags[activeWrapper]!
        if activeWrapper == .env && (token == "-S" || token == "--split-string") {
          guard index + 1 < tokens.count, !tokens[index + 1].isEmpty else { return nil }
          return programName(tokens[index + 1], depth: depth + 1, context: executionContext, segmentsRemaining: segmentsRemaining)
        }
        if activeWrapper == .env && token.hasPrefix("--split-string=") {
          return programName(
            String(token.dropFirst("--split-string=".count)), depth: depth + 1, context: executionContext,
            segmentsRemaining: segmentsRemaining)
        }
        if withValue.contains(token) {
          if index + 1 >= tokens.count { return nil }
          index += 2
          continue
        }
        if flags.contains(token) {
          index += 1
          continue
        }
        let tokenUnits = units(token)
        if token.hasPrefix("--"), let equalsIndex = tokenUnits.firstIndex(of: unit("=")), equalsIndex > 2 {
          if !withValue.contains(text(tokenUnits[..<equalsIndex])) { return nil }
          index += 1
          continue
        }
        if Patterns.combinedShortOptions.test(token) && !token.hasPrefix("--") {
          var consumesNextToken = false
          for (optionIndex, option) in tokenUnits.dropFirst().enumerated() {
            let shortOption = "-\(text([option]))"
            if withValue.contains(shortOption) {
              consumesNextToken = optionIndex == tokenUnits.count - 2
              break
            }
            if !flags.contains(shortOption) { return nil }
          }
          if consumesNextToken && index + 1 >= tokens.count { return nil }
          index += consumesNextToken ? 2 : 1
          continue
        }
        return nil
      }
      if !tokenProgram.isEmpty {
        var shellName = tokenProgram
        if shellName.lowercased().hasSuffix(".exe") { shellName = String(shellName.dropLast(4)) }
        if shellPrograms.contains(shellName.lowercased()), let scriptIndex = shellCommandArgumentIndex(tokens, start: index + 1) {
          guard scriptIndex < tokens.count, !tokens[scriptIndex].isEmpty else { return nil }
          return programName(tokens[scriptIndex], depth: depth + 1, context: .shell, segmentsRemaining: segmentsRemaining)
        }
      }
      let lowerTokenProgram = tokenProgram.lowercased()
      if !tokenProgram.isEmpty, windowsShellPrograms.contains(lowerTokenProgram) {
        let payload = windowsShellPayload(
          shell: lowerTokenProgram, tokens: tokens, start: index + 1, depth: depth, remaining: split.remainingCommand,
          separator: split.separator, segmentsRemaining: segmentsRemaining)
        if payload.matched { return payload.program }
      }
      if lowerTokenProgram == "start-process", let started = startProcessProgramName(tokens, start: index + 1) { return started }
      if executionContext == .shell && isUnqualifiedToken && !tokenProgram.isEmpty && shellPrecommandModifiers.contains(tokenProgram) {
        index += 1
        if tokenProgram == "time" && index < tokens.count && tokens[index] == "-p" { index += 1 }
        if index < tokens.count && tokens[index].hasPrefix("-") { return nil }
        continue
      }
      if isUnqualifiedToken && !tokenProgram.isEmpty, let targetIndex = transparentWrapperCommandIndex(tokenProgram, tokens, index) {
        if let wrapped = programName(
          serialize(tokens[targetIndex...]), depth: depth + 1, context: .exec, segmentsRemaining: segmentsRemaining)
        {
          return wrapped
        }
      }
      if isUnqualifiedToken && !tokenProgram.isEmpty && shellCommandWrappers.contains(tokenProgram) {
        return wrappedShellCommandProgramName(
          wrapper: tokenProgram, tokens: tokens, start: index + 1, depth: depth, remaining: split.remainingCommand,
          segmentsRemaining: segmentsRemaining)
      }
      if (executionContext == .shell || (wrapper == .sudo && !tokenProgram.isEmpty && skippableSudoProbes.contains(tokenProgram)))
        && isUnqualifiedToken && !tokenProgram.isEmpty && nonDescriptiveShellPrograms.contains(tokenProgram)
        && (!terminalShellPrograms.contains(tokenProgram) || (tokenProgram == "false" && split.separator != "&&"))
        && split.remainingCommand != nil
      {
        return programName(split.remainingCommand!, depth: depth, context: .shell, segmentsRemaining: segmentsRemaining - 1)
      }
      if executionContext == .shell && isUnqualifiedToken && powershellSetupPrograms.contains(lowerTokenProgram)
        && split.remainingCommand != nil
      {
        return programName(split.remainingCommand!, depth: depth, context: .shell, segmentsRemaining: segmentsRemaining - 1)
      }
      if tokenProgram.isEmpty
        || (isUnqualifiedToken && nonDescriptiveShellPrograms.contains(tokenProgram))
        || contains(nonProgramPrefixCharacters, tokenProgram.utf16.first)
        || contains(nonProgramSuffixCharacters, tokenProgram.utf16.last)
        || tokenProgram.hasSuffix("()")
        || Patterns.functionBraceToken.test(tokenProgram)
      {
        return nil
      }
      return tokenProgram
    }

    if (sawAssignment || sawRedirection) && wrapper == nil, let remaining = split.remainingCommand {
      return programName(remaining, depth: depth, context: executionContext, segmentsRemaining: segmentsRemaining - 1)
    }
    return nil
  }

  static func programName(_ command: String, depth: Int, context: Context, segmentsRemaining: Int) -> String? {
    if segmentsRemaining <= 0 { return nil }
    if let called = callOperatorProgramName(command) { return called }
    return parse(command, depth: depth, context: context, segmentsRemaining: segmentsRemaining)
      ?? (context == .shell ? literalAliasProgramName(command) : nil)
  }
}

// MARK: - Display text

/// The command as rows show it: a plain shell -c wrapper removed and control characters made
/// visible (`commandDisplayText`). Callers retain the original for details.
public func commandDisplayText(_ command: String) -> String {
  withVisibleControlCharacters(withoutShellWrapper(command))
}

/// Replaces each control character with its control picture; tab, newline and carriage return stay.
public func withVisibleControlCharacters(_ text: String) -> String {
  var out = String.UnicodeScalarView()
  for scalar in text.unicodeScalars {
    switch scalar.value {
    case 0x7f: out.append("\u{2421}")
    case 0...8, 0x0b, 0x0c, 0x0e...0x1f: out.append(Unicode.Scalar(0x2400 + scalar.value)!)
    default: out.append(scalar)
    }
  }
  return String(out)
}

// A wrapper whose quoting does not balance is kept: the script's end cannot be known.
private func withoutShellWrapper(_ command: String) -> String {
  let trimmed = command.jsTrimmed
  if CommandLabel.splitFirst(trimmed).remainingCommand != nil { return trimmed }
  guard let tokens = CommandLabel.tokenize(trimmed), let first = tokens.first else { return trimmed }
  var program = first.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
  if program.lowercased().hasSuffix(".exe") { program = String(program.dropLast(4)) }
  guard !program.isEmpty, CommandLabel.shellPrograms.contains(program),
    let scriptIndex = CommandLabel.shellCommandArgumentIndex(tokens, start: 1), scriptIndex == tokens.count - 1
  else { return trimmed }
  let script = tokens[scriptIndex].jsTrimmed
  return script.isEmpty ? trimmed : script
}
