import AppKit
import Foundation
import Observation
import T3ClientRuntime
import T3Contracts
import T3Preview
import UniformTypeIdentifiers

/// The browser panel of one thread: its server tabs (`preview.list` + `subscribePreviewEvents`), the stream of the tab in
/// view, who controls the page, and the offers the page makes (a download, a file picker, a dialog). It lives as long as
/// the app and only runs while the panel is on screen (`activate` / `deactivate`), so a hidden panel streams nothing.
@MainActor
@Observable
final class PreviewThreadModel: PreviewSurfaceDelegate {
  enum Phase: Equatable {
    case idle
    case connecting
    /// Connected; no frame has painted yet (the server may still be starting its browser).
    case waitingForFrame
    case streaming
    case hostSetup(PreviewStreamHostSetup)
  }

  struct DownloadOffer: Identifiable, Equatable {
    let id: String
    let fileName: String
    let sizeBytes: Int
  }

  let key: ScopedThreadKey
  private let app: AppModel
  private let client: PreviewClient

  // MARK: Observed state

  private(set) var tabs = PreviewTabsState()
  private(set) var selectedTabId: String?
  private(set) var servers: [DiscoveredLocalServer] = []
  private(set) var phase: Phase = .idle
  private(set) var control: PreviewStreamControl?
  /// The first start of the server's browser downloads it; the protocol reports no progress, only a long wait.
  private(set) var slowStart = false
  private(set) var errorMessage: String?
  private(set) var download: DownloadOffer?
  private(set) var fileChooser: PreviewStreamFileChooser?
  private(set) var isBusy = false
  /// Bumped to ask the address field for focus (`preview.focusUrl`).
  private(set) var focusAddressRequest = 0
  /// Browser focus, for the `previewFocus` keybinding context.
  private(set) var pageFocused = false
  var addressFocused = false
  var addressDraft: String?

  // MARK: Private state

  @ObservationIgnored let surface = PreviewSurfaceView(frame: .zero)
  @ObservationIgnored private var session: PreviewStreamSession?
  @ObservationIgnored private var streamTabId: String?
  @ObservationIgnored private var eventsTask: Task<Void, Never>?
  @ObservationIgnored private var discoveryTask: Task<Void, Never>?
  @ObservationIgnored private var streamEvents: Task<Void, Never>?
  @ObservationIgnored private var slowTask: Task<Void, Never>?
  @ObservationIgnored private var noticeTask: Task<Void, Never>?
  @ObservationIgnored private var isActive = false
  @ObservationIgnored private var windowVisible = true
  @ObservationIgnored private var occlusionObserver: (any NSObjectProtocol)?
  @ObservationIgnored private var surfacePoints: CGSize = .zero
  @ObservationIgnored private var surfaceScale: CGFloat = 2
  @ObservationIgnored private var queuedForControl: [PreviewStreamInput] = []
  @ObservationIgnored private var wantsPopup: String?
  @ObservationIgnored private(set) var framesPresented = 0

  init(key: ScopedThreadKey, app: AppModel) {
    self.key = key
    self.app = app
    client = PreviewClient(runtime: app.runtime)
    surface.delegate = self
  }

  // MARK: Derived

  /// Whether the environment hosts server browsers at all; without it the panel has nothing to show.
  var isSupported: Bool { app.runtime.serverConfigs[key.environmentId]?.config.environment.capabilities.serverBrowser == true }

  var serverTabs: [PreviewSessionSnapshot] { tabs.serverTabs }

  var selectedTab: PreviewSessionSnapshot? { serverTabs.first { $0.tabId == selectedTabId } ?? serverTabs.mostRecent }

  var controlsPage: Bool { control?.canOperate == true && control?.controller == .you }

  var controlLabel: String { PreviewStreamControl.label(phase == .streaming || phase == .waitingForFrame ? control : nil) }

  var canTakeControl: Bool { control?.canOperate == true && control?.controller != .anotherViewer && control?.controller != .you }

  /// What the address field shows: the draft while typing, else the page's address (which an agent's navigation keeps current).
  var addressText: String { addressDraft ?? selectedTab?.address ?? "" }

  var zoom: Double { selectedTab?.zoomFactor ?? PreviewViewports.defaultZoom }

  // MARK: Lifecycle

  func activate() {
    guard !isActive else { return }
    isActive = true
    windowVisible = surface.window?.occlusionState.contains(.visible) ?? true
    observeWindow()
    if isSupported { startEvents() }
    ensureStream()
  }

