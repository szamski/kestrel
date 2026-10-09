import AppKit
import SwiftUI
import T3Contracts
import T3Theme

/// One typography row: the family (a picker over the installed fonts, or any comma-separated list), the size, and a sample in
/// the chosen font.
struct FontFamilyRow: View {
  @Environment(SettingsModel.self) private var model
  let id: String
  let title: String
  let help: String
  let family: WritableKeyPath<ClientSettingsSchema, String>
  let size: WritableKeyPath<ClientSettingsSchema, Int>
  let sizes: ClosedRange<Int>
  let monospaced: Bool
  @State private var picking = false

  private let dc = ClientSettingsSchema()

  var body: some View {
    let value = model.client[keyPath: family]
    let points = model.client[keyPath: size]
    let resolved = AppearanceFonts.resolvedFamily(value)
    SettingRow(
      id: id, title: title, help: help, isDefault: value == dc[keyPath: family] && points == dc[keyPath: size],
      reset: { model.updateClient { $0[keyPath: family] = dc[keyPath: family]; $0[keyPath: size] = dc[keyPath: size] } },
      status: !value.trimmingCharacters(in: .whitespaces).isEmpty && resolved == nil ? "None of these fonts is installed; the default is used." : nil
    ) {
      VStack(alignment: .trailing, spacing: 6) {
        HStack(spacing: 8) {
          Button { picking = true } label: {
            HStack(spacing: 4) {
              Text(value.isEmpty ? "Default (\(AppearanceFonts.defaultLabel(monospaced: monospaced)))" : value).lineLimit(1)
              Spacer(minLength: 0)
              Image(systemName: "chevron.up.chevron.down").imageScale(.small)
            }.frame(width: 190)
          }
          .popover(isPresented: $picking, arrowEdge: .bottom) { FontFamilyPicker(selection: Binding(get: { model.client[keyPath: family] }, set: { new in model.updateClient { $0[keyPath: family] = new } }), monospaced: monospaced) }
          .accessibilityLabel("\(title) family")
          Text("\(points) px").monospacedDigit().frame(width: 46, alignment: .trailing)
          Stepper("\(title) size", value: Binding(get: { points }, set: { new in model.updateClient { $0[keyPath: size] = ThemeFonts.clamp(new, to: sizes) } }), in: sizes)
            .labelsHidden()
        }
        Text("The quick brown fox jumps over the lazy dog").lineLimit(1)
          .font(sample(resolved: resolved, points: points)).foregroundStyle(.secondary).frame(maxWidth: 360, alignment: .trailing)
      }
    }
  }

  private func sample(resolved: String?, points: Int) -> Font {
    let pointSize = CGFloat(points)
    if let resolved { return .custom(resolved, size: pointSize) }
    return monospaced ? .system(size: pointSize, design: .monospaced) : .system(size: pointSize)
  }
}

/// Installed families, searchable; code and terminal rows list only fixed-width ones. A free-text field below takes a
/// comma-separated list for fallbacks.
private struct FontFamilyPicker: View {
  @Binding var selection: String
  let monospaced: Bool
  @State private var query = ""
  @State private var families: [String] = []
  @State private var draft = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Search fonts", text: $query).textFieldStyle(.roundedBorder)
      List {
        Button { selection = "" } label: { row("Default (\(AppearanceFonts.defaultLabel(monospaced: monospaced)))", selected: selection.isEmpty) }.buttonStyle(.plain)
        ForEach(families.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { family in
          Button { selection = family } label: { row(family, selected: selection == family) }.buttonStyle(.plain)
        }
      }
      .frame(height: 260)
      HStack {
        TextField("Or a list: JetBrains Mono, Menlo", text: $draft).textFieldStyle(.roundedBorder).onSubmit { selection = draft }
        Button("Set") { selection = draft }.disabled(draft == selection)
      }
    }
    .padding(12).frame(width: 300)
    .task {
      draft = selection
      let all = AppearanceFonts.installedFamilies()
      families = monospaced ? all.filter(AppearanceFonts.isMonospaced) : all
    }
  }

  private func row(_ text: String, selected: Bool) -> some View {
    HStack {
      Text(text).lineLimit(1)
      Spacer()
      if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
    }.contentShape(Rectangle())
  }
}

/// A mock panel that slides in at the chosen duration when clicked, so the setting can be felt before it is used. It plays on
/// demand and when the duration changes, never in a loop.
struct PanelAnimationPreview: View {
  let durationMs: Int
  @State private var open = true

  var body: some View {
    Button {
      play()
    } label: {
      ZStack(alignment: .trailing) {
        RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5))
        RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.55)).frame(width: 34).padding(3).offset(x: open ? 0 : 40)
      }
      .frame(width: 84, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain)
    .help("Click to preview the panel animation")
    .accessibilityLabel("Preview panel animation")
    .onChange(of: durationMs) { play() }
  }

  private func play() {
    let animation: Animation? = durationMs > 0 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeInOut(duration: Double(durationMs) / 1000) : nil
    withAnimation(animation) { open.toggle() }
  }
}
