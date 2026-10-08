import AppKit
import SwiftUI
import T3Contracts

/// The `@`, `/`, `$` and `#` menu. It floats above the composer and never takes key focus, so the
/// caret keeps blinking in the editor; arrows and Return reach it through the model.
struct ComposerMenuView: View {
  let model: ComposerModel

  var body: some View {
    VStack(spacing: 0) {
      if model.menuItems.isEmpty {
        HStack(spacing: 8) {
          if model.menuIsLoading { ProgressView().controlSize(.small) }
          Text(model.menuIsLoading ? "Searching…" : emptyText).font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: 1) {
              ForEach(model.menuItems) { item in
                MenuRow(item: item, isHighlighted: item.id == model.menuHighlightedId)
                  .id(item.id)
                  .onTapGesture { model.pick(item) }
                  .onHover { if $0 { model.highlightMenuItem(item.id) } }
              }
            }
            .padding(6)
          }
          .frame(maxHeight: 264)
          .onChange(of: model.menuHighlightedId) { _, id in if let id { proxy.scrollTo(id) } }
        }
      }
    }
    .frame(width: 420)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ComposerTheme.stroke))
    .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Suggestions")
  }

  private var emptyText: String {
    switch model.trigger?.kind {
    case .slashCommand?, .slashModel?: "No matching commands"
    case .skill?: "No matching skills"
    case .pullRequest?: "No matching pull requests"
    default: "No matching files"
    }
  }
}

private struct MenuRow: View {
  let item: ComposerMenuItem
  let isHighlighted: Bool

  private var symbol: String {
    switch item {
    case .path(_, let kind, _, _): kind == .directory ? "folder" : "doc.text"
    case .slash(let slash):
      switch slash {
      case .builtIn: "slash.circle"
      case .provider: "terminal"
      case .skill: "sparkles"
      }
    case .skill: "sparkles"
    case .pullRequest: "arrow.triangle.pull"
    }
  }

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
      Text(item.label).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
      Text(item.itemDescription).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isHighlighted ? Color.accentColor.opacity(0.18) : .clear))
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isHighlighted ? .isSelected : [])
  }
}

/// The model picker: search, provider sections, favorites, ⌘1–9 to jump.
struct ModelPickerPanel: View {
  let model: ComposerModel
  @State private var query = ""
  @State private var highlighted: String?
  @FocusState private var searchFocused: Bool

  var body: some View {
    let rows = model.modelPickerRows(query: query)
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search models", text: $query).textFieldStyle(.plain).focused($searchFocused).accessibilityLabel("Search models")
          .onSubmit { if let row = rows.first(where: { $0.id == (highlighted ?? rows.first?.id) }) { choose(row) } }
      }
      .padding(.horizontal, 12).padding(.vertical, 9)
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 1) {
            if rows.isEmpty { Text("No models match").font(.system(size: 12.5)).foregroundStyle(.secondary).padding(12) }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
              if index == 0 || rows[index - 1].instanceId != row.instanceId || (query.isEmpty && rows[index - 1].isFavorite != row.isFavorite) {
                header(for: row, favorites: query.isEmpty && row.isFavorite)
              }
              ModelRow(row: row, isHighlighted: row.id == (highlighted ?? rows.first?.id), choose: { choose(row) }, toggleFavorite: { model.toggleFavorite(row) })
                .id(row.id)
                .onHover { if $0 { highlighted = row.id } }
            }
          }
          .padding(6)
        }
        .frame(maxHeight: 320)
        .onChange(of: highlighted) { _, id in if let id { proxy.scrollTo(id) } }
      }
    }
    .frame(width: 380)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(ComposerTheme.stroke))
    .onAppear { searchFocused = true }
    .onKeyPress(.downArrow) { move(rows, 1); return .handled }
    .onKeyPress(.upArrow) { move(rows, -1); return .handled }
    .onExitCommand { model.isModelPickerOpen = false }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Model picker")
  }

  private func header(for row: ModelPickerRow, favorites: Bool) -> some View {
    HStack(spacing: 6) {
      if favorites { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow) } else {
        Circle().fill(Color(hex: row.accentColor) ?? .secondary).frame(width: 7, height: 7)
      }
      Text(favorites ? "Favorites" : row.providerName).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }
    .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 3)
    .accessibilityAddTraits(.isHeader)
  }

  private func move(_ rows: [ModelPickerRow], _ delta: Int) {
    guard !rows.isEmpty else { return }
    let current = rows.firstIndex { $0.id == (highlighted ?? rows[0].id) } ?? 0
    highlighted = rows[(current + delta + rows.count) % rows.count].id
  }

  private func choose(_ row: ModelPickerRow) {
    guard row.disabledReason == nil else { return }
    model.selectModel(instanceId: row.instanceId, slug: row.option.slug)
    model.isModelPickerOpen = false
  }
}

