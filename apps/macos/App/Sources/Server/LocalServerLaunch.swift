import Foundation

/// What to run for the app-managed local server and where its data lives.
///
/// Debug runs the server from this repo's source with a dev home that is never `~/.t3`; Release runs the
/// bundled self-contained `t3` (Contents/Resources/t3, see apps/macos/scripts/bundle-server.sh) on the
/// same home Electron uses (`$T3CODE_HOME` or `~/.t3`).
struct LocalServerLaunch: Sendable {
  var executable: URL
  var arguments: [String]
  var workingDirectory: URL
  /// T3 home; the server keeps its state in `home/userdata`.
  var home: URL
  var firstPort: Int
  /// A substring of the server's command line, to recognise our own process in `ps`.
  var marker: String

  var stateDirectory: URL { home.appending(path: "userdata", directoryHint: .isDirectory) }
  /// Written by a live server next to its database; how a second server on this home is detected.
  var runtimeStateURL: URL { stateDirectory.appending(path: "server-runtime.json") }

  struct Failure: Error, LocalizedError {
    var errorDescription: String?
  }

  /// The T3 home the local server uses, known without starting it (the `t3 app` socket address derives from `<home>/userdata`).
  static func homeDirectory(dataDirectory: URL) -> URL {
    #if DEBUG
    dataDirectory.appending(path: "server-home", directoryHint: .isDirectory)
    #else
    let configured = ProcessInfo.processInfo.environment["T3CODE_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return configured.isEmpty
      ? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".t3", directoryHint: .isDirectory)
      : URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
    #endif
  }

  /// `environment` is the captured login-shell environment (its PATH finds node in Debug).
  static func resolve(environment: [String: String], dataDirectory: URL) throws -> LocalServerLaunch {
    let userHome = FileManager.default.homeDirectoryForCurrentUser
    #if DEBUG
    guard let root = Bundle.main.object(forInfoDictionaryKey: "T3RepoRoot") as? String, !root.isEmpty else {
      throw Failure(errorDescription: "The Debug build does not know the repository root (T3_REPO_ROOT in Debug.xcconfig).")
    }
    let repo = URL(fileURLWithPath: root).standardizedFileURL
    let entry = repo.appending(path: "apps/server/src/bin.ts")
    guard FileManager.default.fileExists(atPath: entry.path) else {
      throw Failure(errorDescription: "The server source was not found at \(entry.path).")
    }
    // cwd is the server's workspace boundary for review/diff RPCs: the home directory, as in Release (not the repo's apps/server).
    let node = try findNode(path: environment["PATH"] ?? "")
    let home = homeDirectory(dataDirectory: dataDirectory)
    // Data safety: a Debug build must never run a server on the live install.
    guard home.standardizedFileURL.path != userHome.appending(path: ".t3").path else {
      throw Failure(errorDescription: "Refusing to run the Debug server on ~/.t3.")
    }
    return LocalServerLaunch(
      executable: node, arguments: [entry.path, "--bootstrap-fd", "0"], workingDirectory: userHome,
      home: home, firstPort: 13900, marker: entry.path)
    #else
    let executable = Bundle.main.resourceURL!.appending(path: "t3/t3")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw Failure(errorDescription: "This build has no bundled server. Run apps/macos/scripts/bundle-server.sh on the app.")
    }
    let home = homeDirectory(dataDirectory: dataDirectory)
    return LocalServerLaunch(
      executable: executable, arguments: ["--bootstrap-fd", "0"], workingDirectory: userHome, home: home, firstPort: 3773,
      marker: executable.path)
    #endif
  }

  #if DEBUG
  /// The repo's Node first (vite-plus provides node 24, which runs the TypeScript source directly), then the login-shell PATH.
  private static func findNode(path: String) throws -> URL {
    let userHome = FileManager.default.homeDirectoryForCurrentUser
    var candidates = [userHome.appending(path: ".local/share/vite-plus/bin/node").path]
    candidates += path.split(separator: ":").map { "\($0)/node" }
    candidates += ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
    guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
      throw Failure(errorDescription: "Node was not found (looked in ~/.local/share/vite-plus/bin and the login-shell PATH).")
    }
    return URL(fileURLWithPath: found)
  }
  #endif
}
