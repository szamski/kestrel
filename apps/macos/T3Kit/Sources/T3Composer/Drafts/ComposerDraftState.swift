import Foundation
import T3Contracts

/// Everything the composer remembers for one thread (or draft session) between sends.
public struct ComposerThreadDraft: Sendable, Hashable, Codable {
  /// Canonical Markdown: chips are `[label](t3-context://…)` / `[name](path)` / `$skill` links.
  public var prompt = ""
  public var attachments: [ComposerAttachment] = []
  /// Payloads behind chips that are not attachments (terminal excerpts, review comments, preview
  /// annotations, pull requests).
  public var records: [ComposerContextRecord] = []
  /// Per provider instance, so a default `codex` and a custom `codex_personal` each remember
  /// their own model and options.
  public var modelSelectionByProvider: [String: ModelSelection] = [:]
  public var activeProvider: String?
  /// True only when a human picked the active selection; seeded ones may be replaced by later seeds.
  public var modelSelectionExplicit: Bool?
  public var runtimeMode: RuntimeMode?
  public var interactionMode: ProviderInteractionMode?

  public init() {}

  public var images: [ComposerAttachment] { attachments.filter { $0.kind == .image } }
  public var files: [ComposerAttachment] { attachments.filter { $0.kind == .file } }

  /// Typed text or any attachment or context. Model and mode choices alone do not count: they
  /// are ambient defaults, not work in progress.
  public var hasUserContent: Bool {
    !prompt.jsTrim().isEmpty || !attachments.isEmpty || !records.isEmpty
  }

  var isEmpty: Bool {
    prompt.isEmpty && attachments.isEmpty && records.isEmpty && modelSelectionByProvider.isEmpty && activeProvider == nil && runtimeMode == nil
      && interactionMode == nil
  }
}

/// The set of drafts plus the sticky model selection new drafts start from (`composerDraftStore.ts`).
public struct ComposerDraftState: Sendable, Hashable, Codable {
  public static let storageVersion = 1

  public var draftsByKey: [String: ComposerThreadDraft] = [:]
  public var stickyModelSelectionByProvider: [String: ModelSelection] = [:]
  public var stickyActiveProvider: String?

  public init() {}

  public func draft(_ key: String) -> ComposerThreadDraft { draftsByKey[key] ?? ComposerThreadDraft() }

  /// Reads, edits and writes back one draft; an empty draft disappears.
  public mutating func update(_ key: String, _ edit: (inout ComposerThreadDraft) -> Void) {
    guard !key.isEmpty else { return }
    var next = draft(key)
    edit(&next)
    if next.isEmpty { draftsByKey[key] = nil } else { draftsByKey[key] = next }
  }

  public mutating func setPrompt(_ key: String, _ prompt: String) { update(key) { $0.prompt = prompt } }

  // MARK: Model selection

  private static func keepOptions(_ selection: ModelSelection, current: ModelSelection?) -> ModelSelection {
    selection.options != nil ? selection : ModelOptions.makeSelection(instanceId: selection.instanceId.rawValue, model: selection.model, options: current?.options)
  }

  /// The picker pick: marks the selection explicit. A selection without options keeps the options
  /// the instance already had, so a model change preserves traits.
  public mutating func setModelSelection(_ key: String, _ selection: ModelSelection, explicit: Bool = false, replaceOptions: Bool = false) {
    update(key) { draft in
      let id = selection.instanceId.rawValue
      draft.modelSelectionByProvider[id] = (selection.options != nil || replaceOptions) ? selection : Self.keepOptions(selection, current: draft.modelSelectionByProvider[id])
      draft.activeProvider = id
      draft.modelSelectionExplicit = explicit ? true : nil
    }
  }

  /// Remembers the pick for new drafts. Model-only updates keep the last sticky traits.
  public mutating func setStickyModelSelection(_ selection: ModelSelection) {
    let id = selection.instanceId.rawValue
    stickyModelSelectionByProvider[id] = Self.keepOptions(selection, current: stickyModelSelectionByProvider[id])
    stickyActiveProvider = id
  }

