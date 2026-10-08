import Foundation
import T3Contracts
import Testing

@testable import T3Composer

@Suite("Chip labels, records and pull-request matching oracle") struct ContextOracleTests {
  private func pullRequest(_ any: Any?) -> PullRequestContextMetadata? {
    guard let object = any as? [String: Any] else { return nil }
    let state: VcsStatusRemoteResultPrState = object.string("state") == "merged" ? .merged : object.string("state") == "closed" ? .closed : .open
    return PullRequestContextMetadata(
      number: object.int("number"), title: object.string("title"), url: object.string("url"), headBranch: object.string("headBranch"),
      baseBranch: object.string("baseBranch"), state: state, isDraft: object.bool("isDraft"))
  }

  private func review(_ object: [String: Any]) -> ComposerContextRecordReviewComment {
    ComposerContextRecordReviewComment(
      contextId: "c1", label: "x", sectionId: object.string("sectionId"), sectionTitle: object.string("sectionTitle"), filePath: object.string("filePath"),
      startIndex: object.int("startIndex"), endIndex: object.int("endIndex"), rangeLabel: object.string("rangeLabel"), text: object.string("text"),
      diff: object.string("diff"), fenceLanguage: nil, pullRequest: pullRequest(object["pullRequest"]))
  }

  @Test func labels() throws {
    try Oracle.check("reviewLabels") { input in
      let record = review(input["comment"] as! [String: Any])
      return [
        "label": ContextRecords.reviewCommentLabel(record), "isPullRequest": ContextRecords.isPullRequestSummary(record),
        "state": ContextRecords.pullRequestDisplayState(record)?.rawValue as Any? ?? NSNull(), "kindLabel": ContextRecords.pullRequestKindLabel(record),
      ] as [String: Any]
    }
    try Oracle.check("previewLabel") { input in
      ContextRecords.previewAnnotationLabel(comment: input.string("comment"), pageTitle: input.optionalString("pageTitle"))
    }
    try Oracle.check("terminalLabel") { ContextRecords.terminalLabel(terminalLabel: $0.string("label"), lineStart: $0.int("lineStart"), lineEnd: $0.int("lineEnd")) }
    try Oracle.check("terminalText") { ContextRecords.normalizeTerminalText($0.string("text")) }
  }

  @Test func recordsFromTheComposer() throws {
    try Oracle.check("pullRequestRecord", nullEqualsMissing: true) { input in
      try json(ComposerContext.record(.reviewComment(ContextRecords.pullRequestReferenceRecord(pullRequest(input["metadata"])!))))
    }
    try Oracle.check("attachmentRecord", nullEqualsMissing: true) { input in
      let raw = input["attachment"] as! [String: Any]
      let attachment = ComposerAttachment(
        id: raw.string("id"), kind: raw.string("type") == "image" ? .image : .file, name: raw.string("name"), mimeType: raw.string("mimeType"), sizeBytes: raw.int("sizeBytes"))
      let reference = ContextRecords.attachmentReference(attachment)
      return [
        "record": try json(ContextRecords.attachmentRecord(attachment, attachmentId: input.string("attachmentId"))),
        "reference": ["kind": reference.kind, "contextId": reference.contextId, "label": reference.label],
      ] as [String: Any]
    }
  }

  @Test func messageContextKeepsTheWebOrder() throws {
    func image(_ id: String) -> ComposerAttachment { ComposerAttachment(id: id, kind: .image, name: "\(id).png", mimeType: "image/png", sizeBytes: 1) }
    let terminal = ComposerContextRecord.terminal(TerminalContextRecord(contextId: "terminal_1", label: "T", terminalId: "t", terminalLabel: "T", lineStart: 1, lineEnd: 1, text: "x"))
    let comment = ComposerContextRecord.reviewComment(ContextRecords.pullRequestReferenceRecord(pullRequest(["number": 1, "title": "t", "url": "u", "headBranch": "h", "baseBranch": "b", "state": "open", "isDraft": false])!))
    let preview = ComposerContextRecord.previewAnnotation(
      ComposerContextRecordPreviewAnnotation(contextId: "p", label: "p", annotationId: "a", pageUrl: "u", comment: "c", targetSummary: "", styleChanges: []))
    let context = ContextRecords.messageContext(records: [preview, comment, terminal], attachments: [(image("a1"), "server-a1")])
    #expect(context?.records.map(\.contextKind) == ["terminal", "review-comment", "preview-annotation", "image"])
    #expect(ContextRecords.messageContext(records: [], attachments: []) == nil)
  }

  @Test func pullRequestMenu() throws {
    func candidate(_ object: [String: Any]) -> ComposerPullRequestCandidate {
      ComposerPullRequestCandidate(
        projectId: object.string("projectId"), repository: object.string("repository"), number: object.int("number"), title: object.string("title"), url: object.string("url"),
        state: .open, isDraft: false, headBranch: object.string("headBranch"), baseBranch: object.string("baseBranch"), updatedAt: object.string("updatedAt"),
        authorLogin: (object["author"] as? [String: Any])?.string("login"))
    }
    // The entries the oracle used, rebuilt here (the oracle only records outputs for them).
    func entry(_ n: Int, _ extra: [String: Any] = [:]) -> ComposerPullRequestCandidate {
      var object: [String: Any] = [
        "number": n, "projectId": "p1", "repository": "Org/Repo", "title": "Title \(n)", "url": "https://x/\(n)", "headBranch": "branch-\(n)", "baseBranch": "main",
        "updatedAt": "2026-01-\(String(format: "%02d", 10 + (n % 20)))T00:00:00Z", "author": ["login": n % 2 == 1 ? "alice" : "bob"],
      ]
      for (key, value) in extra { object[key] = value }
      return candidate(object)
    }
    let entries = [
      entry(1), entry(12), entry(123), entry(21), entry(121, ["title": "welcome wizard fix"]), entry(5, ["repository": "other/repo"]), entry(6, ["projectId": "p2"]),
      entry(12, ["title": "dupe"]), entry(31, ["headBranch": "wizard-welcome"]), entry(40, ["author": ["login": "carol"]]),
    ]
    try Oracle.check("pullRequestNumeric") { input in
      PullRequestMatching.filterNumeric(entries, projectId: "p1", repository: " org/repo ", query: input.string("query"), limit: 12).map { "\($0.number):\($0.title)" }
    }
    try Oracle.check("pullRequestRank") { input in
      let query = input.string("query")
      return [
        "ranked": PullRequestMatching.rank(entries, query: query).map { "\($0.number):\($0.title)" },
        "matches": entries.map { PullRequestMatching.matches($0, query: query) },
        "scores": entries.map { PullRequestMatching.score($0, query: query) },
      ] as [String: Any]
    }
  }
}

/// `json(record)` for a single `ComposerContextRecord` case.
enum ComposerContext {
  static func record(_ record: ComposerContextRecord) -> ComposerContextRecord { record }
}
