import SwiftUI
import T3ClientRuntime
import T3Contracts

/// Add provider instance: driver, identity (label, id, accent), then the driver's own settings.
struct AddProviderInstanceSheet: View {
  let controller: ProvidersController
  @Environment(\.dismiss) private var dismiss

  private static let steps = ["Driver", "Identity", "Config"]
  private static let swatches = ["#2563eb", "#16a34a", "#ea580c", "#dc2626", "#7c3aed", "#0891b2"]
  /// Announced drivers that cannot be added yet.
  private static let comingSoon = ["GitHub Copilot", "Gemini"]

  @State private var step = 0
  @State private var driverSlug = "codex"
  @State private var label = ""
  @State private var idOverride: String?
  @State private var accent: String?
  @State private var configs: [String: JSONValue] = [:]
  @State private var attempted = false

  private var driver: ProviderDriver { ProviderCatalog.driver(driverSlug) ?? ProviderCatalog.drivers[0] }
  private var instanceId: String { idOverride ?? ProviderInstances.deriveInstanceId(driver: driverSlug, label: label) }
  private var idError: String? { ProviderInstances.idError(instanceId, existing: Set(controller.settings.providerInstances.keys)) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Add provider instance").font(.title3.bold())
      Text("Configure an additional provider instance on \(controller.environmentLabel), for example a second Codex install pointed at a different workspace.")
        .foregroundStyle(.secondary).padding(.top, 2).padding(.bottom, 10)
      Picker("Step", selection: Binding(get: { step }, set: { go($0) })) {
        ForEach(Self.steps.indices, id: \.self) { Text(Self.steps[$0]).tag($0) }
      }
      .pickerStyle(.segmented).labelsHidden().padding(.bottom, 12)
      Group {
        switch step {
        case 0: driverStep
        case 1: identityStep
        default: configStep
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .frame(minHeight: 250, alignment: .top)
      HStack {
        Button(step == 0 ? "Cancel" : "Back", role: step == 0 ? .cancel : nil) { if step == 0 { dismiss() } else { step -= 1 } }
        Spacer()
        if step < Self.steps.count - 1 {
          Button("Next") { go(step + 1) }.keyboardShortcut(.defaultAction)
        } else {
          Button("Add instance", action: save).keyboardShortcut(.defaultAction)
        }
      }
      .padding(.top, 12)
    }
    .padding(20)
    .frame(width: 560)
  }

  // MARK: Steps

  private var driverStep: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(ProviderCatalog.drivers) { option in
        Button { driverSlug = option.slug } label: {
          HStack {
            ProviderGlyph(name: option.label, accent: nil, size: 22)
            Text(option.label).fontWeight(.medium)
            if let badge = option.badge { Text(badge).font(.caption).padding(.horizontal, 5).padding(.vertical, 1).background(.orange.opacity(0.2), in: Capsule()) }
            Spacer()
            if option.slug == driverSlug { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
          }
          .padding(8).contentShape(Rectangle())
          .background(option.slug == driverSlug ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain).accessibilityAddTraits(option.slug == driverSlug ? .isSelected : [])
      }
      Text("Coming soon: \(Self.comingSoon.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
    }
  }

  private var identityStep: some View {
    let showError = attempted && idError != nil
    return VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Label").font(.callout.weight(.medium))
        TextField("Label", text: $label, prompt: Text("e.g. Work")).labelsHidden().textFieldStyle(.roundedBorder)
        Text("Shown in the provider list. Optional.").font(.caption).foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text("Instance ID").font(.callout.weight(.medium))
        TextField("Instance ID", text: Binding(get: { instanceId }, set: { idOverride = $0 }), prompt: Text("\(driverSlug)_work"))
          .labelsHidden().textFieldStyle(.roundedBorder).autocorrectionDisabled()
        if showError, let idError {
          Text(idError).font(.caption).foregroundStyle(.red)
        } else {
          Text("Routing key used by threads and sessions. Letters, digits, '-', or '_'.").font(.caption).foregroundStyle(.secondary)
        }
      }
      VStack(alignment: .leading, spacing: 3) {
        Text("Accent color").font(.callout.weight(.medium))
        HStack(spacing: 8) {
          AccentColorControl(hex: accent) { accent = $0 }
          ForEach(Self.swatches, id: \.self) { swatch in
            Button { accent = swatch } label: {
              Circle().fill(Color(hex: swatch) ?? .gray).frame(width: 18, height: 18)
                .overlay(Circle().stroke(Color.primary, lineWidth: accent?.lowercased() == swatch ? 2 : 0).padding(-3))
            }
            .buttonStyle(.plain).accessibilityLabel("Use \(swatch) accent")
          }
        }
        Text("Optional marker shown in the picker.").font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var configStep: some View {
    VStack(alignment: .leading, spacing: 12) {
      if driver.fields(for: configs[driverSlug]).isEmpty {
        Text("This driver has no required configuration. You can add the instance now.").foregroundStyle(.secondary)
      }
      ForEach(driver.fields(for: configs[driverSlug])) { field in
        ProviderFieldRow(idPrefix: "add-\(driverSlug)", field: field, config: configs[driverSlug], onChange: { configs[driverSlug] = $0 }, inSheet: true)
      }
    }
  }

  // MARK: Navigation and save

  /// Moving past Identity needs a valid instance id; a blocked jump lands on Identity so the error is visible.
  private func go(_ requested: Int) {
    let target = max(0, min(Self.steps.count - 1, requested))
    if step <= 1, target > 1, idError != nil {
      attempted = true
      step = 1
    } else {
      step = target
    }
  }

  private func save() {
    attempted = true
    guard idError == nil else {
      step = 1
      return
    }
    let name = label.trimmingCharacters(in: .whitespaces)
    let instance = ProviderInstanceConfig(
      driver: ProviderDriverKind(driverSlug), displayName: name.isEmpty ? nil : name, accentColor: ProviderInstances.normalizedAccent(accent), enabled: true,
      config: configs[driverSlug])
    controller.save(ProviderInstances.addPatch(settings: controller.settings, instanceId: instanceId, instance: instance), failure: "Provider not added.")
    controller.selectedId = instanceId
    dismiss()
  }
}
