import Foundation
import Testing

@testable import T3Timeline

/// commandLabel.test.ts replayed by scripts/timeline-oracle/commandLabelTests.ts: every
/// (command, expected program) pair the TypeScript test asserts.
@Suite struct CommandLabelTests {
  @Test func matchesEveryExpectationOfTheTypeScriptTests() throws {
    let expected = try Oracle.load(Oracle.directory(raw: false), "expected", "_commandLabelTests")
    let cases = try #require(expected["cases"] as? [[String: Any]])
    #expect(cases.count > 300)
    var failures: [String] = []
    for item in cases {
      let command = try #require(item["command"] as? String)
      let want = item["program"] as? String
      let got = commandProgramName(command)
      if got != want { failures.append("\(command.prefix(70).debugDescription): expected \(want ?? "nil"), got \(got ?? "nil") [\(item["title"] as? String ?? "")]") }
    }
    #expect(failures.isEmpty, "\(failures.count) mismatches:\n\(failures.prefix(15).joined(separator: "\n"))")
  }

  @Test(arguments: [
    ("/bin/zsh -lc 'git diff --check'", "git"),
    ("sudo -u root pnpm test", "pnpm"),
    ("cd packages/client-runtime && vp test run", "vp"),
    ("timeout 10 pnpm test", "pnpm"),
    ("cmd /c cd C:\\work && npm test", "npm"),
    ("$env:CI='1'; npm test", "npm"),
  ])
  func readableExamples(command: String, program: String) {
    #expect(commandProgramName(command) == program)
  }

  @Test func fallsBackForShellSyntaxAndMalformedScripts() {
    for command in ["", "zsh -lc 'git status", "if test -f package.json; then vp test; fi", "[[ -f package.json ]]", "cd one && cd two", "true"] {
      #expect(commandProgramName(command) == nil, "\(command)")
    }
  }
}
