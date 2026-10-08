import AppKit
import SwiftUI

/// Image thumbnails above the editor: progress while uploading, retry on failure, remove.
struct ComposerAttachmentShelf: View {
  let model: ComposerModel
  @State private var confirmRemoval: ComposerAttachment?

  var body: some View {
    let images = model.attachments.filter { $0.kind == .image }
    if !images.isEmpty {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(images) { image in
            AttachmentThumbnail(
              attachment: image, state: model.uploads[image.id],
              remove: { if model.imageIsReferenced(image.id) { confirmRemoval = image } else { model.removeAttachment(id: image.id) } },
              retry: { model.retryUpload(id: image.id) })
          }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Attached images")
      .confirmationDialog("Remove this image?", isPresented: Binding(get: { confirmRemoval != nil }, set: { if !$0 { confirmRemoval = nil } }), presenting: confirmRemoval) { image in
        Button("Remove image", role: .destructive) { model.removeAttachment(id: image.id) }
      } message: { image in
        Text("\(image.name) is still mentioned in your message.")
      }
    }
  }
}

private struct AttachmentThumbnail: View {
  let attachment: ComposerAttachment
  let state: AttachmentRules.UploadState?
  let remove: () -> Void
  let retry: () -> Void
  @State private var image: NSImage?

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06))
      if let image {
        Image(nsImage: image).resizable().scaledToFill()
      } else {
        Image(systemName: "photo").foregroundStyle(.secondary)
      }
      switch state {
      case .uploading(let progress)?:
        Color.black.opacity(0.35)
        ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small).tint(.white)
      case .failed?:
        Color.red.opacity(0.35)
        Button(action: retry) { Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white) }
          .buttonStyle(.plain)
          .accessibilityLabel("Retry upload of \(attachment.name)")
      default: EmptyView()
      }
    }
    .frame(width: 56, height: 56)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    .overlay(alignment: .topTrailing) {
      Button(action: remove) {
        Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, Color.black.opacity(0.65)).font(.system(size: 15))
      }
      .buttonStyle(.plain)
      .offset(x: 5, y: -5)
      .accessibilityLabel("Remove \(attachment.name)")
    }
    .help(attachment.name)
    .task(id: attachment.id) { image = await Self.load(attachment) }
  }

  private static func load(_ attachment: ComposerAttachment) async -> NSImage? {
    let path = attachment.localPath
    let dataURL = attachment.dataURL
    let data: Data? = await Task.detached(priority: .utility) {
      let raw = path.flatMap { FileManager.default.contents(atPath: $0) } ?? dataURL.flatMap { ImageCompression.data(fromDataURL: $0) }
      return raw.flatMap { ImageCompression.thumbnail(of: $0, side: 112) }
    }.value
    return data.flatMap { NSImage(data: $0) }
  }
}

/// Messages waiting for the running turn: they go out at the next tool boundary or when the turn ends.
struct ComposerQueueList: View {
  let model: ComposerModel

  var body: some View {
    let queued = model.queuedMessages
    if !queued.isEmpty {
      VStack(spacing: 0) {
        ForEach(Array(queued.enumerated()), id: \.element.id) { index, message in
          if index > 0 { Divider().opacity(0.5) }
          QueuedRow(model: model, message: message)
        }
      }
      .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ComposerTheme.raised))
      .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ComposerTheme.stroke))
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Queued messages")
    }
  }
}

private struct QueuedRow: View {
  let model: ComposerModel
  let message: QueuedComposerMessage

  private var summary: String {
    let line = message.prompt.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
    let plain = line.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
    if !plain.isEmpty { return plain }
    return message.attachments.first?.name ?? "Attachment"
  }

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: message.holdUntilUserAction ? "pause.circle" : "clock").foregroundStyle(.secondary).font(.system(size: 12))
      Text(summary).lineLimit(1).truncationMode(.tail).font(.system(size: 12.5))
      if !message.attachments.isEmpty {
        Label("\(message.attachments.count)", systemImage: "paperclip").labelStyle(.titleAndIcon).font(.system(size: 11)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      if message.sending != nil {
        ProgressView().controlSize(.small)
      } else {
        Button { model.steerQueued(id: message.id) } label: { Image(systemName: "arrow.turn.down.right") }
          .help("Send now").accessibilityLabel("Send now")
        Button { model.editQueued(id: message.id) } label: { Image(systemName: "pencil") }
          .help("Edit").accessibilityLabel("Edit queued message")
        Button { model.discardQueued(id: message.id) } label: { Image(systemName: "trash") }
          .help("Remove").accessibilityLabel("Remove queued message")
      }
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Queued: \(summary)")
  }
}

/// Failures and warnings the composer raised, until dismissed.
struct ComposerNoticeList: View {
  let model: ComposerModel

  var body: some View {
    ForEach(model.services.notices) { notice in
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: notice.kind == .error ? "exclamationmark.octagon.fill" : notice.kind == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
          .foregroundStyle(notice.kind == .error ? Color.red : notice.kind == .warning ? Color.orange : Color.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(notice.title).font(.system(size: 12, weight: .semibold))
          if let message = notice.message { Text(message).font(.system(size: 12)).foregroundStyle(.secondary) }
        }
        Spacer(minLength: 0)
        Button { model.services.dismissNotice(notice.id) } label: { Image(systemName: "xmark") }
          .buttonStyle(.borderless).accessibilityLabel("Dismiss")
      }
      .padding(10)
      .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ComposerTheme.raised))
      .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ComposerTheme.stroke))
      .accessibilityElement(children: .combine)
    }
  }
}

enum ComposerTheme {
  static let raised = Color(nsColor: .controlBackgroundColor)
  static let stroke = Color.primary.opacity(0.12)
  static let corner: CGFloat = 20
}
