import Foundation
import Testing

@testable import T3Composer

@Suite("Attachment rules oracle") struct AttachmentOracleTests {
  @Test func classification() throws {
    try Oracle.check("attachmentClassify") { input in
      let name = input.string("name")
      let type = input.string("type")
      return [
        "kind": AttachmentRules.classify(name: name, mimeType: type).rawValue, "inferred": AttachmentRules.inferImageMimeType(fromName: name) as Any? ?? NSNull(),
        "heic": AttachmentRules.isHeic(name: name, mimeType: type), "video": AttachmentRules.videoMimeType(name: name, mimeType: type) as Any? ?? NSNull(),
      ]
    }
    try Oracle.check("attachmentPaste") { input in
      let files = (input["files"] as! [[String: Any]]).map { (name: $0.string("name"), mimeType: $0.string("type")) }
      return AttachmentRules.shouldHandlePaste(files: files, plainText: input.string("plainText"))
    }
    try Oracle.check("attachmentReattach") { input in
      let marker = input["marker"] as! [String: Any]
      let file = input["file"] as! [String: Any]
      let attachment = ComposerAttachment(id: "m", kind: .file, name: marker.string("name"), mimeType: marker.string("mimeType"), sizeBytes: marker.int("sizeBytes"))
      return AttachmentRules.matchesReattachMarker(marker: attachment, name: file.string("name"), mimeType: file.string("mimeType"), sizeBytes: file.int("sizeBytes"))
    }
  }

  @Test func limits() throws {
    try Oracle.check("attachmentLimits") { input in
      let raw = input["capabilities"] as! [String: Any]
      let capabilities = AttachmentRules.Capabilities(
        attachmentUploadsCapabilityKnown: raw.bool("attachmentUploadsCapabilityKnown"), supportsAttachmentUploads: raw.bool("supportsAttachmentUploads"),
        maxFileAttachmentBytes: (raw["maxFileAttachmentBytes"] as? NSNumber)?.intValue)
      let files = (input["files"] as! [[String: Any]]).map { (name: $0.string("name"), sizeBytes: $0.int("sizeBytes")) }
      return [
        "staging": AttachmentRules.fileStagingLimit(capabilities) as Any? ?? NSNull(),
        "reason": AttachmentRules.capabilityBlockReason(files: files, capabilities: capabilities) as Any? ?? NSNull(),
      ]
    }
    try Oracle.check("attachmentSize") { AttachmentRules.formatSize($0.int("bytes")) }
    try Oracle.check("attachmentTooLarge") { AttachmentRules.tooLargeMessage(name: $0.string("name"), maxUploadBytes: $0.int("bytes")) }
    try Oracle.check("attachmentClamp") { AttachmentRules.clampUploadBytes($0.int("bytes")) }
    try Oracle.check("attachmentProviderLimit") { input in
      func attachment(_ raw: [String: Any]) -> (kind: ComposerAttachment.Kind, mimeType: String, sizeBytes: Int) {
        (raw.string("type") == "image" ? .image : .file, raw.string("mimeType"), raw.int("sizeBytes"))
      }
      let count = input.int("count")
      var list: [(kind: ComposerAttachment.Kind, mimeType: String, sizeBytes: Int)] = []
      if count > 2, let first = input["first"] as? [String: Any] {
        list = Array(repeating: attachment(first), count: count)
      } else {
        if let first = input["first"] as? [String: Any] { list.append(attachment(first)) }
        if let second = input["second"] as? [String: Any] { list.append(attachment(second)) }
      }
      return AttachmentRules.providerLimitError(list) as Any? ?? NSNull()
    }
  }

  @Test func uploads() throws {
    try Oracle.check("attachmentUploadBlock") { input in
      var uploads: [String: AttachmentRules.UploadState] = [:]
      for (id, raw) in input["uploads"] as! [String: [String: Any]] {
        guard raw.string("environmentId") == "e" else { continue }  // other environments never count as ready
        switch raw.string("status") {
        case "ready": uploads[id] = .ready(attachmentId: raw.string("attachmentId"))
        case "failed": uploads[id] = .failed(reason: raw.string("reason"), attachmentId: nil)
        default: uploads[id] = .uploading(progress: (raw["progress"] as! NSNumber).doubleValue)
        }
      }
      return AttachmentRules.uploadBlockReason(attachmentIds: input["imageIds"] as! [String], uploads: uploads) as Any? ?? NSNull()
    }
    try Oracle.check("attachmentProgress") { input in
      let progress = (input["progress"] as? NSNumber)?.doubleValue ?? .nan
      return AttachmentRules.formatUploadProgress(progress)
    }
  }

  @Test func intakeKeepsSlotsForReattachMarkers() {
    let marker = ComposerAttachment(id: "m1", kind: .file, name: "clip.mp4", mimeType: "", sizeBytes: 9)
    let files = [
      AttachmentRules.IncomingFile(name: "a.png", mimeType: "image/png", sizeBytes: 1), AttachmentRules.IncomingFile(name: "clip.mp4", mimeType: "", sizeBytes: 9),
      AttachmentRules.IncomingFile(name: "x.tiff", mimeType: "image/tiff", sizeBytes: 1), AttachmentRules.IncomingFile(name: "empty.txt", mimeType: "text/plain", sizeBytes: 0),
      AttachmentRules.IncomingFile(name: "big.bin", mimeType: "", sizeBytes: 100),
    ]
    // A full draft refuses new files, but the marker's replacement needs no free slot.
    let full = AttachmentRules.plan(files: files, reservedCount: 100, reattachMarkers: [marker], fileStagingLimit: 50)
    #expect(full.error == "You can attach up to 100 files per message.")
    #expect(full.files.map(\.file.name) == ["clip.mp4"])
    #expect(full.files.first?.mimeType == "video/mp4")
    #expect(full.replacedMarkerIds == ["m1"])
    let open = AttachmentRules.plan(files: files, reservedCount: 0, reattachMarkers: [], fileStagingLimit: 50)
    #expect(open.images.map(\.name) == ["a.png"])
    #expect(open.error == "'big.bin' exceeds the 50 bytes attachment limit.")
    #expect(AttachmentRules.plan(files: [files[3]], reservedCount: 0, reattachMarkers: [], fileStagingLimit: 50).error == "'empty.txt' is empty or could not be read.")
    #expect(AttachmentRules.plan(files: [files[4]], reservedCount: 0, reattachMarkers: [], fileStagingLimit: nil).error == "This server does not support file attachments.")
    #expect(AttachmentRules.plan(files: [files[2]], reservedCount: 0, reattachMarkers: [], fileStagingLimit: 50).error?.hasPrefix("'x.tiff' is not a supported image type.") == true)
  }
}
