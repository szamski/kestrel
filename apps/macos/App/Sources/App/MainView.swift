import SwiftUI

/// Sidebar | reading window, with the app-level sheets, alerts and confirmations.
struct MainView: View {
  @Environment(AppModel.self) private var app
  @State private var rightPanel = RightPanelStore()

  var body: some View {
    @Bindable var model = app
    NavigationSplitView {
      SidebarView()
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 440)
    } detail: {
      if app.runtime.environments.isEmpty && app.selection == nil {
        FirstRunView()
      } else {
        ReadingWindow()
      }
    }
    .frame(minWidth: 760, minHeight: 480)
    .environment(rightPanel)
    #if DEBUG
    .task { DiffDebugSnapshot.runIfRequested(app: app) }
    #endif
    .sheet(item: $model.sheet) { sheet in
      switch sheet {
      case .addEnvironment: AddEnvironmentSheet()
      case .snooze(let key): SnoozeSheet(key: key)
      case .rename(let key): RenameThreadSheet(key: key)
      }
    }
    .alert("Something went wrong", isPresented: Binding(get: { app.errorMessage != nil }, set: { if !$0 { app.errorMessage = nil } })) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(app.errorMessage ?? "")
    }
    .confirmationDialog(
      app.confirmation?.title ?? "", isPresented: Binding(get: { app.confirmation != nil }, set: { if !$0 { app.confirmation = nil } }),
      titleVisibility: .visible
    ) {
      if let request = app.confirmation {
        Button(request.confirmTitle, role: .destructive) { Task { await request.perform() } }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(app.confirmation?.message ?? "")
    }
  }
}
