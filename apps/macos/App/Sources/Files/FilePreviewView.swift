import AVKit
import PDFKit
import SwiftUI
import T3ClientRuntime
import T3Markdown

/// A `file:<path>` tab: the file as source (highlighted, with line numbers and `#L` anchors), rendered Markdown,
/// a CSV/TSV table, an image, PDF, audio or video; with an editor and Save for text files.
struct FilePreviewView: View {
  let app: AppModel
  let key: ScopedThreadKey
  let store: RightPanelStore
  @State private var document: FileDocument
  @State private var selectedLines: ClosedRange<Int>?
  @State private var comment = ""
  @State private var forceSource = false
  @AppStorage("files.renderMarkdown") private var renderMarkdown = true
  @AppStorage("files.renderTable") private var renderTable = true
  @AppStorage("files.wordWrap") private var wordWrap = false

  init(app: AppModel, key: ScopedThreadKey, path: String, store: RightPanelStore) {
    self.app = app
    self.key = key
    self.store = store
    _document = State(initialValue: FileSurfaces.shared.document(path, in: key, app: app))
  }

  private var reveal: FileReveal? { store.reveal(document.path, in: key) }
  private var rendersMarkdown: Bool { document.kind == .markdown && renderMarkdown && !forceSource && !document.isEditing }
  private var delimiter: Character? {
    if case .delimited(let character) = document.kind { return character }
    return nil
  }
  private var rendersTable: Bool { delimiter != nil && renderTable && !forceSource && !document.isEditing }
  private var showsSource: Bool { document.phase == .text && !rendersMarkdown && !rendersTable }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if document.truncated, document.phase == .text {
        Text("Preview limited to the first 1 MB of a \(document.byteLength.formatted()) byte file.")
          .font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
          .background(.orange.opacity(0.1))
      }
      if let error = document.saveError {
        Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
          .background(.red.opacity(0.08))
      }
      content
      if showsSource, let lines = selectedLines { commentBar(lines) }
    }
    .task { document.load() }
    .onChange(of: reveal?.token) { _, token in if token != nil { forceSource = true } }
    .onAppear { if reveal != nil { forceSource = true } }
  }

  // MARK: Header

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: FileLogic.symbol(for: document.path)).foregroundStyle(Palette.muted)
      Text(document.path).font(.callout).lineLimit(1).truncationMode(.head).help(document.path)
      if document.isDirty { Circle().fill(.orange).frame(width: 7, height: 7).help("Unsaved changes").accessibilityLabel("Unsaved changes") }
      Spacer(minLength: 8)
      if document.phase == .text, document.kind == .markdown || delimiter != nil {
        Picker("View", selection: renderedBinding) {
          Text(document.kind == .markdown ? "Preview" : "Table").tag(true)
          Text("Source").tag(false)
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 130).disabled(document.isEditing)
      }
      if showsSource {
        Toggle(isOn: $wordWrap) { Image(systemName: "text.word.spacing") }
          .toggleStyle(.button).buttonStyle(.borderless).help("Wrap lines").accessibilityLabel("Wrap lines")
      }
      if document.canEdit {
        if document.isEditing {
          Button(document.isDirty ? "Revert" : "Done") { document.discardEdits() }
          Button { Task { await document.save() } } label: { Text(document.isSaving ? "Saving" : "Save") }
            .keyboardShortcut("s", modifiers: .command).disabled(!document.isDirty || document.isSaving).buttonStyle(.borderedProminent).controlSize(.small)
        } else {
          Button("Edit") { forceSource = true; document.isEditing = true }
        }
      }
      Menu {
        Button("Add to Message") { app.addFileToComposer(document.path, in: key) }
        Divider()
        Button("Open in Editor") { app.openInEditor(document.path, line: selectedLines?.lowerBound, in: key) }
        if app.isLocalEnvironment(key) { Button("Reveal in Finder") { app.revealInFinder(document.path, in: key) } }
        Button("Copy Path") { app.copyToPasteboard(app.absoluteFilePath(document.path, in: key)) }
        Button("Copy Relative Path") { app.copyToPasteboard(document.path) }
        Divider()
        Button("Reload") { document.load() }.disabled(document.isDirty)
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More actions").accessibilityLabel("File actions")
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 12)
    .frame(height: 36)
  }

  private var renderedBinding: Binding<Bool> {
    Binding(
      get: { document.kind == .markdown ? rendersMarkdown : rendersTable },
      set: { value in
        forceSource = false
        if document.kind == .markdown { renderMarkdown = value } else { renderTable = value }
      })
  }

  // MARK: Content

  @ViewBuilder private var content: some View {
    switch document.phase {
    case .loading:
      ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
    case .failed(let message):
      ContentUnavailableView {
        Label("Could not open \(document.name)", systemImage: "exclamationmark.triangle")
      } description: {
        Text(message)
      } actions: {
        Button("Try Again") { document.load() }
        Button("Open in Editor") { app.openInEditor(document.path, in: key) }
      }
    case .binary:
      ContentUnavailableView {
        Label("Binary file", systemImage: "doc.zipper")
      } description: {
        Text("\(document.name) is not text. Open it in another app to view its contents.")
      } actions: {
        Button("Open in Editor") { app.openInEditor(document.path, in: key) }
      }
    case .folder:
      ContentUnavailableView {
        Label("\(document.name) is a folder", systemImage: "folder")
      } actions: {
        Button("Show in Files") { store.open(.files, in: key) }
      }
    case .asset(let url):
      assetView(url)
    case .text:
      textBody
    }
  }

  @ViewBuilder private var textBody: some View {
    if rendersMarkdown {
      ScrollView {
        MarkdownView(
          document.text, options: MarkdownOptions(baseDirectory: (app.absoluteFilePath(document.path, in: key) as NSString).deletingLastPathComponent),
          imageLoader: { [app, key] image in await app.assets.image(for: image, in: key) }, onLink: { [app, key] in app.open($0, in: key) }
        )
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    } else if let delimiter, rendersTable {
      DelimitedTableView(name: document.name, text: document.text, delimiter: delimiter)
    } else {
      SourceView(
        text: Bindable(document).text, path: document.path, isEditable: document.isEditing, wordWrap: wordWrap, reveal: reveal,
        onRevealed: { store.clearReveal(document.path, in: key) }, onSelection: { selectedLines = $0 })
    }
  }

  @ViewBuilder private func assetView(_ url: URL) -> some View {
    switch document.kind {
    case .video, .audio: MediaPlayerView(url: url)
    case .pdf: PDFFileView(document: document)
    default: ImageFileView(document: document)
    }
  }

  // MARK: Add to message

  private func commentBar(_ lines: ClosedRange<Int>) -> some View {
    VStack(spacing: 0) {
      Divider()
      HStack(spacing: 8) {
        Image(systemName: "text.bubble").foregroundStyle(Palette.muted)
        Text("\(document.name) \u{00B7} \(FileLogic.rangeLabel(start: lines.lowerBound, end: lines.upperBound))")
          .font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 170, alignment: .leading)
        TextField("Comment for the agent (optional)", text: $comment).textFieldStyle(.plain).onSubmit { submit(lines) }
        Button("Add to Message") { submit(lines) }.buttonStyle(.borderedProminent).controlSize(.small)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
    .background(Palette.surface)
  }

  private func submit(_ lines: ClosedRange<Int>) {
    if app.addFileSelectionToComposer(path: document.path, contents: document.text, start: lines.lowerBound, end: lines.upperBound, comment: comment, in: key) {
      comment = ""
      selectedLines = nil
    }
  }
}

// MARK: Table

/// CSV/TSV as a bounded table (100 rows, 30 columns); the source view keeps every byte.
private struct DelimitedTableView: View {
  let name: String
  let table: (rows: [[String]], truncated: Bool)

  init(name: String, text: String, delimiter: Character) {
    self.name = name
    table = FileLogic.parseDelimited(text, delimiter: delimiter)
  }

  private static let columnWidth: CGFloat = 170

  var body: some View {
    VStack(spacing: 0) {
      if table.truncated {
        Text("Table limited to the first 100 rows and 30 columns. Switch to source for the rest.")
          .font(.caption).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
      }
      ScrollView([.horizontal, .vertical]) {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
          Section {
            ForEach(Array(table.rows.dropFirst().enumerated()), id: \.offset) { index, row in
              rowView(row, header: false).background(index.isMultiple(of: 2) ? Color.clear : Palette.surface.opacity(0.6))
            }
          } header: {
            if let header = table.rows.first { rowView(header, header: true).background(.bar) }
          }
        }
      }
    }
    .accessibilityLabel(name)
  }

  private func rowView(_ row: [String], header: Bool) -> some View {
    HStack(alignment: .top, spacing: 0) {
      ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
        Text(cell).font(.callout.weight(header ? .semibold : .regular)).lineLimit(3).textSelection(.enabled)
          .frame(width: Self.columnWidth, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 5)
      }
    }
    .overlay(alignment: .bottom) { Divider().opacity(0.5) }
  }
}

