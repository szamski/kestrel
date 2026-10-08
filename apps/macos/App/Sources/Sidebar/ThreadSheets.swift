import SwiftUI
import T3ClientRuntime
import T3Contracts

struct RenameThreadSheet: View {
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  let key: ScopedThreadKey
  @State private var title = ""
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Rename thread").font(.headline)
      TextField("Title", text: $title)
        .focused($focused)
        .onSubmit(save)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Rename", action: save)
          .keyboardShortcut(.defaultAction)
          .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 360)
    .onAppear {
      title = app.runtime.threadShell(key)?.shell.title ?? ""
      focused = true
    }
  }

  private func save() {
    let next = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !next.isEmpty else { return }
    app.run { [runtime = app.runtime, key] in try await runtime.renameThread(key, title: next) }
    dismiss()
  }
}

/// "Pick a date": a graphical calendar plus time, and nothing in the past.
struct SnoozeSheet: View {
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  let key: ScopedThreadKey
  @State private var date = Calendar.current.date(byAdding: .hour, value: 3, to: .now) ?? .now

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Snooze until").font(.headline)
      DatePicker("Date", selection: $date, in: Date.now..., displayedComponents: [.date])
        .datePickerStyle(.graphical)
        .labelsHidden()
      DatePicker("Time", selection: $date, displayedComponents: [.hourAndMinute])
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Snooze", action: save)
          .keyboardShortcut(.defaultAction)
          .disabled(date <= .now)
      }
    }
    .padding(20)
    .frame(width: 300)
  }

  private func save() {
    let until = IsoDateTime(date: date)
    app.run { [runtime = app.runtime, key] in try await runtime.snoozeThread(key, until: until) }
    dismiss()
  }
}
