import AppKit
import SwiftUI
import T3ClientRuntime
import T3Contracts
import T3Preview

/// The Preview tab of the right panel: the thread's server browser tabs, an address bar, and the page itself. The page
/// runs on the environment's server (agents drive it with their `preview_*` tools); this only views it, and controls it
/// when the person takes control.
struct PreviewPanelView: View {
  let app: AppModel
  let key: ScopedThreadKey
  @State private var model: PreviewThreadModel?

  var body: some View {
    Group {
      if let model {
        if model.isSupported {
          PreviewBrowser(model: model)
        } else {
          ContentUnavailableView("No browser on this environment", systemImage: "globe", description: Text("This server does not host a browser for the preview. Update T3 Code on its host to use it."))
        }
      } else {
        Color.clear
      }
    }
    .task(id: key) {
      let model = PreviewStore.shared.model(for: key, app: app)
      self.model = model
      model.activate()
    }
    .onChange(of: model?.isSupported) { _, _ in model?.retry() }
    .onDisappear { model?.deactivate() }
  }
}

private struct PreviewBrowser: View {
  @Bindable var model: PreviewThreadModel
  @FocusState private var addressFocus: Bool
  @State private var promptText = ""

  var body: some View {
    VStack(spacing: 0) {
      if !model.serverTabs.isEmpty { tabStrip; Divider() }
      if let tab = model.selectedTab { toolbar(tab); Divider() }
      banners
      ZStack {
        PreviewSurface(view: model.surface)
          .opacity(model.selectedTab == nil ? 0 : 1)
          .accessibilityHidden(model.selectedTab == nil)
        overlay
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      if let tab = model.selectedTab, tab.navStatus != .idle { Divider(); controlBar }
    }
    .background(Palette.canvas)
    .onChange(of: addressFocus) { _, focused in model.addressFocused = focused }
    .onChange(of: model.focusAddressRequest) { _, _ in addressFocus = true }
  }

  // MARK: Tabs

  private var tabStrip: some View {
    HStack(spacing: 2) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 2) {
          ForEach(model.serverTabs, id: \.tabId) { tab in
            let active = tab.tabId == model.selectedTab?.tabId
            HStack(spacing: 4) {
              Button { model.select(tab.tabId) } label: {
                HStack(spacing: 4) {
                  if tab.isLoading { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12) } else { Image(systemName: "globe").font(.caption) }
                  Text(tab.displayTitle).font(.callout.weight(active ? .semibold : .regular)).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
                }
              }
              .buttonStyle(.plain)
              Button { model.closeTab(tab.tabId) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(Palette.muted)
                .help("Close tab").accessibilityLabel("Close \(tab.displayTitle)")
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(active ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .foregroundStyle(active ? Palette.text : Palette.muted)
          }
        }
      }
      Button { model.openTab(nil) } label: { Image(systemName: "plus") }
        .buttonStyle(.borderless).help("New tab").accessibilityLabel("New tab")
    }
    .padding(.horizontal, 8).padding(.vertical, 4)
  }

  // MARK: Toolbar