  /// A new draft starts from the sticky selection.
  public mutating func applyStickyState(_ key: String) {
    let sticky = stickyModelSelectionByProvider
    let active = stickyActiveProvider
    update(key) { draft in
      draft.modelSelectionByProvider = sticky
      draft.activeProvider = active
      draft.modelSelectionExplicit = nil
    }
  }

  /// Trait edits are user intent: the selection becomes explicit and may persist as sticky. A call
  /// that changes nothing leaves the draft untouched.
  public mutating func setProviderModelOptions(
    _ key: String, instanceId: String, model: String, options: [ProviderOptionSelection]?, persistSticky: Bool = false
  ) {
    let next = options?.isEmpty == false ? options : nil
    let base = draft(key)
    var nextMap = base.modelSelectionByProvider
    let current = nextMap[instanceId]
    if let next {
      nextMap[instanceId] = ModelOptions.makeSelection(instanceId: instanceId, model: current?.model ?? model, options: next)
    } else if let current, current.options?.isEmpty == false {
      nextMap[instanceId] = ModelOptions.makeSelection(instanceId: instanceId, model: current.model, options: nil)
    }
    var nextSticky = stickyModelSelectionByProvider
    var nextStickyActive = stickyActiveProvider
    if persistSticky {
      let stickyBase = nextSticky[instanceId] ?? base.modelSelectionByProvider[instanceId] ?? ModelOptions.makeSelection(instanceId: instanceId, model: model, options: nil)
      if let next {
        nextSticky[instanceId] = ModelOptions.makeSelection(instanceId: instanceId, model: stickyBase.model, options: next)
      } else if stickyBase.options?.isEmpty == false {
        nextSticky[instanceId] = ModelOptions.makeSelection(instanceId: instanceId, model: stickyBase.model, options: nil)
      }
      nextStickyActive = instanceId
    }
    if base.modelSelectionByProvider == nextMap && stickyModelSelectionByProvider == nextSticky && stickyActiveProvider == nextStickyActive { return }
    update(key) { draft in
      draft.activeProvider = instanceId
      draft.modelSelectionByProvider = nextMap
      draft.modelSelectionExplicit = true
    }
    if persistSticky {
      stickyModelSelectionByProvider = nextSticky
      stickyActiveProvider = nextStickyActive
    }
  }

  public mutating func setRuntimeMode(_ key: String, _ mode: RuntimeMode?) { update(key) { $0.runtimeMode = mode } }
  public mutating func setInteractionMode(_ key: String, _ mode: ProviderInteractionMode?) { update(key) { $0.interactionMode = mode } }

  // MARK: Attachments