// MARK: Assets

private struct ImageFileView: View {
  let document: FileDocument
  @State private var image: NSImage?
  @State private var failure: String?

  var body: some View {
    Group {
      if let image {
        // Shrinks to the panel's width, never beyond the image's own size.
        ScrollView {
          Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: max(image.size.width, 1)).padding(16)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(document.path)
        }
      } else if let failure {
        ContentUnavailableView("Could not show the image", systemImage: "photo", description: Text(failure))
      } else {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task {
      do {
        let data = try await document.assetData()
        if let decoded = NSImage(data: data) { image = decoded } else { failure = "The file is not an image this Mac can decode." }
      } catch { failure = error.localizedDescription }
    }
  }
}

private struct PDFFileView: View {
  let document: FileDocument
  @State private var pdf: PDFDocument?
  @State private var failure: String?

  var body: some View {
    Group {
      if let pdf {
        PDFKitView(document: pdf).accessibilityLabel(document.path)
      } else if let failure {
        ContentUnavailableView("Could not show the PDF", systemImage: "doc.richtext", description: Text(failure))
      } else {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task {
      do {
        let data = try await document.assetData()
        if let decoded = PDFDocument(data: data) { pdf = decoded } else { failure = "The file is not a readable PDF." }
      } catch { failure = error.localizedDescription }
    }
  }
}

private struct PDFKitView: NSViewRepresentable {
  let document: PDFDocument

  func makeNSView(context: Context) -> PDFView {
    let view = PDFView()
    view.autoScales = true
    view.displayMode = .singlePageContinuous
    view.document = document
    return view
  }

  func updateNSView(_ view: PDFView, context: Context) {
    if view.document !== document { view.document = document }
  }
}

/// Audio and video play from the signed URL (the server answers byte ranges), with the system's inline controls.
private struct MediaPlayerView: View {
  let url: URL
  @State private var player: AVPlayer

  init(url: URL) {
    self.url = url
    _player = State(initialValue: AVPlayer(url: url))
  }

  var body: some View {
    VideoPlayer(player: player)
      .onDisappear { player.pause() }
      .accessibilityLabel("Media player")
  }
}
