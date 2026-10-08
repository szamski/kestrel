import Foundation
import T3Contracts
import T3Protocol

public enum AttachmentUploadError: Error, Sendable, Equatable {
  case notConnected
  case rejected(String)
  case uploadFailed(status: Int?)
  case cancelled
}

public struct UploadedAttachment: Sendable, Equatable {
  public enum Kind: Sendable { case image, file }
  public let attachmentId: String
  public let name: String
  public let mimeType: String
  public let sizeBytes: Int
  public let kind: Kind

  /// The attachment as a `thread.turn.start` message attachment.
  public var messageAttachment: ClientOrchestrationCommandThreadTurnStartMessageAttachmentsItem {
    switch kind {
    case .image: .chatImageAttachment(ChatImageAttachment(id: attachmentId, name: name, mimeType: mimeType, sizeBytes: sizeBytes))
    case .file: .chatFileAttachment(ChatFileAttachment(id: attachmentId, name: name, mimeType: mimeType, sizeBytes: sizeBytes))
    }
  }
}

/// Two-step upload (apps/web `attachmentUploadQueue.ts`, minimal): mint a signed upload URL over RPC,
/// then POST the bytes to it. The signed URL is the credential, so no auth header is sent. A
/// cancelled or failed upload deletes the pending upload it minted.
enum AttachmentUploader {
  static let uploadTimeout: TimeInterval = 5 * 60
  static let imageMimeTypes: Set<String> = ["image/gif", "image/jpeg", "image/png", "image/webp"]

  static func upload(
    session: any EnvironmentSession, httpBaseURL: URL, data: Data, name: String, mimeType: String, urlSession: URLSession
  ) async throws(AttachmentUploadError) -> UploadedAttachment {
    let isImage = imageMimeTypes.contains(mimeType)
    let input: AttachmentCreateUploadUrlInput =
      isImage
      ? .image(AttachmentCreateUploadUrlInputImage(name: name, mimeType: AttachmentCreateUploadUrlInputImageMimeType(rawValue: mimeType), sizeBytes: data.count))
      : .file(AttachmentCreateUploadUrlInputFile(name: name, mimeType: mimeType, sizeBytes: data.count))
    let minted: AttachmentCreateUploadUrlResult
    do {
      minted = try await session.call(Rpc.attachmentsCreateUploadUrl, input)
    } catch {
      throw .rejected("\(error)")
    }
    guard let url = URL(string: minted.relativeUrl, relativeTo: httpBaseURL)?.absoluteURL else {
      await delete(session, minted.attachmentId)
      throw .rejected("The server returned an invalid upload URL.")
    }
    var request = URLRequest(url: url, timeoutInterval: uploadTimeout)
    request.httpMethod = "POST"
    request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
    do {
      let (_, response) = try await urlSession.upload(for: request, from: data)
      let status = (response as? HTTPURLResponse)?.statusCode
      guard let status, (200..<300).contains(status) else {
        await delete(session, minted.attachmentId)
        throw AttachmentUploadError.uploadFailed(status: status)
      }
    } catch let error as AttachmentUploadError {
      throw error
    } catch {
      await delete(session, minted.attachmentId)
      throw (error is CancellationError || (error as? URLError)?.code == .cancelled) ? .cancelled : .uploadFailed(status: nil)
    }
    return UploadedAttachment(attachmentId: minted.attachmentId, name: name, mimeType: mimeType, sizeBytes: data.count, kind: isImage ? .image : .file)
  }

  /// Fire-and-forget delete of a pending upload the client no longer references.
  static func delete(_ session: any EnvironmentSession, _ attachmentId: String) async {
    _ = try? await session.call(Rpc.attachmentsDelete, AttachmentDeleteInput(attachmentId: attachmentId))
  }
}
