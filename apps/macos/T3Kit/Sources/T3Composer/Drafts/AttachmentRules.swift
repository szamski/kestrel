import Foundation

/// Attachment classification, limits and upload bookkeeping. Ports `composerAttachmentFiles.ts`,
/// `attachmentUploadState.ts`, `imageCompression.ts#isHeicImageFile`, `shared/video.ts`,
/// `shared/image.ts` and the limit helpers of `client-runtime/state/attachments.ts`.
public enum AttachmentRules {
  public enum FileKind: String, Sendable { case image, file, unsupportedImage = "unsupported-image" }

  private static let imageMimeByExtension = ["gif": "image/gif", "jpeg": "image/jpeg", "jpg": "image/jpeg", "png": "image/png", "webp": "image/webp"]
  private static let videoMimeByExtension = [
    "avi": "video/x-msvideo", "m4v": "video/mp4", "mkv": "video/x-matroska", "mov": "video/quicktime", "mp4": "video/mp4", "ogv": "video/ogg", "webm": "video/webm",
  ]
  /// What a picker writes when it did not recognize the file; the name is better evidence.
  public static let genericMimeTypes: Set<String> = ["application/octet-stream", "binary/octet-stream", "application/unknown"]
  private static let heicMime = JSRegex("^image/hei(?:c|f)\\z", caseInsensitive: true)
  private static let heicExtension = JSRegex("\\.(?:heic|heif)\\z", caseInsensitive: true)

  private static func fileExtension(_ name: String) -> String? {
    let index = name.jsLastIndex(of: 0x2E, from: name.jsLength)
    guard index >= 0 else { return nil }
    return name.jsSlice(index + 1).lowercased()
  }

  /// Maps the extension to a provider-supported image type so a plain `photo.jpg` still lands on
  /// the image path; anything unrecognized stays a generic file.
  public static func inferImageMimeType(fromName name: String) -> String? {
    let dot = name.jsLastIndex(of: 0x2E, from: name.jsLength)
    guard dot > 0, let ext = fileExtension(name) else { return nil }
    return imageMimeByExtension[ext]
  }

  private static func inferImageMimeTypeForUnknownFile(name: String, mimeType: String) -> String? {
    let lowered = mimeType.lowercased()
    if lowered != "" && lowered != "application/octet-stream" { return nil }
    return inferImageMimeType(fromName: name)
  }

  /// Recognizes videos even when the file picker omitted their MIME type.
  public static func videoMimeType(name: String, mimeType: String) -> String? {
    let base = (mimeType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "").jsTrim().lowercased()
    if base.hasPrefix("video/") { return base }
    // The name is only evidence when nothing recorded what this is.
    if base != "" && !genericMimeTypes.contains(base) { return nil }
    guard let ext = fileExtension(name) else { return nil }
    return videoMimeByExtension[ext]
  }

  /// Finder and some browsers omit the MIME type when dragging HEIC photos.
  public static func isHeic(name: String, mimeType: String) -> Bool {
    if heicMime.test(mimeType) { return true }
    return (mimeType == "" || mimeType.lowercased() == "application/octet-stream") && heicExtension.test(name)
  }

  public static func classify(name: String, mimeType: String) -> FileKind {
    if isHeic(name: name, mimeType: mimeType) { return .image }
    if inferImageMimeTypeForUnknownFile(name: name, mimeType: mimeType) != nil { return .image }
    if !mimeType.lowercased().hasPrefix("image/") { return .file }
    return ModelConstants.isSupportedImageMimeType(mimeType) ? .image : .unsupportedImage
  }

  /// Whether a paste's files should be claimed as composer attachments instead of falling through
  /// to the default text paste.
  public static func shouldHandlePaste(files: [(name: String, mimeType: String)], plainText: String) -> Bool {
    if files.contains(where: { let kind = classify(name: $0.name, mimeType: $0.mimeType); return kind == .image || kind == .unsupportedImage }) { return true }
    if !plainText.isEmpty { return false }
    return files.contains { classify(name: $0.name, mimeType: $0.mimeType) == .file }
  }

  // MARK: Limits

  public struct Capabilities: Sendable, Hashable {
    public var attachmentUploadsCapabilityKnown: Bool
    public var supportsAttachmentUploads: Bool
    public var maxFileAttachmentBytes: Int?

