import Foundation
import Testing
import T3Contracts
@testable import T3ClientRuntime

@Suite struct ProjectCommandTests {
  @Test func metaUpdateBecomesAProjectMutation() throws {
    let meta = CommandMeta(commandId: "c1", createdAt: "2026-08-07T12:00:00.000Z")
    let icon = ProjectIconOverride.emoji(ProjectIconOverrideEmoji(emoji: "🚀"))
    let plan = try CommandTranslation.plan(for: ProjectCommand.metaUpdate("p1", title: "New", projectIcon: .some(icon), faviconPath: .some(nil), meta: meta))
    guard case .project(.projectUpdate(let update)) = plan.first, plan.count == 1 else {
      Issue.record("expected project.update")
      return
    }
    #expect(update.commandId == "c1" && update.projectId == "p1" && update.title == "New")
    #expect(update.projectIcon == .some(icon))
    // A cleared favicon stays an explicit null on the wire; an untouched field is absent.
    #expect(update.faviconPath == .some(nil))
    #expect(update.scripts == nil && update.workspaceRoot == nil)
    let encoded = String(decoding: try JSONEncoder().encode(update), as: UTF8.self)
    #expect(encoded.contains("\"faviconPath\":null") && !encoded.contains("scripts"))
  }

  @Test func deleteForcesRemovalOfThreads() throws {
    guard case .project(.projectDelete(let delete)) = try CommandTranslation.plan(for: ProjectCommand.delete("p1", meta: CommandMeta(commandId: "c2", createdAt: "2026-08-07T12:00:00.000Z"))).first
    else {
      Issue.record("expected project.delete")
      return
    }
    #expect(delete.projectId == "p1" && delete.force == true)
  }
}

@Suite struct ProjectIdentityTests {
  @Test func monogramFollowsTheWebRules() {
    #expect(ProjectIdentity.monogram("kestrel") == "KL")
    #expect(ProjectIdentity.monogram("t3code-in-swift") == "T3")
    #expect(ProjectIdentity.monogram("my cool app") == "MA")
    #expect(ProjectIdentity.monogram("  ") == "PR")
    #expect(ProjectIdentity.monogram("x") == "XX")
  }

  @Test func colourIsStableAndInThePalette() {
    #expect(ProjectIdentity.color("Kestrel") == ProjectIdentity.color("  kestrel "))
    #expect(ProjectIconColor.palette.contains(ProjectIdentity.color("anything")))
    #expect(ProjectIdentity.color("") == ProjectIdentity.color("project"))
  }

  @Test func monogramValidation() {
    #expect(ProjectIdentity.isValidMonogram("AB") && ProjectIdentity.isValidMonogram("7"))
    #expect(!ProjectIdentity.isValidMonogram("") && !ProjectIdentity.isValidMonogram("ABC") && !ProjectIdentity.isValidMonogram("-A"))
  }
}

@Suite struct T3ProjectFileTests {
  @Test func readsActionsFromJsonWithCommentsAndTrailingCommas() {
    let state = T3ProjectFile.parse(
      """
      {
        // team actions
        "$schema": "https://t3.codes/schema/t3.json",
        "scripts": [
          { "name": " Setup ", "command": "bun i", "runOnWorktreeCreate": true, "async": false, "icon": "configure", },
          { "name": "Dev", "command": "bun dev # not // a comment", "previewUrl": "http://localhost:3000" },
        ],
      }
      """)
    guard case .valid(let scripts) = state else {
      Issue.record("expected a valid file, got \(state)")
      return
    }
    #expect(scripts.map(\.name) == ["Setup", "Dev"])
    #expect(scripts[0].runOnWorktreeCreate && scripts[0].async == false && scripts[0].icon == .configure)
    #expect(scripts[1].command == "bun dev # not // a comment" && scripts[1].previewUrl == "http://localhost:3000")
  }

  @Test func aBrokenFileIsInvalidNotMissing() {
    for bad in [
      "{ not json", "[]", #"{"scripts": [{"name": "A"}]}"#, #"{"scripts": [{"name": "A", "command": "x", "icon": "rocket"}]}"#,
      #"{"scripts": [{"name": " ", "command": "x"}]}"#, #"{"defaultThreadEnvMode": "cloud"}"#, #"{"iconPath": ""}"#,
    ] { #expect(T3ProjectFile.parse(bad) == .invalid, "\(bad)") }
    #expect(T3ProjectFile.parse("{}") == .valid(scripts: []))
  }
}
