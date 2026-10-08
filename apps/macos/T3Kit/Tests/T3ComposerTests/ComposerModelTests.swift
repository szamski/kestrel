import Foundation
import T3Contracts
import T3Timeline
import Testing

@testable import T3Composer

@MainActor
@Suite("Composer model") struct ComposerModelTests {
  @Test func startupResolvesTheModelAndShowsTheDefaultPlaceholder() async throws {
    let fixture = try await ModelFixture.make()
    #expect(fixture.model.selectedEntry?.instanceId == "codex")
    #expect(fixture.model.selectedModel == "gpt-6-astra")
    #expect(fixture.model.placeholder == "Ask anything, @tag files/folders, $use skills, or / for commands")
    #expect(!fixture.model.hasSendableContent && !fixture.model.canSend)
    #expect(fixture.model.runtimeMode == .fullAccess)
  }

  @Test func typingAnAtSignSearchesTheWorkspaceAndPickingInsertsAFileLink() async throws {
    let fixture = try await ModelFixture.make()
    fixture.type("look at @mai")
    #expect(fixture.model.trigger?.kind == .path && fixture.model.trigger?.query == "mai")
    #expect(fixture.model.menuIsLoading)
    await fixture.model.menuSearchTask?.value
    #expect(fixture.model.menuItems.map(\.label) == ["main.ts"])
    #expect(fixture.model.menuItems.first?.itemDescription == "src")
    #expect(fixture.model.menuHighlightedId == fixture.model.menuItems.first?.id)
    fixture.model.pick(fixture.model.menuItems[0])
    #expect(fixture.model.draft.prompt == "look at [main.ts](src/main.ts) ")
    #expect(fixture.model.trigger == nil)
    #expect(fixture.model.editorSync.markdown == "look at [main.ts](src/main.ts) ")
    #expect(fixture.model.editorSync.undoable)
    // The caret follows the chip: "look at " + chip + " ".
    #expect(fixture.model.cursor == 8 + 1 + 1)
  }

  @Test func theMenuStaysClosedUntilTheTriggerChangesAfterEscape() async throws {
    let fixture = try await ModelFixture.make()
    fixture.type("see @s")
    #expect(fixture.model.isMenuOpen)
    #expect(fixture.model.handleCommandKey(.escape, context: ComposerKeyContext(), isTaskItem: false))
    #expect(!fixture.model.isMenuOpen)
    fixture.type("see @sr")
    #expect(!fixture.model.isMenuOpen, "the same trigger stays dismissed while it is edited")
    fixture.type("see @sr and ")
    fixture.type("see @sr and @")
    #expect(fixture.model.isMenuOpen)
  }

  @Test func dollarAndCurrencySymbolsOfferSkillsAndSlashShowsCommands() async throws {
    let fixture = try await ModelFixture.make()
    fixture.type("use $front")
    #expect(fixture.model.trigger?.kind == .skill)
    #expect(fixture.model.menuItems.map(\.label) == ["Frontend Design"])
    fixture.type("use €plug")
    #expect(fixture.model.trigger?.kind == .skill && fixture.model.menuItems.map(\.label) == ["Plugin Skill"])
    fixture.type("/")
    #expect(fixture.model.trigger?.kind == .slashCommand)
    let labels = fixture.model.menuItems.map(\.label)
    #expect(labels.first == "/model")
    #expect(!labels.contains("/plan"), "plan commands need the legacy plan mode setting")
    #expect(labels.contains("/review") && labels.contains("/skill:plugin-skill"))
    #expect(!labels.contains("/compact"), "compact needs a started thread")
  }

  @Test func slashModelOpensThePickerAndCompactNeedsAStartedThread() async throws {
    var started = ComposerThreadSnapshot(phase: .ready)
    started.isFirstMessage = false
    let fixture = try await ModelFixture.make(thread: started)
    await fixture.settle { !fixture.model.thread.isFirstMessage }
    fixture.type("/")
    #expect(fixture.model.menuItems.map(\.label).contains("/compact"))
    fixture.type("/mod")
    fixture.model.pick(fixture.model.menuItems[0])
    #expect(fixture.model.isModelPickerOpen)
    #expect(fixture.model.draft.prompt.isEmpty)
    fixture.type("a /")
    #expect(!fixture.model.menuItems.map(\.label).contains("/compact"))
    #expect(!fixture.model.menuItems.contains { if case .slash(.provider) = $0 { true } else { false } }, "provider commands only expand at the start of a message")
  }

  @Test func planCommandsSwitchTheModeWhenLegacyPlanModeIsOn() async throws {
    let fixture = try await ModelFixture.make(planMode: true)
    fixture.type("/pl")
    #expect(fixture.model.menuItems.first?.label == "/plan")
    fixture.model.pick(fixture.model.menuItems[0])
    #expect(fixture.model.interactionMode == .plan && fixture.model.draft.prompt.isEmpty)
    // Shift+Tab toggles it back.
    #expect(fixture.model.handleCommandKey(.tab, context: ComposerKeyContext(shift: true), isTaskItem: false))
    #expect(fixture.model.interactionMode == .default)
    // Typed in full and sent, the command also switches the mode.
    fixture.type("/plan")
    await fixture.model.submit()
    #expect(fixture.model.interactionMode == .plan && fixture.env.sentTurns.isEmpty)
  }

  @Test func pullRequestMenuFiltersTheRecentListAndResolvesOlderNumbers() async throws {
    let fixture = try await ModelFixture.make()
    func candidate(_ number: Int, _ title: String) -> ComposerPullRequestCandidate {
      ComposerPullRequestCandidate(
        projectId: "project-1", repository: "org/repo", number: number, title: title, url: "https://x/\(number)", state: .open, isDraft: false, headBranch: "h",
        baseBranch: "main", updatedAt: "2026-01-0\(number % 9 + 1)T00:00:00Z")
    }
    fixture.env.pullRequests = [candidate(12, "Fix the thing"), candidate(120, "Another"), candidate(7, "Welcome wizard")]
    fixture.type("see #12")
    await fixture.model.menuSearchTask?.value
    #expect(fixture.model.menuItems.map(\.label) == ["#12", "#120"], "an exact number outranks a substring match")
    fixture.type("see #welcome")
    await fixture.model.menuSearchTask?.value
    #expect(fixture.model.menuItems.map(\.label) == ["#7"])
    fixture.model.pick(fixture.model.menuItems[0])
    #expect(fixture.model.draft.records.count == 1)
    guard case .reviewComment(let record) = fixture.model.draft.records[0] else {
      Issue.record("expected a pull-request record")
      return
    }
    #expect(record.pullRequest?.number == 7)
    #expect(fixture.model.draft.prompt.hasPrefix("see [#7](t3-context://v1/review-comment/"))
    #expect(fixture.model.draft.prompt.hasSuffix(") "))
  }

  @Test func removingAChipDropsItsRecord() async throws {
    let fixture = try await ModelFixture.make()
    let record = ContextRecords.pullRequestReferenceRecord(PullRequestContextMetadata(number: 5, title: "t", url: "u", headBranch: "h", baseBranch: "b", state: .open, isDraft: false))
    fixture.model.insertContext([.reviewComment(record)])
    #expect(fixture.model.draft.records.count == 1)
    #expect(fixture.model.draft.prompt.contains("review-comment"))
    fixture.type("nothing left ")
    #expect(fixture.model.draft.records.isEmpty)
  }
}
