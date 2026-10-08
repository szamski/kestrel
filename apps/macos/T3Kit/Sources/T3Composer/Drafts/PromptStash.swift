import Foundation
import T3Contracts

/// An image persisted with a draft or stash entry (web keeps it as a data URL within a budget).
public struct PersistedImageAttachment: Sendable, Hashable, Codable {
  public var id: String
  public var name: String
  public var mimeType: String
  public var sizeBytes: Int
  public var source: String?
  public var dataUrl: String

  public init(id: String, name: String, mimeType: String, sizeBytes: Int, source: String? = nil, dataUrl: String) {
    self.id = id
    self.name = name
    self.mimeType = mimeType
    self.sizeBytes = sizeBytes
    self.source = source
    self.dataUrl = dataUrl
  }
}

/// A file persisted by reference: its bytes live on the environment that received the upload.
public struct PersistedFileAttachment: Sendable, Hashable, Codable {
  public var id: String
  public var name: String
  public var mimeType: String
  public var sizeBytes: Int
  public var attachmentId: String?
  public var environmentId: String?
  public var source: String?

  public init(id: String, name: String, mimeType: String, sizeBytes: Int, attachmentId: String? = nil, environmentId: String? = nil, source: String? = nil) {
    self.id = id
    self.name = name
    self.mimeType = mimeType
    self.sizeBytes = sizeBytes
    self.attachmentId = attachmentId
    self.environmentId = environmentId
    self.source = source
  }
}

public struct PromptStashEntry: Sendable, Hashable, Identifiable, Codable {
  public var id: String
  public var createdAt: String
  public var prompt: String
  public var attachments: [PersistedImageAttachment]
  public var files: [PersistedFileAttachment]?
  /// Names of images that exceeded the attachment budget and were not saved.
  public var droppedImageNames: [String]
  /// Names of images that could not be decoded or re-encoded at all.
  public var unreadableImageNames: [String]?
  /// Images still being encoded when the entry was written; the entry is persisted before its
  /// images so a crash mid-encode cannot lose the prompt.
  public var pendingImageCount: Int?
  /// Payloads behind the prompt's context links.
  public var records: [ComposerContextRecord]?

  public init(
    id: String, createdAt: String, prompt: String, attachments: [PersistedImageAttachment] = [], files: [PersistedFileAttachment]? = nil,
    droppedImageNames: [String] = [], unreadableImageNames: [String]? = nil, pendingImageCount: Int? = nil, records: [ComposerContextRecord]? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.prompt = prompt
    self.attachments = attachments
    self.files = files
    self.droppedImageNames = droppedImageNames
    self.unreadableImageNames = unreadableImageNames
    self.pendingImageCount = pendingImageCount
    self.records = records
  }
}

/// The prompt stash (`promptStashStore.ts`): up to 20 prompts with their attachments, newest first.
public struct PromptStash: Sendable {
  public static let maxEntries = 20
  /// Budget for an entry's serialized image payload, sized for two images at the per-image
  /// compression budget.
  public static let maxEntryAttachmentChars = 2_700_000
  public static let maxImageDataURLChars = 1_300_000

  public private(set) var entries: [PromptStashEntry]

  public init(entries: [PromptStashEntry] = []) {
    self.entries = Self.clearOrphanedPendingImages(entries)
  }

  /// `pendingImageCount` only has meaning within the session that wrote it: an entry that comes
  /// back from storage still pending was orphaned by a closed app or a crash mid-encode, and the
  /// images are genuinely gone.
  static func clearOrphanedPendingImages(_ entries: [PromptStashEntry]) -> [PromptStashEntry] {
    entries.map { entry in
      guard let lost = entry.pendingImageCount, lost > 0 else { return entry }
      var next = entry
      next.pendingImageCount = 0
      next.unreadableImageNames = (entry.unreadableImageNames ?? []) + (0..<lost).map { "image \($0 + 1) (not saved before reload)" }
      return next
    }
  }

  /// Splits candidate images into a persistable set within the entry budget plus the names of any
  /// that had to be dropped; earlier images win.
  public static func partition(_ attachments: [PersistedImageAttachment]) -> (kept: [PersistedImageAttachment], droppedNames: [String]) {
    var kept: [PersistedImageAttachment] = []
    var dropped: [String] = []
    var used = 0
    for attachment in attachments {
      let length = attachment.dataUrl.jsLength
      if used + length > maxEntryAttachmentChars {
        dropped.append(attachment.name)
        continue
      }
      used += length
      kept.append(attachment)
    }
    return (kept, dropped)
  }

  /// Prepends an entry, evicting the oldest past the cap. Returns the evicted entry.
  public mutating func stash(_ entry: PromptStashEntry) -> PromptStashEntry? {
    var next = [entry] + entries
    let evicted = next.count > Self.maxEntries ? next.popLast() : nil
    entries = next
    return evicted
  }

  /// Removes and returns an entry (restore + delete).
  public mutating func take(_ id: String) -> PromptStashEntry? {
    guard let entry = entries.first(where: { $0.id == id }) else { return nil }
    entries.removeAll { $0.id == id }
    return entry
  }

  /// Attaches encoded images to an entry written earlier, clearing its pending count. False when
  /// the entry is gone (restored or deleted while encoding was still running).
  public mutating func finalizeImages(
    _ id: String, attachments: [PersistedImageAttachment], droppedImageNames: [String], unreadableImageNames: [String]
  ) -> Bool {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
    entries[index].attachments = attachments
    entries[index].droppedImageNames = droppedImageNames
    entries[index].unreadableImageNames = unreadableImageNames
    entries[index].pendingImageCount = 0
    return true
  }
}