    public init(attachmentUploadsCapabilityKnown: Bool = true, supportsAttachmentUploads: Bool = true, maxFileAttachmentBytes: Int? = ModelConstants.maxFileBytes) {
      self.attachmentUploadsCapabilityKnown = attachmentUploadsCapabilityKnown
      self.supportsAttachmentUploads = supportsAttachmentUploads
      self.maxFileAttachmentBytes = maxFileAttachmentBytes
    }
  }

  public static func clampUploadBytes(_ advertised: Int) -> Int { min(advertised, ModelConstants.maxFileBytes) }

  /// Byte limit for adding a generic file to the draft; nil when the server takes no files.
  public static func fileStagingLimit(_ capabilities: Capabilities) -> Int? {
    if !capabilities.attachmentUploadsCapabilityKnown { return ModelConstants.maxFileBytes }
    guard capabilities.supportsAttachmentUploads, let max = capabilities.maxFileAttachmentBytes else { return nil }
    return clampUploadBytes(max)
  }

  public static func formatSize(_ sizeBytes: Int) -> String {
    if sizeBytes >= 1024 * 1024 {
      // `toFixed(1)`: the quotient is exact (a power-of-two divisor), and a tie rounds up.
      let tenths = Int((Double(sizeBytes) * 10 / 1_048_576).rounded(.toNearestOrAwayFromZero))
      return "\(tenths / 10).\(tenths % 10) MB"
    }
    return "\(max(1, Int((Double(sizeBytes) / 1024).rounded(.up)))) KB"
  }

  public static func tooLargeMessage(name: String, maxUploadBytes: Int) -> String {
    let size: String
    if maxUploadBytes >= 1024 * 1024 && maxUploadBytes % (1024 * 1024) == 0 {
      size = "\(maxUploadBytes / (1024 * 1024)) MB"
    } else if maxUploadBytes >= 1024 && maxUploadBytes % 1024 == 0 {
      size = "\(maxUploadBytes / 1024) KB"
    } else {
      size = "\(maxUploadBytes) \(maxUploadBytes == 1 ? "byte" : "bytes")"
    }
    return "'\(name)' exceeds the \(size) attachment limit."
  }

  /// Why retained generic files cannot send with the current server config.
  public static func capabilityBlockReason(files: [(name: String, sizeBytes: Int)], capabilities: Capabilities) -> String? {
    if files.isEmpty { return nil }
    if !capabilities.attachmentUploadsCapabilityKnown { return "Waiting for the server before file attachments can send" }
    guard let limit = fileStagingLimit(capabilities) else { return "This server does not accept file attachments right now. Remove the files to send." }
    if let oversized = files.first(where: { $0.sizeBytes > limit }) { return tooLargeMessage(name: oversized.name, maxUploadBytes: limit) }
    return nil
  }

  /// Per-message limits shared by the composer and question answers.
  public static func providerLimitError(_ attachments: [(kind: ComposerAttachment.Kind, mimeType: String, sizeBytes: Int)]) -> String? {
    if attachments.count > ModelConstants.maxAttachments {
      return "You can attach up to \(ModelConstants.maxAttachments) files per message or question response."
    }
    let imageBytes = attachments.reduce(0) { total, attachment in
      total + (attachment.kind == .image || ModelConstants.isSupportedImageMimeType(attachment.mimeType) ? attachment.sizeBytes : 0)
    }
    if imageBytes > ModelConstants.maxTotalImageBytes {
      return "Images can total up to 80 MiB per message or question response. Use smaller images or send fewer at once."
    }
    return nil
  }

  // MARK: Reattach markers and intake

  public static func matchesReattachMarker(marker: ComposerAttachment, name: String, mimeType: String, sizeBytes: Int) -> Bool {
    if marker.name != name || marker.sizeBytes != sizeBytes { return false }
    if marker.mimeType == mimeType { return true }
    let markerMime = marker.mimeType.lowercased()
    return (markerMime == "" || markerMime == "application/octet-stream") && videoMimeType(name: marker.name, mimeType: marker.mimeType) != nil
      && videoMimeType(name: name, mimeType: mimeType) != nil
  }