  /// Adds attachments, skipping duplicates and anything past the per-message cap. A needs-reattach
  /// marker is replaced in place by a matching re-pick and its chip follows to the new id.
  /// Returns the ids the draft actually took.
  @discardableResult
  public mutating func addAttachments(_ key: String, _ incoming: [ComposerAttachment], allowDuplicates: Bool = false) -> [String] {
    guard !incoming.isEmpty else { return [] }
    var accepted: [String] = []
    update(key) { draft in
      var knownIds = Set(draft.attachments.map(\.id))
      var knownKeys = Dictionary(draft.attachments.map { ($0.dedupeKey, $0) }, uniquingKeysWith: { first, _ in first })
      var replacements: [String: ComposerAttachment] = [:]
      var added: [ComposerAttachment] = []
      for attachment in incoming {
        if knownIds.contains(attachment.id) { continue }
        var duplicate: ComposerAttachment?
        if !allowDuplicates {
          duplicate = knownKeys[attachment.dedupeKey]
          if duplicate == nil {
            duplicate = draft.attachments.first {
              $0.kind == .file && $0.needsReattach && attachment.kind == .file && replacements[$0.id] == nil
                && AttachmentRules.matchesReattachMarker(marker: $0, name: attachment.name, mimeType: attachment.mimeType, sizeBytes: attachment.sizeBytes)
            }
          }
        }
        if let duplicate {
          // A needs-reattach marker is not a usable duplicate: replace it so the upload restarts.
          if duplicate.needsReattach, replacements[duplicate.id] == nil {
            replacements[duplicate.id] = attachment
            knownIds.insert(attachment.id)
            knownKeys[attachment.dedupeKey] = attachment
          }
          continue
        }
        if draft.attachments.count + added.count >= ModelConstants.maxAttachments { break }
        added.append(attachment)
        knownIds.insert(attachment.id)
        knownKeys[attachment.dedupeKey] = attachment
      }
      if added.isEmpty && replacements.isEmpty { return }
      accepted = added.map(\.id)
      let retained = draft.attachments.map { replacements[$0.id] ?? $0 }
      if !replacements.isEmpty {
        draft.prompt = ComposerContextReferences.replace(draft.prompt) { occurrence in
          guard let original = draft.attachments.first(where: { ContextRecords.fileReference($0).contextId == occurrence.contextId }),
            let replacement = replacements[original.id]
          else { return occurrence.source }
          return ComposerContextReferences.format(ContextRecords.fileReference(replacement))
        }
      }
      draft.attachments = retained + added
    }
    return accepted
  }

  /// Removes an attachment and every chip that points at it.
  @discardableResult
  public mutating func removeAttachment(_ key: String, id: String) -> ComposerAttachment? {
    var removed: ComposerAttachment?
    update(key) { draft in
      guard let attachment = draft.attachments.first(where: { $0.id == id }) else { return }
      removed = attachment
      draft.attachments.removeAll { $0.id == id }
      draft.prompt = ComposerContextReferences.remove(prompt: draft.prompt, contextId: ContextRecords.attachmentReference(attachment).contextId).prompt
    }
    return removed
  }

  /// Stamps a finished upload onto the file so a reload can verify it instead of re-uploading.
  public mutating func setFileUpload(_ key: String, attachmentId id: String, environmentId: String, uploadedId: String) {
    update(key) { draft in
      guard let index = draft.attachments.firstIndex(where: { $0.id == id && $0.kind == .file }) else { return }
      draft.attachments[index].uploadedAttachmentId = uploadedId
      draft.attachments[index].uploadEnvironmentId = environmentId
    }
  }

  // MARK: Context records

  /// Adds the payload behind a chip (a second chip may point at the same record).
  public mutating func addRecord(_ key: String, _ record: ComposerContextRecord) {
    update(key) { draft in
      draft.records.removeAll { $0.contextIdentifier == record.contextIdentifier }
      draft.records.append(record)
    }
  }

  /// Chip removal drops the records no chip points at; a file whose last chip went is removed.
  public mutating func syncWithPrompt(_ key: String) {
    update(key) { draft in
      let referenced = Set(ComposerContextReferences.collectInlineContextIds(draft.prompt))
      draft.records.removeAll { !referenced.contains($0.contextIdentifier) }
      draft.attachments.removeAll { $0.kind == .file && !referenced.contains(ContextRecords.fileReference($0).contextId) }
    }
  }

  /// Everything the send consumed.
  public mutating func clearContent(_ key: String) {
    update(key) { draft in
      draft.prompt = ""
      draft.attachments = []
      draft.records = []
    }
  }

  // MARK: Persistence

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    struct Envelope: Encodable { var version: Int; var state: ComposerDraftState }
    return try encoder.encode(Envelope(version: Self.storageVersion, state: self))
  }

  /// A stored payload from a newer or unreadable version yields an empty state, never a crash.
  public static func decode(_ data: Data?) -> ComposerDraftState {
    guard let data else { return ComposerDraftState() }
    struct Envelope: Decodable { var version: Int; var state: ComposerDraftState }
    guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == storageVersion else { return ComposerDraftState() }
    return envelope.state
  }
}
