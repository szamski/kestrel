import SwiftUI
import T3ClientRuntime
import T3Contracts

/// Advanced background activity: the shared policy plus the intervals and power switches that feed it. Only offered for one
/// environment, because the intervals are per-machine tuning.
struct BackgroundActivitySheet: View {
  @Environment(SettingsModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    let server = model.server
    let resolved = BackgroundActivityPolicy.resolved(server)
    VStack(alignment: .leading, spacing: 0) {
      Text("Background Activity").font(.title3.bold())
      Text("Tune the shared power policy and the background intervals that feed it.").foregroundStyle(.secondary).padding(.bottom, 12)
      Form {
        LabeledContent("Shared policy") {
          Picker("", selection: Binding(get: { resolved.profile }, set: { model.edit(BackgroundActivityPolicy.sharedPolicyPatch(server, profile: $0)) })) {
            Text("Balanced").tag(BackgroundActivityPolicy.Profile.balanced)
            Text("Performance").tag(BackgroundActivityPolicy.Profile.performance)
            Text("Battery saver").tag(BackgroundActivityPolicy.Profile.batterySaver)
          }.labelsHidden().pickerStyle(.menu).fixedSize()
        }
        interval("Git fetch interval", "Refresh remote branch status in the background.", resolved.automaticGitFetchInterval, minimum: 0) { $0.automaticGitFetchInterval = $1 }
        interval("Provider health interval", "Refresh provider availability, versions, auth state, and model metadata.", resolved.providerHealthRefreshInterval, minimum: 0) {
          $0.providerHealthRefreshInterval = $1
        }
        interval("Host power monitor", "Poll host power state while clients are active.", resolved.hostPowerMonitorActiveInterval, minimum: 5) {
          $0.hostPowerMonitorActiveInterval = $1
        }
        interval("Idle host monitor", "Poll host power state when no foreground client is active.", resolved.hostPowerMonitorIdleInterval, minimum: 5) {
          $0.hostPowerMonitorIdleInterval = $1
        }
        toggle("Pause when host is locked", resolved.pauseWhenHostLocked) { $0.pauseWhenHostLocked = $1 }
        toggle("Pause on host low power", resolved.pauseWhenHostLowPower) { $0.pauseWhenHostLowPower = $1 }
        toggle("Pause on client low power", resolved.pauseWhenClientLowPower) { $0.pauseWhenClientLowPower = $1 }
        toggle("Pause on battery", resolved.pauseWhenOnBattery) { $0.pauseWhenOnBattery = $1 }
      }
      .formStyle(.grouped)
      HStack {
        Spacer()
        Button("Reset all") { model.edit(BackgroundActivityPolicy.profilePatch(.balanced)) }
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
      .padding(.top, 8)
    }
    .padding(20)
    .frame(width: 520)
  }

  private func interval(
    _ title: String, _ help: String, _ millis: Double, minimum: Double, set: @escaping (inout BackgroundActivityPolicy.Resolved, Double) -> Void
  ) -> some View {
    LabeledContent {
      HStack(spacing: 6) {
        TextField(
          "", value: Binding(get: { (millis / 1000).rounded() }, set: { seconds in commit { set(&$0, max(minimum, seconds.rounded()) * 1000) } }), format: .number
        )
        .labelsHidden().multilineTextAlignment(.trailing).frame(width: 72).accessibilityLabel("\(title) in seconds")
        Text("seconds").foregroundStyle(.secondary)
      }
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(help).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func toggle(_ title: String, _ value: Bool, set: @escaping (inout BackgroundActivityPolicy.Resolved, Bool) -> Void) -> some View {
    Toggle(title, isOn: Binding(get: { value }, set: { on in commit { set(&$0, on) } }))
  }

  private func commit(_ edit: (inout BackgroundActivityPolicy.Resolved) -> Void) {
    model.edit(BackgroundActivityPolicy.overridePatch(model.server, edit: edit))
  }
}