  public struct IncomingFile: Sendable, Hashable {
    public var name: String
    public var mimeType: String
    public var sizeBytes: Int
    public var url: URL?

    public init(name: String, mimeType: String, sizeBytes: Int, url: URL? = nil) {
      self.name = name
      self.mimeType = mimeType
      self.sizeBytes = sizeBytes
      self.url = url
    }
  }

  public struct IntakePlan: Sendable, Hashable {
    public var images: [IncomingFile] = []
    public var files: [(file: IncomingFile, mimeType: String)] = []
    public var replacedMarkerIds: Set<String> = []
    public var error: String?

    public static func == (lhs: IntakePlan, rhs: IntakePlan) -> Bool {
      lhs.images == rhs.images && lhs.files.map(\.file) == rhs.files.map(\.file) && lhs.files.map(\.mimeType) == rhs.files.map(\.mimeType)
        && lhs.replacedMarkerIds == rhs.replacedMarkerIds && lhs.error == rhs.error
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(images)
      hasher.combine(files.map(\.file))
      hasher.combine(replacedMarkerIds)
      hasher.combine(error)
    }
  }

  /// Synchronous validation of a batch (paste, drop, picker): accepted files reserve their slots
  /// before any await, so concurrent pastes see each other and the total stays under the limit.
  public static func plan(
    files: [IncomingFile], reservedCount: Int, reattachMarkers: [ComposerAttachment], fileStagingLimit: Int?
  ) -> IntakePlan {
    var plan = IntakePlan()
    var reserved = reservedCount
    for file in files {
      let kind = classify(name: file.name, mimeType: file.mimeType)
      let fileMime = kind == .file ? (videoMimeType(name: file.name, mimeType: file.mimeType) ?? (file.mimeType.isEmpty ? "application/octet-stream" : file.mimeType)) : file.mimeType
      var marker: ComposerAttachment?
      if kind == .file {
        marker = reattachMarkers.first {
          !plan.replacedMarkerIds.contains($0.id) && matchesReattachMarker(marker: $0, name: file.name.isEmpty ? "file" : file.name, mimeType: fileMime, sizeBytes: file.sizeBytes)
        }
      }
      if let marker { plan.replacedMarkerIds.insert(marker.id) }
      if marker == nil && reserved >= ModelConstants.maxAttachments {
        plan.error = "You can attach up to \(ModelConstants.maxAttachments) files per message."
        // Keep scanning: a later file can still replace a needs-reattach marker without a free slot.
        continue
      }
      if kind == .unsupportedImage {
        plan.error = "'\(file.name)' is not a supported image type. Attach GIF, HEIC, HEIF, JPEG, PNG, or WebP images."
        continue
      }
      if kind == .image {
        plan.images.append(file)
      } else {
        guard let limit = fileStagingLimit else {
          plan.error = "This server does not support file attachments."
          continue
        }
        if file.sizeBytes <= 0 {
          plan.error = "'\(file.name)' is empty or could not be read."
          continue
        }
        if file.sizeBytes > limit {
          plan.error = tooLargeMessage(name: file.name, maxUploadBytes: limit)
          continue
        }
        plan.files.append((file, fileMime))
      }
      if marker == nil { reserved += 1 }
    }
    return plan
  }

  // MARK: Upload state

  public enum UploadState: Sendable, Hashable {
    case uploading(progress: Double)
    case ready(attachmentId: String)
    case failed(reason: String, attachmentId: String?)
  }

  /// Why the draft cannot send yet because of its uploads.
  public static func uploadBlockReason(attachmentIds: [String], uploads: [String: UploadState]) -> String? {
    var pending = 0
    var failed = 0
    for id in attachmentIds {
      switch uploads[id] {
      case .failed?: failed += 1
      case .ready?: break
      default: pending += 1
      }
    }
    if failed > 0 { return failed == 1 ? "Retry or remove the failed attachment" : "Retry or remove the failed attachments" }
    if pending > 0 { return pending == 1 ? "Attachment still uploading" : "Attachments still uploading" }
    return nil
  }

  public static func formatUploadProgress(_ progress: Double) -> String {
    let bounded = max(0, min(1, progress.isFinite ? progress : 0))
    return "\(Int((bounded * 100).rounded(.down)))%"
  }
}
