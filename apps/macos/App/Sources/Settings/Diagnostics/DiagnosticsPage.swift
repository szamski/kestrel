import SwiftUI
import T3ClientRuntime
import T3Contracts

/// Settings › Diagnostics. Like Providers, the page shows one environment, the scope bar's representative: its processes,
/// resource use, traces and logs live on that machine.
struct DiagnosticsPage: View {
  @Environment(SettingsModel.self) private var model

  var body: some View {
    if let target = model.targets.first {
      DiagnosticsContent(model: model, environmentId: target.environmentId).id(target.environmentId)
    } else {
      ContentUnavailableView("Connect an environment to see diagnostics.", systemImage: "waveform.path.ecg")
    }
  }
}

private struct DiagnosticsContent: View {
  @Environment(SettingsModel.self) private var model
  @State private var controller: DiagnosticsController

  init(model: SettingsModel, environmentId: EnvironmentId) {
    _controller = State(initialValue: DiagnosticsController(model: model, environmentId: environmentId))
  }

  var body: some View {
    Group {
      if let reason = controller.accessError {
        ContentUnavailableView("Diagnostics are not available", systemImage: "lock", description: Text(reason))
      } else {
        content
      }
    }
    .task { await controller.run() }
    #if DEBUG
    .task { await controller.debugShot() }
    #endif
    .confirmationDialog(
      "Send \(controller.pendingSignal?.name ?? "signal")?", isPresented: Binding(get: { controller.pendingSignal != nil }, set: { if !$0 { controller.pendingSignal = nil } }),
      titleVisibility: .visible, presenting: controller.pendingSignal
    ) { pending in
      Button("Send \(pending.name)", role: .destructive) { controller.confirm(pending) }
      Button("Cancel", role: .cancel) {}
    } message: { pending in
      Text(
        pending.signal == .SIGKILL
          ? "Send SIGKILL to \(pending.row.name) (process \(pending.row.pid))? The process cannot handle or refuse it."
          : "Send SIGINT to \(pending.row.name) (process \(pending.row.pid))? It may ask the process to stop what it is doing.")
    }
  }

  private var content: some View {
    ScrollViewReader { proxy in
      Form {
        Section {
          LabeledContent("Environment", value: controller.environmentLabel)
        } footer: {
          if model.environments.count > 1 { Text("Choose another environment in the bar above to inspect it.") }
        }
        MonitorSection(controller: controller).id("diagnostics-resources")
        HostSection(controller: controller)
        HealthSection(controller: controller)
        TimelineSection(controller: controller).id("diagnostics-timeline")
        ProcessTreeSection(controller: controller).id("diagnostics-process-tree")
        AttributionSection(controller: controller)
        LiveProcessesSection(controller: controller).id("diagnostics-processes")
        ProcessHistorySection(controller: controller)
        TraceSections(controller: controller).id("diagnostics-trace")
        ObservabilitySection(controller: controller).id("diagnostics-observability")
      }
      .formStyle(.grouped)
      .onChange(of: model.jump?.token) {
        guard let id = model.jump?.id else { return }
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(80))
          withAnimation { proxy.scrollTo(id, anchor: .top) }
        }
      }
    }
  }
}

/// The OTLP endpoints the server is asked to export to (`observability` settings). Empty turns an export off.
private struct ObservabilitySection: View {
  let controller: DiagnosticsController

  var body: some View {
    let observability = controller.settings.observability
    Section("OpenTelemetry export") {
      endpoint("diagnostics-otlp-traces", "Traces URL", observability.otlpTracesUrl) { ServerSettingsPatchObservability(otlpTracesUrl: $0) }
      endpoint("diagnostics-otlp-metrics", "Metrics URL", observability.otlpMetricsUrl) { ServerSettingsPatchObservability(otlpMetricsUrl: $0) }
      endpoint("diagnostics-otlp-logs", "Logs URL", observability.otlpLogsUrl) { ServerSettingsPatchObservability(otlpLogsUrl: $0) }
      PanelNote(text: "Where the server sends OpenTelemetry data. Leave a field empty to turn that export off. The server host applies these when it starts the server; Trace diagnostics shows what it exports now.")
    }
  }

  private func endpoint(_ id: String, _ title: String, _ value: String, patch: @escaping (String) -> ServerSettingsPatchObservability) -> some View {
    SettingRow(id: id, title: title, isDefault: value.isEmpty, reset: { save(patch("")) }) {
      CommitTextField(value: value, placeholder: "Off") { save(patch($0.trimmingCharacters(in: .whitespacesAndNewlines))) }
        .frame(width: 320)
    }
  }

  private func save(_ patch: ServerSettingsPatchObservability) {
    controller.save(ServerSettingsPatch(observability: patch), failure: "OpenTelemetry URL not saved.")
  }
}
