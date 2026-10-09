import SwiftUI
import T3ClientRuntime
import T3Contracts

/// Usage providers: quota sources beyond the provider CLIs. A CLIProxyAPI hub reports the windows of every account it pools;
/// on a Mac, Cursor's own account usage can be read from the login keychain.
struct UsageProvidersSection: View {
  let controller: ProvidersController
  @State private var removing: (id: String, label: String)?

  var body: some View {
    let settings = controller.settings
    let sources = settings.usageLimitSources.sorted { $0.key < $1.key }
    Section {
      if controller.isMac {
        SettingRow(
          id: "cursor-keychain-usage", title: "Cursor account usage",
          help: "Read your existing Cursor CLI login from macOS Keychain to show account history and monthly limits. macOS may ask you to allow access."
        ) {
          Toggle("Cursor account usage", isOn: Binding(get: { settings.cursorKeychainUsageEnabled }, set: { controller.setCursorUsage($0) }))
            .labelsHidden().toggleStyle(.switch).disabled(controller.cursorUsageBusy)
        }
      }
      if sources.isEmpty {
        Text("No hubs configured.").foregroundStyle(.secondary)
      }
      ForEach(sources, id: \.key) { id, source in
        let label = source.label?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? source.url
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 2) {
            Text(label)
            Text("CLI Proxy\(source.enabled ? "" : " · Disabled")\(label != source.url ? " · \(source.url)" : "")")
              .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
          }
          Spacer()
          Button("Remove") { removing = (id, label) }
        }
      }
    } header: {
      HStack {
        Text("Usage providers").id("usage-providers")
        Spacer()
        Button("Add hub", systemImage: "plus") { controller.showAddHub = true }.buttonStyle(.borderless).font(.callout)
      }
    }
    .confirmationDialog(
      "Remove \(removing?.label ?? "hub")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible
    ) {
      Button("Remove hub", role: .destructive) {
        if let removing { controller.save(ProviderUsageSources.removePatch(id: removing.id), failure: "Hub not removed.") }
        removing = nil
      }
    } message: {
      Text("The hub's management key is deleted from this server. Its accounts leave the Limits view; the hub itself is untouched. Add it again with the URL and key to bring them back.")
    }
  }
}

/// Adds a CLIProxyAPI hub. The management key is sent once and kept on that server; settings only carry a redaction marker afterwards.
struct AddUsageLimitSourceSheet: View {
  let controller: ProvidersController
  @Environment(\.dismiss) private var dismiss
  @State private var url = ""
  @State private var key = ""
  @State private var label = ""

  private var canSave: Bool { !url.trimmingCharacters(in: .whitespaces).isEmpty && !key.trimmingCharacters(in: .whitespaces).isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Add a CLIProxyAPI hub").font(.title3.bold())
      Text("Show the quota of every account the hub pools, next to the providers on \(controller.environmentLabel). The key stays on that server.")
        .foregroundStyle(.secondary)
      Form {
        TextField("Hub URL", text: $url, prompt: Text("https://hub.example.ts.net:8318")).autocorrectionDisabled()
        SecureField("Management key", text: $key)
        TextField("Label (optional)", text: $label, prompt: Text("Defaults to the hub's host name"))
      }
      .formStyle(.grouped).scrollDisabled(true)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Add hub") {
          controller.save(ProviderUsageSources.addPatch(label: label, url: url, managementKey: key), failure: "Hub not added.")
          dismiss()
        }
        .keyboardShortcut(.defaultAction).disabled(!canSave)
      }
    }
    .padding(20).frame(width: 480)
  }
}
