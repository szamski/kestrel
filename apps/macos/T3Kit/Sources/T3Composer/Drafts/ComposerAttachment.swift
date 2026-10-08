import Foundation
import T3Contracts

/// An attachment in a draft: an image on the thumbnail shelf or a file that exists only as chips.
public struct ComposerAttachment: Sendable, Hashable, Identifiable, Codable {
  public enum Kind: String, Sendable, Codable { case image, file }

  public var id: String
  public var kind: Kind
  public var name: String
  public var mimeType: String
  public var sizeBytes: Int
  /// Where the attachment came from (screenshot, pasted text) so the server can label it.
  public var source: String?
  /// Staged bytes inside the app's attachment cache; nil once only the server copy is left.
  public var localPath: String?
  /// Base64 payload of an image kept in the draft (web stores images this way, within a budget).
  public var dataURL: String?
  /// The server-side upload backing a file, with the environment that owns it.
  public var uploadedAttachmentId: String?
  public var uploadEnvironmentId: String?

  public init(
    id: String, kind: Kind, name: String, mimeType: String, sizeBytes: Int, source: String? = nil, localPath: String? = nil,
    dataURL: String? = nil, uploadedAttachmentId: String? = nil, uploadEnvironmentId: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.mimeType = mimeType
    self.sizeBytes = sizeBytes
    self.source = source
    self.localPath = localPath
    self.dataURL = dataURL
    self.uploadedAttachmentId = uploadedAttachmentId
    self.uploadEnvironmentId = uploadEnvironmentId
  }

  /// A file whose bytes are gone locally and whose server upload has to be re-verified.
  public var needsReattach: Bool { kind == .file && localPath == nil && uploadedAttachmentId == nil }

  public var isVideo: Bool { mimeType.lowercased().hasPrefix("video/") }

  /// Identity used to drop a second copy of the same picture or file.
  public var dedupeKey: String { "\(mimeType)\u{0}\(sizeBytes)\u{0}\(name)" }
}

/// Where a message is headed: the thread (or draft session) the composer belongs to.
public struct ComposerTarget: Sendable, Hashable {
  /// Stable key for drafts, queues and history (`scopedThreadKey` for real threads).
  public var key: String
  public var environmentId: String
  public var threadId: String
  public var projectId: String?
  /// Working directory for `@` path search.
  public var cwd: String?
  /// The project's repository (`owner/name`) for `#` pull requests.
  public var repository: String?
  public var isDraftThread: Bool
  /// Folders can only be dropped into the environment running on this machine.
  public var isLocalEnvironment: Bool

  public init(
    key: String, environmentId: String, threadId: String, projectId: String? = nil, cwd: String? = nil, repository: String? = nil, isDraftThread: Bool = false,
    isLocalEnvironment: Bool = true
  ) {
    self.key = key
    self.environmentId = environmentId
    self.threadId = threadId
    self.projectId = projectId
    self.cwd = cwd
    self.repository = repository
    self.isDraftThread = isDraftThread
    self.isLocalEnvironment = isLocalEnvironment
  }
}
