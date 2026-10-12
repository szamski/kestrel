import CryptoKit
import Foundation

/// The `t3 app <path>` activation protocol: packages/contracts/src/desktopAppActivation.ts and packages/shared/src/desktopAppControl.ts.
/// The CLI connects to a local Unix socket, writes one JSON line and reads one JSON line back.
public enum DesktopAppActivation {
  public static let maxRequestBytes = 64 * 1024
  /// How long a connection may take to deliver its request line.
  public static let readTimeout: TimeInterval = 5
  /// How long a request may wait for the app, ready or not, before it answers `request-timeout`.
  public static let requestTimeout: TimeInterval = 15

  /// `resolveDesktopAppControlAddress` for macOS: `<tmpdir>/t3code-<uid>/<sha256(stateDir)[0..12] as hex>.sock`. The state directory is the
  /// server's `<t3Home>/userdata`; hashing it keeps custom homes under the 104-byte socket path limit. `tempDir` is Node's `os.tmpdir()`
  /// (`$TMPDIR` without its trailing slash), so the CLI and this app agree as long as they run for the same user.
  public static func controlAddress(stateDir: String, tempDir: String, userId: UInt32) -> (directory: String, address: String) {
    let hash = SHA256.hash(data: Data(stateDir.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    var base = tempDir
    while base.count > 1, base.hasSuffix("/") { base.removeLast() }
    let directory = base + "/t3code-\(userId)"
    return (directory, directory + "/\(hash).sock")
  }

  public struct Request: Sendable, Equatable {
    public var requestId: String
    public var workspaceRoot: String
    public var platform: String
  }

  public enum ErrorCode: String, Sendable {
    case invalidRequest = "invalid-request"
    case rendererUnavailable = "renderer-unavailable"
    case environmentUnavailable = "environment-unavailable"
    case platformMismatch = "platform-mismatch"
    case projectCreateFailed = "project-create-failed"
    case threadOpenFailed = "thread-open-failed"
    case requestTimeout = "request-timeout"
    case internalError = "internal-error"
  }

  public enum Parsed: Sendable, Equatable {
    case request(Request)
    /// `requestId` is the one the client sent when it could be read, else `invalid-request`, as the desktop answers.
    case invalid(requestId: String, message: String)
  }

  /// `DesktopAppActivationRequest` decoded the way the desktop does it: version 1, a trimmed non-empty `requestId` and `workspaceRoot`,
  /// type `open-workspace`, a known platform.
  public static func parse(line: Data) -> Parsed {
    guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
      return .invalid(requestId: "invalid-request", message: "The desktop app request is not valid JSON.")
    }
    let sent = (object["requestId"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    let failed = Parsed.invalid(requestId: sent ?? "invalid-request", message: "The desktop app request is invalid.")
    guard object["version"] as? Int == 1, let requestId = sent, object["type"] as? String == "open-workspace",
      let root = (object["workspaceRoot"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty,
      let platform = object["platform"] as? String, ["darwin", "linux", "win32"].contains(platform)
    else { return failed }
    return .request(Request(requestId: requestId, workspaceRoot: root, platform: platform))
  }

  public static func success(requestId: String, projectId: String, threadId: String) -> Data {
    line(["version": 1, "requestId": requestId, "ok": true, "projectId": projectId, "threadId": threadId])
  }

  public static func failure(requestId: String, _ code: ErrorCode, _ message: String) -> Data {
    line(["version": 1, "requestId": requestId, "ok": false, "code": code.rawValue, "message": message])
  }

  private static func line(_ object: [String: Any]) -> Data {
    var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    data.append(0x0A)
    return data
  }
}
