import Foundation
import T3ClientRuntime
import T3Composer
import T3Contracts
import T3Diff

/// The composer models that are on screen, by thread key, so another panel can put context into the draft the
/// user is looking at (`ComposerModel.insertContext` edits the live editor, not just the stored draft).
@MainActor
final class LiveComposers {
  static let shared = LiveComposers()
  private struct Box { weak var model: ComposerModel? }
  private var boxes: [String: Box] = [:]

  func register(_ model: ComposerModel, for key: String) { boxes[key] = Box(model: model) }

  func unregister(_ model: ComposerModel, for key: String) {
    if boxes[key]?.model === model { boxes[key] = nil }
  }

  func model(for key: String) -> ComposerModel? { boxes[key]?.model }
}

extension AppModel {
  /// A selected diff range as a `review-comment` chip at the caret of the thread's composer.
  /// Returns false when that composer is not on screen.
  @discardableResult
  func insertReviewComment(_ draft: ReviewCommentDraft, in key: ScopedThreadKey) -> Bool {
    guard let model = LiveComposers.shared.model(for: key.description) else { return false }
    var record = ComposerContextRecordReviewComment(
      contextId: ComposerContextId(ComposerContextReferences.toKindScopedContextId(kind: "review-comment", producerId: draft.id)), label: "",
      sectionId: draft.sectionId, sectionTitle: draft.sectionTitle, filePath: draft.filePath, startIndex: draft.startIndex, endIndex: draft.endIndex,
      rangeLabel: draft.rangeLabel, text: Self.clamp(draft.text, to: 16_000), diff: Self.clamp(draft.diff, to: 32_000), fenceLanguage: draft.fenceLanguage)
    record.label = ComposerContextReferences.sanitizeLabel(ContextRecords.reviewCommentLabel(record), kind: "review-comment")
    return model.insertContext([ComposerContextRecord.reviewComment(record)])
  }

  /// Comments in this thread's draft that belong to `sectionId`, for the markers in the diff gutter.
  func draftReviewComments(in key: ScopedThreadKey, sectionId: String) -> [(filePath: String, startIndex: Int, endIndex: Int)] {
    composer.services.drafts.draft(key.description).records.compactMap { (record: ComposerContextRecord) -> (filePath: String, startIndex: Int, endIndex: Int)? in
      guard case .reviewComment(let comment) = record, comment.sectionId == sectionId, comment.pullRequest == nil else { return nil }
      return (comment.filePath, comment.startIndex, comment.endIndex)
    }
  }

  /// The composer's own limits (`COMPOSER_CONTEXT_REVIEW_*_MAX_CHARS`), cut with the web's marker.
  private static func clamp(_ value: String, to limit: Int) -> String {
    let marker = "\n\u{2026} truncated \u{2026}"
    let units = Array(value.utf16)
    guard units.count > limit else { return value }
    return String(decoding: units.prefix(max(0, limit - marker.utf16.count)), as: UTF16.self) + marker
  }
}
