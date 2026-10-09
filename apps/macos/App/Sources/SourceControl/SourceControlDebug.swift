#if DEBUG
import Foundation

/// Debug-only: `-T3GitDebug <file>` makes the app run each new line of the file as a source control step
/// (`commitdialog`, `publishdialog`, `branchpicker`, `workspacemenu`), for verification runs that cannot post real clicks to menus.
enum SourceControlDebug {
  @MainActor static func run(_ store: SourceControlStore) async {
    guard let path = UserDefaults.standard.string(forKey: "T3GitDebug"), !path.isEmpty else { return }
    FileManager.default.createFile(atPath: path, contents: nil)
    var done = 0
    while !Task.isCancelled {
      let lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
      while done < lines.count {
        let line = lines[done]
        done += 1
        switch line {
        case "commitdialog": if let info = store.activeInfo { store.dialog = .commit(info.context) }
        case "publishdialog": if let info = store.activeInfo { store.dialog = .publish(info.context) }
        case "branchpicker": store.branchPickerRequest += 1
        case "workspacemenu": store.workspaceMenuRequest += 1
        default: break
        }
      }
      try? await Task.sleep(for: .milliseconds(250))
    }
  }
}
#endif
