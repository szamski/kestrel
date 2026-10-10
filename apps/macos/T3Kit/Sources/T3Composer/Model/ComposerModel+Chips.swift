import Foundation
import T3Contracts

extension ComposerModel {
  /// How each chip in the editor looks, from the draft's attachments, uploads and context records.
  /// Chips whose record is gone render as the dashed "unresolved" form, like the web's `UnresolvedChip`.
  public func makeChipPresentationProvider() -> ChipPresentationProvider {
    var byContextId: [String: ChipPresentation] = [:]
    let uploads = services.uploads
    for attachment in activeAttachments {
      let reference = ContextRecords.attachmentReference(attachment)
      byContextId[reference.contextId] = Self.presentation(for: attachment, upload: uploads[attachment.id])
    }
    for record in draft.records { byContextId[record.contextIdentifier] = Self.presentation(for: record) }
    let skills = Dictionary(selectedProviderSkills.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    return { atom in
      switch atom {
      case .mention(let path, _):
        let isFolder = path.hasSuffix("/")
        let name = String(path.split(separator: "/").last ?? "")
        return ChipPresentation(kind: .mention, symbol: isFolder ? "folder" : "doc.text", label: name.isEmpty ? path : name, accessibilityLabel: "\(isFolder ? "Folder" : "File") mention, \(path)", tooltip: path)
      case .skill(let name, let label, let description):
        let meta = skills[name]
        return ChipPresentation(kind: .skill, symbol: "sparkles", label: label, accessibilityLabel: "Skill, \(label)", tooltip: description ?? meta?.description)
      case .citation(let citation, _):
        let quote = citation.text.jsTrim().jsCollapsingWhitespace()
        let label = quote.jsLength > 40 ? quote.jsSlice(0, 39) + "…" : quote
        return ChipPresentation(
          kind: .citation, symbol: "quote.opening", label: label.isEmpty ? "Assistant quote" : label, accessibilityLabel: "Assistant quote, \(label)",
          tooltip: citation.comment.map { "\(citation.text)\n\n\($0)" } ?? citation.text, editableComment: true)
      case .contextReference(let kind, let contextId, let label, _):
        if let found = byContextId[contextId] { return found }
        return ChipPresentation(
          kind: Self.chipKind(forContext: kind), symbol: "exclamationmark.triangle", label: label, accessibilityLabel: "Unavailable context, \(label)",
          tooltip: "This context is no longer available. Remove it or attach it again.", isUnresolved: true)
      }
    }
  }

  /// Label and description of a `$skill` chip from the selected provider's skills.
  public var skillMeta: (String) -> SkillMeta {
    let skills = Dictionary(selectedProviderSkills.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    return { name in
      guard let skill = skills[name] else { return SkillMeta(label: name) }
      return SkillMeta(label: ProviderSkills.displayName(skill), description: skill.description)
    }
  }

  /// Attachments whose chips the editor shows: the active question's own, or the thread's.
  var activeAttachments: [ComposerAttachment] { draft.attachments + questionAttachments }

  static func chipKind(forContext kind: String) -> ChipPresentation.Kind {
    switch kind {
    case "image": .image
    case "file": .file
    case "terminal": .terminal
    case "element": .element
    case "preview-annotation": .previewAnnotation
    case "review-comment": .reviewComment
    default: .neutral
    }
  }

  static func presentation(for attachment: ComposerAttachment, upload: AttachmentRules.UploadState?) -> ChipPresentation {
    let size = AttachmentRules.formatSize(attachment.sizeBytes)
    var suffix: String?
    var failure: String?
    var isError = false
    switch upload {
    case .uploading(let progress)?: suffix = AttachmentRules.formatUploadProgress(progress)
    case .failed(let reason, _)?:
      suffix = "upload failed"
      failure = reason
      isError = true
    default: break
    }
    let needsReattach = attachment.needsReattach
    if needsReattach { suffix = "attach again" }
    var tooltip = [attachment.name, size].joined(separator: "\n")
    if let failure { tooltip += "\n\n\(failure)" }
    if needsReattach { tooltip = "\(attachment.name) was not saved with this draft. Attach it again to send it." }
    if attachment.kind == .image {
      return ChipPresentation(kind: .image, symbol: "photo", label: attachment.name, suffix: suffix, accessibilityLabel: "Image attachment, \(attachment.name), \(size)", tooltip: tooltip, isError: isError)
    }
    return ChipPresentation(
      kind: attachment.isVideo ? .video : .file, symbol: attachment.isVideo ? "play.rectangle" : "doc", label: attachment.name, suffix: suffix,
      accessibilityLabel: "\(attachment.isVideo && !needsReattach ? "Preview video" : "File") attachment, \(attachment.name), \(size)", tooltip: tooltip, isUnresolved: needsReattach, isError: isError)
  }

  static func presentation(for record: ComposerContextRecord) -> ChipPresentation {
    switch record {
    case .terminal(let value):
      return ChipPresentation(kind: .terminal, symbol: "terminal", label: value.label, accessibilityLabel: "Terminal context, \(value.label)", tooltip: ContextRecords.normalizeTerminalText(value.text))
    case .reviewComment(let value):
      if let state = ContextRecords.pullRequestDisplayState(value) {
        let kind: ChipPresentation.Kind = switch state {
        case .open: .prOpen
        case .draft: .prDraft
        case .merged: .prMerged
        case .closed: .prClosed
        }
        let metadata = value.pullRequest
        return ChipPresentation(
          kind: kind, symbol: "arrow.triangle.pull", label: value.label, accessibilityLabel: "\(ContextRecords.pullRequestKindLabel(value)), \(value.label)",
          tooltip: metadata.map { "#\($0.number) \($0.title)\n\($0.headBranch) → \($0.baseBranch)" })
      }
      return ChipPresentation(
        kind: .reviewComment, symbol: "text.bubble", label: value.label, accessibilityLabel: "Review comment, \(value.label)",
        tooltip: "\(value.filePath)\n\(value.sectionTitle) · \(value.rangeLabel)\(value.text.jsTrim().isEmpty ? "" : "\n\n" + value.text.jsTrim())")
    case .previewAnnotation(let value):
      var lines = [value.pageTitle?.jsTrim().isEmpty == false ? value.pageTitle! : value.pageUrl]
      if !value.comment.jsTrim().isEmpty { lines += ["", value.comment.jsTrim()] }
      if !value.targetSummary.isEmpty { lines += ["", value.targetSummary] }
      return ChipPresentation(kind: .previewAnnotation, symbol: "cursorarrow.click", label: value.label, accessibilityLabel: "Preview annotation, \(value.label)", tooltip: lines.joined(separator: "\n"))
    case .element(let value):
      return ChipPresentation(kind: .element, symbol: "cursorarrow.click", label: value.label, accessibilityLabel: "Page element, \(value.label)")
    case .image(let value):
      return ChipPresentation(kind: .image, symbol: "photo", label: value.label, accessibilityLabel: "Image attachment, \(value.label)")
    case .file(let value):
      return ChipPresentation(kind: .file, symbol: "doc", label: value.label, accessibilityLabel: "File attachment, \(value.label)")
    case .mention(let value):
      return ChipPresentation(kind: .mention, symbol: "doc.text", label: value.label)
    case .skill(let value):
      return ChipPresentation(kind: .skill, symbol: "sparkles", label: value.label)
    case .thread(let value):
      return ChipPresentation(kind: .neutral, symbol: "bubble.left", label: value.label, tooltip: value.title)
    case .other(let value):
      return ChipPresentation(kind: .neutral, symbol: "doc", label: value.label)
    case .unknown(let value):
      return ChipPresentation(kind: .neutral, symbol: "doc", label: value["label"]?.stringValue ?? "Context", isUnresolved: true)
    }
  }
}
