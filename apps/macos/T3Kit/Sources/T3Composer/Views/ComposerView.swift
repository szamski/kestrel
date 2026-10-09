import AppKit
import SwiftUI
import T3Contracts
import UniformTypeIdentifiers

/// The composer: editor, attachments, queued messages, approval and question panels, and the
/// footer controls. Embed it under the reading window and give it the full width; it sizes itself.
///
/// The `@` menu floats above the composer without clipping, so the host must not clip its bounds.
public struct ComposerView: View {
  let model: ComposerModel
  var style = ComposerEditorStyle()
  var onChipActivate: (RichAtom, ChipAction) -> Void

  @State private var width: CGFloat = 720
  @State private var isFileImporterPresented = false
  @State private var isTraitsOpen = false

  public init(model: ComposerModel, style: ComposerEditorStyle = ComposerEditorStyle(), onChipActivate: @escaping (RichAtom, ChipAction) -> Void = { _, _ in }) {
    self.model = model
    self.style = style
    self.onChipActivate = onChipActivate
  }

  private var isCompact: Bool { ComposerFooterLayout.shouldUseCompactFooter(width: width) }

  public var body: some View {
    VStack(spacing: 8) {
      ComposerNoticeList(model: model)
      ComposerQueueList(model: model)
      card
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    .overlay(alignment: .top) {
      // A zero-height frame pinned to the top edge; the menu grows upward out of it.
      if model.isMenuOpen && !model.isEditorDisabled {
        ComposerMenuView(model: model).fixedSize(horizontal: false, vertical: true).padding(.leading, 12).frame(maxWidth: .infinity, minHeight: 0, maxHeight: 0, alignment: .bottomLeading).offset(y: -8)
      }
    }
    .fileImporter(isPresented: $isFileImporterPresented, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
      guard case .success(let urls) = result else { return }
      let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
      Task {
        _ = await model.addFiles(urls: urls)
        scoped.forEach { $0.stopAccessingSecurityScopedResource() }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Composer")
  }

  // MARK: Card

  private var card: some View {
    VStack(spacing: 0) {
      if let approval = model.activeApproval { ComposerApprovalPanel(model: model, approval: approval) }
      if let prompt = model.activeUserInput { ComposerUserInputPanel(model: model, prompt: prompt) }
      if model.activeApproval == nil { ComposerAttachmentShelf(model: model) }
      editor
      if let message = model.validationMessage ?? model.errorMessage {
        Text(message).font(.system(size: 12)).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 4)
          .accessibilityLabel("Error: \(message)")
      }
      footer.padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 2)
    }
    .background(RoundedRectangle(cornerRadius: ComposerTheme.corner, style: .continuous).fill(style.fill ?? ComposerTheme.raised))
    .overlay(RoundedRectangle(cornerRadius: ComposerTheme.corner, style: .continuous).strokeBorder(style.stroke ?? ComposerTheme.stroke))
    .shadow(color: .black.opacity(0.06), radius: 6, y: 1)
    .dropDestination(for: URL.self) { urls, _ in
      guard !urls.isEmpty else { return false }
      Task { _ = await model.handleDrop(urls: urls) }
      return true
    }
  }

  @ViewBuilder private var editor: some View {
    if model.isApprovalState {
      Text(model.placeholder).font(.system(size: style.fontSize)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 12)
    } else {
      ComposerEditorView(
        model: model, sync: model.editorSync, focusRequest: model.focusRequest, placeholder: model.placeholder, isDisabled: model.isEditorDisabled,
        richTextEnabled: model.richTextEnabled, chipSignature: chipSignature, style: style, onChipActivate: onChipActivate)
        .padding(.horizontal, 12).padding(.top, 8)
        .opacity(model.isEditorDisabled ? 0.55 : 1)
    }
  }

  private var chipSignature: Int {
    var hasher = Hasher()
    hasher.combine(model.activeAttachments)
    hasher.combine(model.uploads)
    hasher.combine(model.draft.records)
    hasher.combine(model.selectedEntry?.instanceId)
    return hasher.finalize()
  }

  // MARK: Footer

  @ViewBuilder private var footer: some View {
    if let approval = model.activeApproval {
      HStack { Spacer(); ComposerApprovalActions(model: model, approval: approval) }
    } else {
      HStack(spacing: 4) {
        if let prompt = model.activeUserInput {
          Spacer()
          ComposerUserInputActions(model: model, prompt: prompt)
        } else {
          controls
          Spacer(minLength: 8)
          trailing
        }
      }
    }
  }

  private var controls: some View {
    HStack(spacing: 2) {
      Button { model.isModelPickerOpen.toggle() } label: {
        FooterLabel(symbol: "cpu", text: model.selectedModelDisplayName, iconOnly: isCompact)
      }
      .help("Choose a model").accessibilityLabel("Model: \(model.selectedModelDisplayName)")
      .popover(isPresented: Bindable(model).isModelPickerOpen, arrowEdge: .top) { ModelPickerPanel(model: model) }
      if model.traits.hasAnyControls {
        Button { isTraitsOpen.toggle() } label: {
          FooterLabel(symbol: model.traitsDisplay.showFastModeIcon ? "bolt.fill" : "slider.horizontal.3", text: model.traitsDisplay.label, iconOnly: isCompact)
        }
        .help("Model options").accessibilityLabel("Model options: \(model.traitsDisplay.label)")
        .popover(isPresented: $isTraitsOpen, arrowEdge: .top) { TraitsPanel(model: model) }
      }
      if model.planModeUiEnabled {
        divider
        Button { model.toggleInteractionMode() } label: {
          FooterLabel(symbol: model.interactionMode == .plan ? "list.bullet.clipboard" : "bubble.left", text: model.interactionMode == .plan ? "Plan" : "Chat", iconOnly: isCompact)
        }
        .help(model.interactionMode == .plan ? "Switch to chat mode" : "Switch to plan mode")
        .accessibilityLabel("Interaction mode: \(model.interactionMode == .plan ? "Plan" : "Chat")")
      }
      divider
      Menu {
        ForEach(Self.runtimeModes, id: \.mode) { entry in
          Button { model.setRuntimeMode(entry.mode) } label: { Label(entry.title, systemImage: model.runtimeMode == entry.mode ? "checkmark" : entry.symbol) }
        }
      } label: {
        let current = Self.runtimeModes.first { $0.mode == model.runtimeMode } ?? Self.runtimeModes[0]
        FooterLabel(symbol: current.symbol, text: current.title, iconOnly: isCompact).foregroundStyle(.secondary)
      }
      .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
      .help("Access mode").accessibilityLabel("Access mode")
    }
    .buttonStyle(FooterButtonStyle())
  }

  private var divider: some View { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 14).padding(.horizontal, 4) }

