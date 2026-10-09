import SwiftUI
import T3ClientRuntime

struct AddEnvironmentSheet: View {
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss

  private enum Mode: String, CaseIterable, Identifiable {
    case link = "Pairing link"
    case code = "Host and code"
    var id: String { rawValue }
  }

  @State private var mode = Mode.link
  @State private var link = ""
  @State private var host = ""
  @State private var code = ""
  @State private var adding = false
  @State private var failure: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Add environment").font(.headline)
      Text("Connect to a T3 Code server. Run `npx t3` or open Settings \u{203A} Connections in another client to get a pairing link.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Picker("Method", selection: $mode) {
        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      switch mode {
      case .link:
        TextField("Pairing link", text: $link, prompt: Text("https://host/pair#token=\u{2026}"))
          .autocorrectionDisabled()
          .onSubmit(add)
      case .code:
        TextField("Host", text: $host, prompt: Text("192.168.1.20:13773"))
          .autocorrectionDisabled()
        TextField("Pairing code", text: $code)
          .autocorrectionDisabled()
          .onSubmit(add)
      }
      if let failure {
        Label(failure, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        if adding { ProgressView().controlSize(.small) }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Add", action: add)
          .keyboardShortcut(.defaultAction)
          .disabled(!canAdd)
      }
    }
    .textFieldStyle(.roundedBorder)
    .padding(20)
    .frame(width: 420)
    .disabled(adding)
    .onAppear {
      guard let prefilled = app.addEnvironmentHost else { return }
      app.addEnvironmentHost = nil
      mode = .code
      host = prefilled
    }
  }

  private var canAdd: Bool {
    switch mode {
    case .link: !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .code: !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  private func add() {
    guard canAdd, !adding else { return }
    adding = true
    failure = nil
    let runtime = app.runtime
    let (mode, link, host, code) = (mode, link.trimmingCharacters(in: .whitespacesAndNewlines), host.trimmingCharacters(in: .whitespacesAndNewlines), code.trimmingCharacters(in: .whitespacesAndNewlines))
    Task {
      do {
        switch mode {
        case .link: try await runtime.addEnvironment(pairingURL: link)
        case .code: try await runtime.addEnvironment(host: host, pairingCode: code)
        }
        dismiss()
      } catch {
        failure = AppModel.describe(error)
        adding = false
      }
    }
  }
}