private struct ModelRow: View {
  let row: ModelPickerRow
  let isHighlighted: Bool
  let choose: () -> Void
  let toggleFavorite: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).opacity(row.isSelected ? 1 : 0).frame(width: 12)
      Text(row.option.name).font(.system(size: 13)).lineLimit(1)
      if let badge = row.option.badge { Text(badge).font(.system(size: 10, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.primary.opacity(0.08))) }
      Spacer(minLength: 4)
      if let reason = row.disabledReason { Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(.secondary).help(reason) }
      Button(action: toggleFavorite) { Image(systemName: row.isFavorite ? "star.fill" : "star").foregroundStyle(row.isFavorite ? Color.yellow : Color.secondary) }
        .buttonStyle(.borderless).font(.system(size: 11)).accessibilityLabel(row.isFavorite ? "Remove from favorites" : "Add to favorites")
      if let index = row.jumpIndex { Text("⌘\(index + 1)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary) }
    }
    .padding(.horizontal, 8).padding(.vertical, 5)
    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isHighlighted ? Color.accentColor.opacity(0.16) : .clear))
    .opacity(row.disabledReason == nil ? 1 : 0.5)
    .contentShape(Rectangle())
    .onTapGesture(perform: choose)
    .background {
      if let index = row.jumpIndex, index < 9 {
        Button("", action: choose).keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command).opacity(0).accessibilityHidden(true)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(row.isSelected ? .isSelected : [])
    .accessibilityAction(named: "Choose", choose)
  }
}

extension Color {
  /// `#rrggbb` accent colors from provider snapshots.
  init?(hex: String?) {
    guard var value = hex?.trimmingCharacters(in: .whitespaces), value.hasPrefix("#") else { return nil }
    value.removeFirst()
    guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
    self.init(red: Double((number >> 16) & 0xFF) / 255, green: Double((number >> 8) & 0xFF) / 255, blue: Double(number & 0xFF) / 255)
  }
}

/// Reasoning effort, fast mode and the other options of the selected model.
struct TraitsPanel: View {
  let model: ComposerModel

  var body: some View {
    let traits = model.traits
    VStack(alignment: .leading, spacing: 12) {
      ForEach(traits.selectDescriptors, id: \.id) { descriptor in
        VStack(alignment: .leading, spacing: 4) {
          Text(descriptor.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
          Picker(descriptor.label, selection: Binding(get: { descriptor.currentValue ?? "" }, set: { model.selectTrait(descriptor, value: $0) })) {
            ForEach(descriptor.options, id: \.id) { option in Text(option.label).tag(option.id) }
          }
          .pickerStyle(.radioGroup).labelsHidden()
        }
      }
      ForEach(traits.booleanDescriptors, id: \.id) { descriptor in
        Toggle(descriptor.label, isOn: Binding(get: { descriptor.currentValue ?? false }, set: { model.setTrait(boolean: descriptor.id, isOn: $0) }))
      }
    }
    .padding(14)
    .frame(minWidth: 220, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Model options")
  }
}

/// Saved prompts: restore one, delete one.
struct StashPanel: View {
  let model: ComposerModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Stashed prompts").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
      ForEach(model.stashEntries) { entry in
        HStack(spacing: 8) {
          VStack(alignment: .leading, spacing: 1) {
            Text(entry.prompt.isEmpty ? "Attachments only" : entry.prompt.split(separator: "\n").first.map(String.init) ?? "").font(.system(size: 12.5)).lineLimit(1)
            if let date = ISO8601DateFormatter().date(from: entry.createdAt) {
              Text(date, style: .relative).font(.system(size: 11)).foregroundStyle(.secondary)
            }
          }
          Spacer(minLength: 8)
          Button { Task { await model.restoreStash(id: entry.id) } } label: { Image(systemName: "arrow.uturn.backward") }.help("Restore").accessibilityLabel("Restore stashed prompt")
          Button { Task { await model.deleteStash(id: entry.id) } } label: { Image(systemName: "trash") }.help("Delete").accessibilityLabel("Delete stashed prompt")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 6)
      }
    }
    .frame(width: 320)
    .padding(.bottom, 6)
  }
}

/// How full the context window is. A static ring: it only changes when a turn reports usage.
struct ContextMeter: View {
  let snapshot: ContextWindowSnapshot

  private var fraction: Double { min(1, max(0, (snapshot.usedPercentage ?? 0) / 100)) }
  private var summary: String {
    let used = Self.compact(snapshot.usedTokens)
    guard let max = snapshot.maxTokens else { return "\(used) tokens used" }
    return "\(Int((snapshot.usedPercentage ?? snapshot.usedTokens / max * 100).rounded()))% used (\(used) of \(Self.compact(max)) tokens)"
  }

  var body: some View {
    ZStack {
      Circle().stroke(Color.primary.opacity(0.14), lineWidth: 2.5)
      Circle().trim(from: 0, to: fraction).stroke(fraction > 0.9 ? Color.red : fraction > 0.75 ? Color.orange : Color.secondary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
    }
    .frame(width: 16, height: 16)
    .help(summary)
    .accessibilityElement()
    .accessibilityLabel("Context window")
    .accessibilityValue(summary)
  }

  static func compact(_ tokens: Double) -> String {
    tokens >= 1_000_000 ? String(format: "%.1fM", tokens / 1_000_000) : tokens >= 1000 ? "\(Int((tokens / 1000).rounded()))k" : "\(Int(tokens))"
  }
}