  private func toolbar(_ tab: PreviewSessionSnapshot) -> some View {
    HStack(spacing: 6) {
      Button { model.back() } label: { Image(systemName: "chevron.left") }
        .disabled(!tab.canGoBack || model.phase != .streaming).help("Back").accessibilityLabel("Back")
      Button { model.forward() } label: { Image(systemName: "chevron.right") }
        .disabled(!tab.canGoForward || model.phase != .streaming).help("Forward").accessibilityLabel("Forward")
      Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
        .disabled(model.phase != .streaming).help("Reload").accessibilityLabel("Reload")
      TextField("Search or enter address", text: Binding(get: { model.addressText }, set: { model.addressDraft = $0 }))
        .textFieldStyle(.roundedBorder)
        .focused($addressFocus)
        .onSubmit { model.submitAddress() }
        .onExitCommand { model.addressDraft = nil; addressFocus = false }
        .disabled(model.phase != .streaming && tab.navStatus != .idle)
        .accessibilityLabel("Address")
      Menu { tabMenu(tab) } label: { Image(systemName: "ellipsis") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Browser tab options").accessibilityLabel("Browser tab options")
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 10).padding(.vertical, 6)
  }

  @ViewBuilder private func tabMenu(_ tab: PreviewSessionSnapshot) -> some View {
    Button("Hard Reload") { model.adjust(hardReload: true) }
    Menu("Zoom (\(Int((model.zoom * 100).rounded()))%)") {
      Button("Zoom In") { model.adjust(zoomStep: 1) }
      Button("Zoom Out") { model.adjust(zoomStep: -1) }
      Button("Actual Size") { model.adjust(resetZoom: true) }
    }
    Menu("Appearance") {
      ForEach(["system", "light", "dark"], id: \.self) { name in
        Button((tab.colorScheme?.rawValue ?? "system") == name ? "\u{2713} \(name.capitalized)" : name.capitalized) {
          model.adjust(colorScheme: PreviewAppearancePreference(rawValue: name))
        }
      }
    }
    Menu("Viewport") {
      Button(isFill(tab) ? "\u{2713} Fit to Panel" : "Fit to Panel") { model.setViewport(.fill) }
      if let rotated = PreviewViewports.rotated(tab.viewport ?? .fill) { Button("Rotate") { model.setViewport(rotated) } }
      Divider()
      ForEach([PreviewViewportPreset.Category.phone, .tablet], id: \.self) { category in
        Menu(category.rawValue) {
          ForEach(PreviewViewports.presets.filter { $0.category == category }) { preset in
            Button("\(preset.label)  \(preset.width) \u{00D7} \(preset.height)") { model.setViewport(preset.setting) }
          }
        }
      }
    }
    Divider()
    Button("Clear Cookies", role: .destructive) { model.adjust(clear: .cookies) }
    Button("Clear Cache", role: .destructive) { model.adjust(clear: .cache) }
    Divider()
    Button("Close Tab") { model.closeTab(tab.tabId) }
  }

  private func isFill(_ tab: PreviewSessionSnapshot) -> Bool {
    if case .fill? = tab.viewport { return true }
    return tab.viewport == nil
  }

  // MARK: Control

  private var controlBar: some View {
    HStack(spacing: 8) {
      Circle().fill(model.controlsPage ? Color.green : Palette.muted.opacity(0.5)).frame(width: 7, height: 7)
      Text(model.controlLabel).font(.caption).foregroundStyle(Palette.muted)
      if model.controlsPage { Text("Shift+Esc returns the keyboard to the app").font(.caption2).foregroundStyle(Palette.muted.opacity(0.8)) }
      Spacer()
      if model.controlsPage {
        Button("Release Control") { model.releaseControl() }
      } else if model.control?.canOperate == true {
        Button("Take Control") { model.takeControl() }.disabled(!model.canTakeControl)
      }
    }
    .controlSize(.small)
    .padding(.horizontal, 10).padding(.vertical, 5)
  }

  // MARK: Banners

  @ViewBuilder private var banners: some View {
    if let message = model.errorMessage {
      bannerRow(symbol: "exclamationmark.triangle", text: message) { Button { model.dismissError() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless) }
    }
    if let failure = model.selectedTab?.failure, failure.download == nil {
      bannerRow(symbol: "wifi.exclamationmark", text: "Could not load \(failure.url): \(failure.description)") { EmptyView() }
    }
    if let download = model.download {
      bannerRow(symbol: "arrow.down.circle", text: "Downloaded \(download.fileName) (\(ByteCountFormatter.string(fromByteCount: Int64(download.sizeBytes), countStyle: .file)))") {
        Button("Save\u{2026}") { model.saveDownload() }
        Button { model.dismissDownload() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
      }
    }
    if let chooser = model.fileChooser, model.controlsPage {
      bannerRow(symbol: "doc", text: "The page asks for \(chooser.multiple ? "files" : "a file").") {
        Button("Choose\u{2026}") { model.chooseFiles() }
        Button("Cancel") { model.cancelFileChooser() }
      }
    }
    if let dialog = model.control?.dialog, model.controlsPage {
      VStack(alignment: .leading, spacing: 6) {
        Text(dialog.message).font(.callout)
        if dialog.type == "prompt" { TextField("", text: $promptText).textFieldStyle(.roundedBorder).onAppear { promptText = dialog.defaultValue } }
        HStack {
          Spacer()
          if dialog.type != "alert" { Button("Cancel") { model.answerDialog(accept: false, promptText: nil) } }
          Button("OK") { model.answerDialog(accept: true, promptText: dialog.type == "prompt" ? promptText : nil) }.keyboardShortcut(.defaultAction)
        }
      }
      .padding(10).background(Palette.surface)
      Divider()
    }
  }

  private func bannerRow<Actions: View>(symbol: String, text: String, @ViewBuilder actions: () -> Actions) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: symbol).foregroundStyle(Palette.muted)
        Text(text).font(.callout).lineLimit(2).textSelection(.enabled)
        Spacer(minLength: 8)
        actions()
      }
      .controlSize(.small)
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(Palette.surface)
      Divider()
    }
  }

  // MARK: Overlays

  @ViewBuilder private var overlay: some View {
    if model.serverTabs.isEmpty {
      NewTabPage(model: model, createsTab: true)
    } else if let tab = model.selectedTab, tab.navStatus == .idle {
      NewTabPage(model: model, createsTab: false).background(Palette.canvas)
    } else if case .hostSetup(let setup) = model.phase {
      hostSetup(setup)
    } else if model.phase == .connecting || model.phase == .waitingForFrame, !model.surface.hasFrame {
      VStack(spacing: 10) {
        ProgressView()
        Text(model.slowStart ? "Starting the server\u{2019}s browser\u{2026}" : "Connecting\u{2026}").font(.callout)
        if model.slowStart {
          Text("The first start downloads the browser (about 120 MB) and can take a minute.").font(.caption).foregroundStyle(Palette.muted).multilineTextAlignment(.center).frame(maxWidth: 280)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Palette.canvas.opacity(0.9))
      .accessibilityElement(children: .combine)
    }
  }

  private func hostSetup(_ setup: PreviewStreamHostSetup) -> some View {
    VStack(spacing: 10) {
      Image(systemName: "wrench.and.screwdriver").font(.title)
      Text(setup.message).font(.callout).multilineTextAlignment(.center).frame(maxWidth: 360)
      Text(setup.command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
        .padding(8).background(Palette.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      HStack {
        Button("Copy Command") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(setup.command, forType: .string) }
        Button("Try Again") { model.retry() }
      }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Palette.canvas)
  }
}

/// A tab without a page, and the panel before any tab: an address to open and the servers running on the environment.
private struct NewTabPage: View {
  @Bindable var model: PreviewThreadModel
  /// There is no tab yet, so submitting opens one; otherwise it navigates the idle tab in view.
  let createsTab: Bool
  @State private var text = ""
  @FocusState private var focused: Bool

  var body: some View {
    VStack(spacing: 16) {
      Spacer(minLength: 0)
      Image(systemName: "globe").font(.system(size: 34)).foregroundStyle(Palette.muted)
      HStack {
        TextField("Search or enter address", text: $text).textFieldStyle(.roundedBorder).focused($focused).onSubmit { open(text) }.accessibilityLabel("Address")
        Button("Open") { open(text) }.disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
      }
      .frame(maxWidth: 420)
      if !model.servers.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("Running on this environment").font(.caption).foregroundStyle(Palette.muted)
          ForEach(model.servers, id: \.url) { server in
            Button { open(server.url) } label: {
              HStack {
                Image(systemName: "server.rack").foregroundStyle(Palette.muted)
                VStack(alignment: .leading, spacing: 0) {
                  Text(server.url).font(.callout).lineLimit(1)
                  if let name = server.processName { Text(name).font(.caption).foregroundStyle(Palette.muted) }
                }
                Spacer()
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
          }
        }
        .frame(maxWidth: 420)
      }
      Spacer(minLength: 0)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { model.startDiscovery(); focused = true }
    .onDisappear { model.stopDiscovery() }
  }

  private func open(_ address: String) {
    guard !address.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    if createsTab { model.openTab(address) } else { model.addressDraft = address; model.submitAddress() }
    text = ""
  }
}