  func deactivate() {
    guard isActive else { return }
    isActive = false
    eventsTask?.cancel(); eventsTask = nil
    stopDiscovery()
    stopStream()
    if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    occlusionObserver = nil
    pageFocused = false
  }

  /// A streaming window nobody can see costs the server's screencast and this app's decode for nothing.
  private func observeWindow() {
    guard let window = surface.window, occlusionObserver == nil else { return }
    occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.windowVisible = window.occlusionState.contains(.visible)
        self.ensureStream()
      }
    }
  }

  // MARK: Tabs

  private func startEvents() {
    eventsTask?.cancel()
    let threadId = key.threadId.rawValue
    eventsTask = Task { [weak self, client, environmentId = key.environmentId, key] in
      while !Task.isCancelled {
        do {
          // Subscribing before listing leaves no gap; the reducer replays what the list already covers.
          let events = try await client.events(in: environmentId)
          if let list = try? await client.list(key.threadId, in: environmentId) { self?.apply(list: list) }
          for try await event in events where PreviewTabsState.threadId(event) == threadId { self?.apply(event: event) }
        } catch is CancellationError { return } catch {}
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  private func apply(list: PreviewListResult) {
    tabs.apply(list: list)
    reconcile()
  }

  private func apply(event: PreviewEvent) {
    let known = Set(tabs.sessions.map(\.tabId))
    if tabs.apply(event: event) == .needsRefresh {
      Task { [client, key] in if let list = try? await client.list(key.threadId, in: key.environmentId) { apply(list: list) } }
    }
    // An agent asked to show its tab, or the page opened one: follow it.
    if case .opened(let opened) = event, !known.contains(opened.tabId), opened.snapshot.runtime == .server, opened.snapshot.reveal == true || wantsPopup == opened.tabId {
      selectedTabId = opened.tabId
    }
    reconcile()
  }

  /// Keeps the selection on a tab that exists, then the stream on the selection.
  private func reconcile() {
    if let wanted = wantsPopup, serverTabs.contains(where: { $0.tabId == wanted }) { selectedTabId = wanted; wantsPopup = nil }
    if selectedTabId == nil || !serverTabs.contains(where: { $0.tabId == selectedTabId }) { selectedTabId = serverTabs.mostRecent?.tabId }
    ensureStream()
  }

  func select(_ tabId: String) {
    guard selectedTabId != tabId else { return }
    selectedTabId = tabId
    addressDraft = nil
    if isHostSetup { phase = .idle }
    ensureStream()
  }

  /// Opens a new server tab, on `address` when given (typed text is read like an address bar does).
  func openTab(_ address: String?) {
    var url: String?
    if let address, !address.trimmingCharacters(in: .whitespaces).isEmpty {
      do { url = try PreviewAddress.resolve(address) } catch { return fail("Enter an http or https address.") }
    }
    perform { [client, key] in
      let snapshot = try await client.open(key.threadId, url: url, in: key.environmentId)
      self.selectedTabId = snapshot.tabId
      self.addressDraft = nil
      self.ensureStream()
    }
  }

  func closeTab(_ tabId: String) {
    perform { [client, key] in try await client.close(key.threadId, tab: tabId, in: key.environmentId) }
  }

  // MARK: Discovery

  /// Local servers the environment found, for the new tab page; scanned only while that page is on screen.
  func startDiscovery() {
    guard discoveryTask == nil else { return }
    discoveryTask = Task { [weak self, client, environmentId = key.environmentId] in
      while !Task.isCancelled {
        do {
          for try await list in try await client.discoveredServers(in: environmentId) { self?.servers = list.servers }
        } catch is CancellationError { return } catch {}
        try? await Task.sleep(for: .seconds(3))
      }
    }
  }

  func stopDiscovery() {
    discoveryTask?.cancel()
    discoveryTask = nil
  }

  // MARK: Stream

  /// Starts, retargets or stops the viewer socket so it follows: panel on screen, a window someone can see, a tab, a size.
  private func ensureStream() {
    guard isActive, windowVisible, surfacePoints.width >= 1, let tab = selectedTab, isSupported else {
      if session != nil { stopStream() }
      return
    }
    guard streamTabId != tab.tabId else { return }
    stopStream()
    streamTabId = tab.tabId
    phase = .connecting
    armSlowStart()
    let cap = PreviewFrameCap.request(view: surfacePoints, backingScale: surfaceScale)
    let surface = surface
    let pipeline = PreviewFramePipeline { [weak self] frame in
      surface.present(frame)
      self?.framesPresented += 1
    }
    let access: @Sendable () async throws -> PreviewStreamAccess = { [client, environmentId = key.environmentId] in try await client.access(in: environmentId) }
    let session = PreviewStreamSession(threadId: key.threadId.rawValue, tabId: tab.tabId, cap: cap, pipeline: pipeline, access: access)
    self.session = session
    streamEvents = Task { [weak self] in
      for await event in session.events { self?.handle(event, from: session) }
    }
    session.start()
  }

  private func stopStream() {
    session?.stop()
    session = nil
    streamEvents?.cancel()
    streamEvents = nil
    streamTabId = nil
    slowTask?.cancel()
    slowStart = false
    control = nil
    download = nil
    fileChooser = nil
    queuedForControl = []
    surface.clear()
    surface.resetInput()
    if !isHostSetup { phase = .idle }
  }

  private var isHostSetup: Bool { if case .hostSetup = phase { true } else { false } }

  /// A slow start is the first use of the server's browser, which downloads it (about 120 MB).
  private func armSlowStart() {
    slowTask?.cancel()
    slowStart = false
    slowTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      self?.slowStart = true
    }
  }

  private func handle(_ event: PreviewStreamSession.Event, from source: PreviewStreamSession) {
    guard source === session else { return }
    switch event {
    case .connecting:
      if phase != .waitingForFrame { phase = .connecting }
    case .connected:
      phase = surface.hasFrame ? .streaming : .waitingForFrame
    case .disconnected(let reason):
      control = nil
      surface.resetInput()
      phase = .connecting
      surface.hideAgentPointer()
      if let reason { errorMessage = reason }
    case .hostSetup(let setup):
      session?.stop(); session = nil
      streamTabId = nil
      slowTask?.cancel()
      phase = .hostSetup(setup)
    case .gone:
      session = nil
      streamTabId = nil
      phase = .idle
      // The tab list catches up through its own event; a vanished tab must not be retried in a loop.
    case .message(let message): handle(message)
    }
  }

  private func handle(_ message: PreviewStreamMessage) {
    switch message {
    case .viewport(let width, let height):
      surface.pageSize = CGSize(width: width, height: height)
    case .control(let next):
      let before = control
      control = next
      if next.controller == .you {
        surface.hideAgentPointer()
        if before?.controller != .you {
          // The viewer's size is the page's size while the tab fills its panel.
          if surfacePoints.width >= 1 { session?.send(.resize(width: Int(surfacePoints.width), height: Int(surfacePoints.height))) }
          surface.window?.makeFirstResponder(surface)
          let queued = queuedForControl
          queuedForControl = []
          for input in queued { session?.send(input) }
        }
      } else {
        surface.resetInput()
        if before?.controller == .you, surface.window?.firstResponder === surface { surface.window?.makeFirstResponder(nil) }
        // A command that arrived before the first control message asks for control now.
        if !queuedForControl.isEmpty, before == nil {
          if next.canOperate, next.controller != .anotherViewer { session?.send(.takeControl) } else { queuedForControl = []; fail("Another viewer has control of this browser.") }
        }
      }
    case .pointer(let pointer):
      surface.showAgentPointer(pointer)
    case .clipboard(let text):
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      notice("The page copied text to the clipboard.")
    case .download(let offer):
      download = DownloadOffer(id: offer.id, fileName: offer.fileName, sizeBytes: offer.sizeBytes)
    case .fileChooser(let chooser):
      fileChooser = chooser
    case .fileChooserClosed(let id):
      if fileChooser?.id == id { fileChooser = nil }
    case .popup(let tabId):
      wantsPopup = tabId
      reconcile()
    case .probe:
      break
    }
  }

  // MARK: PreviewSurfaceDelegate

  func surface(send input: PreviewStreamInput) { session?.send(input) }

  func surfaceResized(points: CGSize, scale: CGFloat) {
    surfacePoints = points
    surfaceScale = scale
    // The window exists once the view has a size: from here on a hidden window pauses the stream.
    if occlusionObserver == nil, isActive {
      windowVisible = surface.window?.occlusionState.contains(.visible) ?? true
      observeWindow()
    }
    if session == nil { ensureStream(); return }
    session?.setCap(PreviewFrameCap.request(view: points, backingScale: scale))
    if controlsPage { session?.send(.resize(width: Int(points.width), height: Int(points.height))) }
  }

  func surfaceFocusChanged(_ focused: Bool) { pageFocused = focused }

  func surfaceFirstFrame() {
    phase = .streaming
    slowTask?.cancel()
    slowStart = false
    errorMessage = nil
  }

  // MARK: Actions

  func takeControl() { session?.send(.takeControl) }
  func releaseControl() { session?.send(.releaseControl) }

  /// A browser command needs control of the page; asking for it is part of the command, so Back, Reload and the address
  /// field work in one step, as in any browser.
  private func command(_ input: PreviewStreamInput) {
    guard let session else { return }
    if controlsPage { session.send(input); return }
    // Before the first control message the tab is still connecting: the command waits for it.
    guard let control else { queuedForControl.append(input); return }
    guard control.canOperate, control.controller != .anotherViewer else { return fail("Another viewer has control of this browser.") }
    queuedForControl.append(input)
    session.send(.takeControl)
  }

  func back() { command(.history(delta: -1)) }
  func forward() { command(.history(delta: 1)) }
  func reload() { command(.reload()) }

  func submitAddress() {
    let text = addressText
    addressDraft = nil
    do { command(.navigate(url: try PreviewAddress.resolve(text))) } catch { fail("Enter an http or https address.") }
  }

  func requestAddressFocus() { focusAddressRequest += 1 }

  /// After a host setup the person ran what the panel asked for.
  func retry() {
    if isHostSetup { phase = .idle }
    if isActive, eventsTask == nil, isSupported { startEvents() }
    ensureStream()
  }

  func answerDialog(accept: Bool, promptText: String?) { session?.send(.dialog(accept: accept, promptText: promptText)) }

  func adjust(zoomStep step: Int? = nil, resetZoom: Bool = false, colorScheme: PreviewAppearancePreference? = nil, hardReload: Bool = false, clear: PreviewAdjustInputClear? = nil) {
    guard let tab = selectedTab else { return }
    var input = PreviewAdjustInput(threadId: key.threadId, tabId: tab.tabId)
    if resetZoom { input.zoomFactor = PreviewViewports.defaultZoom } else if let step { input.zoomFactor = PreviewViewports.zoom(from: zoom, step: step) }
    input.colorScheme = colorScheme
    if hardReload { input.hardReload = true }
    input.clear = clear
    perform { [client, key] in try await client.adjust(input, in: key.environmentId) }
  }

  func setViewport(_ setting: PreviewViewportSetting) {
    guard let tab = selectedTab else { return }
    perform { [client, key] in try await client.resize(key.threadId, tab: tab.tabId, to: setting, in: key.environmentId) }
  }

  func dismissError() { errorMessage = nil }

  // MARK: Downloads and uploads

  /// Fetches the downloaded file from the environment and saves it where the person says.
  func saveDownload() {
    guard let offer = download, let tab = selectedTab else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = offer.fileName
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    download = nil
    perform { [client, key] in
      let access = try await client.access(in: key.environmentId)
      let url = PreviewStream.downloadURL(httpBase: access.httpBase, threadId: key.threadId.rawValue, tabId: tab.tabId, id: offer.id, ticket: access.ticket)
      let (file, response) = try await URLSession.shared.download(from: url)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PreviewFailure("The environment no longer has this download.") }
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: file, to: destination)
    }
  }

  func dismissDownload() { download = nil }

  /// Answers the page's open file picker with files from this Mac; no files cancels it.
  func chooseFiles() {
    guard let chooser = fileChooser, let tab = selectedTab else { return }
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = chooser.multiple
    panel.canChooseDirectories = false
    let types = Self.contentTypes(accept: chooser.accept)
    if !types.isEmpty { panel.allowedContentTypes = types }
    guard panel.runModal() == .OK else { return }
    upload(panel.urls, chooser: chooser, tab: tab.tabId)
  }

  func cancelFileChooser() {
    guard let chooser = fileChooser, let tab = selectedTab else { return }
    upload([], chooser: chooser, tab: tab.tabId)
  }

  private func upload(_ files: [URL], chooser: PreviewStreamFileChooser, tab: String) {
    fileChooser = nil
    perform { [client, key] in
      let access = try await client.access(in: key.environmentId)
      var request = URLRequest(url: PreviewStream.uploadURL(httpBase: access.httpBase, threadId: key.threadId.rawValue, tabId: tab, chooser: chooser.id, ticket: access.ticket))
      request.httpMethod = "POST"
      let boundary = "kestrel-\(UUID().uuidString)"
      request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
      let body = FileManager.default.temporaryDirectory.appending(path: "kestrel-upload-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: body) }
      try Self.multipartBody(files, boundary: boundary, to: body)
      let (data, response) = try await URLSession.shared.upload(for: request, fromFile: body)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard (200..<300).contains(status) else { throw PreviewFailure(String(data: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 } ?? "The upload was refused.") }
    }
  }

  /// `multipart/form-data` with one `file` part per file, streamed to disk so a large file is not held in memory.
  nonisolated private static func multipartBody(_ files: [URL], boundary: String, to destination: URL) throws {
    FileManager.default.createFile(atPath: destination.path, contents: nil)
    let output = try FileHandle(forWritingTo: destination)
    defer { try? output.close() }
    for file in files {
      let name = file.lastPathComponent.replacingOccurrences(of: "\"", with: "%22")
      let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
      try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: \(type)\r\n\r\n".utf8))
      let input = try FileHandle(forReadingFrom: file)
      defer { try? input.close() }
      while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { try output.write(contentsOf: chunk) }
      try output.write(contentsOf: Data("\r\n".utf8))
    }
    try output.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
  }

  /// The input's `accept` attribute as file types: `image/*`, exact MIME types and extensions.
  nonisolated static func contentTypes(accept: String) -> [UTType] {
    accept.split(separator: ",").compactMap { part -> UTType? in
      let token = part.trimmingCharacters(in: .whitespaces).lowercased()
      if token.hasPrefix(".") { return UTType(filenameExtension: String(token.dropFirst())) }
      if token.hasSuffix("/*") { return family(String(token.dropLast(2))) }
      return UTType(mimeType: token)
    }
  }

  nonisolated private static func family(_ name: String) -> UTType? {
    switch name {
    case "image": .image
    case "audio": .audio
    case "video": .movie
    case "text": .text
    default: nil
    }
  }

  // MARK: Plumbing

  private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
    isBusy = true
    Task {
      do { try await operation(); errorMessage = nil } catch { errorMessage = PreviewClient.failure(error).message }
      isBusy = false
    }
  }

  private func fail(_ message: String) { errorMessage = message }

  private func notice(_ message: String) {
    // ponytail: errors and notices share one line; a second kind of banner when notices need an action.
    noticeTask?.cancel()
    errorMessage = message
    noticeTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled, self?.errorMessage == message else { return }
      self?.errorMessage = nil
    }
  }

  // MARK: Debug

  #if DEBUG
  var debugSummary: String {
    "supported=\(isSupported) tabs=\(serverTabs.map { "\($0.tabId)=\($0.address)" }) selected=\(selectedTab?.tabId ?? "-") phase=\(phase) windowVisible=\(windowVisible) occlusion=\(surface.window?.occlusionState.rawValue ?? 0) control=\(PreviewStreamControl.label(control)) frames=\(framesPresented) frameSize=\(surface.frameSize) page=\(surface.pageSize) surface=\(surfacePoints) back=\(selectedTab?.canGoBack ?? false) fwd=\(selectedTab?.canGoForward ?? false) zoom=\(zoom) viewport=\(String(describing: selectedTab?.viewport)) lastClose=\(PreviewStreamSession.lastClose) slow=\(slowStart) error=\(errorMessage ?? "-")"
  }
  #endif
}

/// The models by thread, so a panel that was switched away from keeps its tabs and the commands reach the one on screen.
@MainActor
final class PreviewStore {
  static let shared = PreviewStore()
  private var models: [String: PreviewThreadModel] = [:]

  func model(for key: ScopedThreadKey, app: AppModel) -> PreviewThreadModel {
    if let model = models[key.description] { return model }
    let model = PreviewThreadModel(key: key, app: app)
    models[key.description] = model
    return model
  }

  func existing(_ key: ScopedThreadKey) -> PreviewThreadModel? { models[key.description] }

  /// Whether any browser has keyboard focus: the `previewFocus` context of the keybindings.
  var isFocused: Bool { models.values.contains { $0.pageFocused || $0.addressFocused } }
}