  private var trailing: some View {
    HStack(spacing: 8) {
      if let usage = model.thread.contextWindow { ContextMeter(snapshot: usage) }
      if !model.stashEntries.isEmpty || model.canStash {
        Button { Task { await model.stashShortcut() } } label: {
          Image(systemName: model.stashEntries.isEmpty ? "tray.and.arrow.down" : "tray.full").overlay(alignment: .topTrailing) {
            if !model.stashEntries.isEmpty { Text("\(model.stashEntries.count)").font(.system(size: 8, weight: .bold)).padding(2).background(Circle().fill(Color.accentColor)).foregroundStyle(.white).offset(x: 6, y: -5) }
          }
        }
        .buttonStyle(FooterButtonStyle()).help("Stash this prompt (⌘S)").accessibilityLabel("Stash, \(model.stashEntries.count) saved")
        .popover(isPresented: Bindable(model).isStashMenuOpen, arrowEdge: .top) { StashPanel(model: model) }
      }
      if model.canAttachFiles {
        Button { isFileImporterPresented = true } label: { Image(systemName: "paperclip") }
          .buttonStyle(FooterButtonStyle()).help("Attach files").accessibilityLabel("Attach files")
      }
      primaryButtons
    }
  }

  @ViewBuilder private var primaryButtons: some View {
    switch model.primaryAction {
    case .stop: stopButton
    case .stopAndQueue:
      stopButton
      sendButton(symbol: model.sendsAsQueue ? "text.append" : "arrow.up", help: model.sendsAsQueue ? "Queue message" : "Send now")
    default: sendButton(symbol: "arrow.up", help: "Send message")
    }
  }

  private var stopButton: some View {
    Button { Task { await model.interrupt() } } label: {
      Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white).frame(width: 28, height: 28).background(Circle().fill(Color.primary.opacity(0.8)))
    }
    .buttonStyle(.plain).help("Stop").accessibilityLabel("Stop generating")
  }

  private func sendButton(symbol: String, help: String) -> some View {
    let enabled = model.canSend
    return Button { Task { await model.submit() } } label: {
      Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(.white).frame(width: 28, height: 28)
        .background(Circle().fill(enabled ? Color.accentColor : Color.primary.opacity(0.25)))
    }
    .buttonStyle(.plain).disabled(!enabled).help(model.sendDisabledReason ?? help).accessibilityLabel(help)
  }

  static let runtimeModes: [(mode: RuntimeMode, title: String, symbol: String)] = [
    (.approvalRequired, "Supervised", "hand.raised"), (.autoAcceptEdits, "Auto-accept edits", "pencil.and.list.clipboard"), (.auto, "Auto", "wand.and.sparkles"), (.fullAccess, "Full access", "lock.open"),
  ]
}

private struct FooterLabel: View {
  let symbol: String
  let text: String
  let iconOnly: Bool

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: symbol).font(.system(size: 12))
      if !iconOnly { Text(text).font(.system(size: 12.5)).lineLimit(1) }
    }
    .padding(.horizontal, 7).padding(.vertical, 4)
    .contentShape(Rectangle())
  }
}

private struct FooterButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.foregroundStyle(.secondary).padding(2).background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(configuration.isPressed ? 0.1 : 0)))
  }
}
