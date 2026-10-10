import AppKit
import SwiftUI
import T3Contracts

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
    if let queue = model.serverQueue {
      ServerQueueList(model: model, queue: queue)
    } else {
      localQueue
    }
  }

  @ViewBuilder private var localQueue: some View {
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

/// The server's queue of a protocol-2 thread: messages waiting behind the active run. Rows reorder by drag (when the
/// provider supports queued messages), edit in the composer, steer into the run or leave the queue.
private struct ServerQueueList: View {
  let model: ComposerModel
  let queue: ComposerServerQueue

  var body: some View {
    if !queue.items.isEmpty {
      VStack(spacing: 0) {
        if queue.isHeld {
          HStack(spacing: 8) {
            Image(systemName: "pause.circle").foregroundStyle(.secondary).font(.system(size: 12))
            Text("Queue paused").font(.system(size: 12.5))
            Spacer(minLength: 8)
            Button("Resume") { model.resumeServerQueue() }.controlSize(.small).disabled(model.busyQueueRunId != nil)
          }
          .padding(.horizontal, 12).padding(.vertical, 7)
          Divider().opacity(0.5)
        }
        ForEach(Array(queue.items.enumerated()), id: \.element.id) { index, item in
          if index > 0 { Divider().opacity(0.5) }
          ServerQueueRow(model: model, queue: queue, item: item, index: index)
        }
      }
      .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ComposerTheme.raised))
      .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ComposerTheme.stroke))
      .accessibilityElement(children: .contain)
      .accessibilityLabel("\(queue.items.count) queued message\(queue.items.count == 1 ? "" : "s")")
    }
  }
}

private struct ServerQueueRow: View {
  let model: ComposerModel
  let queue: ComposerServerQueue
  let item: ComposerServerQueue.Item
  let index: Int
  @State private var isDropTarget = false

  private var summary: String {
    let line = item.text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
    let plain = line.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
    if !plain.isEmpty { return plain }
    switch item.attachments.first {
    case .image(let image)?: return image.name
    case .file(let file)?: return file.name
    default: return "Attachment"
    }
  }

  private var isEditing: Bool { model.editingQueued?.runId == item.runId }
  private var isBusy: Bool { model.busyQueueRunId != nil }

  var body: some View {
    HStack(spacing: 8) {
      if queue.canReorder {
        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).font(.system(size: 11)).help("Drag to reorder")
      } else {
        Image(systemName: queue.isHeld ? "pause.circle" : "clock").foregroundStyle(.secondary).font(.system(size: 12))
      }
      Text(summary).lineLimit(1).truncationMode(.tail).font(.system(size: 12.5)).foregroundStyle(.primary.opacity(0.8))
      if !item.attachments.isEmpty {
        Label("\(item.attachments.count)", systemImage: "paperclip").labelStyle(.titleAndIcon).font(.system(size: 11)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      if isEditing {
        Button("Cancel") { model.cancelQueuedEdit() }.controlSize(.small).accessibilityLabel("Cancel editing queued message")
      } else {
        Button { model.editServerQueued(item.runId) } label: { Image(systemName: "pencil") }
          .help("Edit in the composer").accessibilityLabel("Edit queued message").disabled(isBusy)
        Button { model.steerServerQueued(item.runId) } label: { Label("Steer", systemImage: "arrow.turn.down.right").labelStyle(.titleAndIcon) }
          .help(queue.activeRunId == nil ? "There is no active run to steer" : "Send as a steer instead")
          .accessibilityLabel("Steer").disabled(isBusy || !queue.canPromoteToSteer)
        Button { model.cancelServerQueued(item.runId) } label: { Image(systemName: "xmark") }
          .help("Remove from queue").accessibilityLabel("Remove queued message").disabled(isBusy)
      }
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .background(isEditing ? Color.accentColor.opacity(0.12) : isDropTarget ? Color.primary.opacity(0.06) : .clear)
    .contentShape(Rectangle())
    .modifier(QueueReorder(enabled: queue.canReorder && !isBusy, item: item, model: model, isDropTarget: $isDropTarget))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Queued: \(summary)")
    .accessibilityAction(named: "Move up") { model.moveServerQueued(item.runId, by: -1) }
    .accessibilityAction(named: "Move down") { model.moveServerQueued(item.runId, by: 1) }
  }
}

/// Drag a row onto another to reorder; off when the provider cannot reorder queued messages.
private struct QueueReorder: ViewModifier {
  let enabled: Bool
  let item: ComposerServerQueue.Item
  let model: ComposerModel
  @Binding var isDropTarget: Bool

  func body(content: Content) -> some View {
    if enabled {
      content
        .draggable(item.runId.rawValue)
        .dropDestination(for: String.self) { ids, _ in
          guard let dragged = ids.first else { return false }
          model.dropServerQueued(RunId(rawValue: dragged), onto: item.runId)
          return true
        } isTargeted: { isDropTarget = $0 }
    } else {
      content
    }
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
