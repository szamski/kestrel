import Foundation
import T3Contracts

// Wire codec of `/api/preview-stream`, the server browser's viewer socket. Mirrors
// packages/client-runtime/src/preview/serverBrowserStream.ts (client) and
// apps/server/src/preview/ServerBrowserStream.ts (server): binary frames are complete JPEGs the client
// acknowledges one by one; everything else is a JSON text message.

public enum PreviewStream {
  public static let basePath = "/api/preview-stream"
  /// The tab does not exist (any more); the viewer stops.
  public static let goneCloseCode = 4404
  /// The server's host lacks something its browser needs; the close reason is a `HostSetup` JSON.
  public static let hostSetupCloseCode = 4503
  /// The text message that acknowledges one binary frame.
  public static let ack = #"{"type":"ack"}"#

  /// `…/ws?threadId&tabId&maxWidth&maxHeight[&interactive=false]&wsTicket=…`; `maxWidth`/`maxHeight` are the viewer's
  /// backing-store size in device pixels, the largest frame the server will send.
  public static func socketURL(
    httpBase: URL, threadId: String, tabId: String, maxWidth: Int, maxHeight: Int, interactive: Bool = true, ticket: String?
  ) -> URL {
    var items = [
      URLQueryItem(name: "threadId", value: threadId), URLQueryItem(name: "tabId", value: tabId),
      URLQueryItem(name: "maxWidth", value: String(max(1, maxWidth))), URLQueryItem(name: "maxHeight", value: String(max(1, maxHeight))),
    ]
    if !interactive { items.append(URLQueryItem(name: "interactive", value: "false")) }
    if let ticket { items.append(URLQueryItem(name: "wsTicket", value: ticket)) }
    return endpoint(httpBase, "/ws", items, webSocket: true)
  }

  /// A file a server tab downloaded: `GET …/download?threadId&tabId&id`, authenticated like the socket.
  public static func downloadURL(httpBase: URL, threadId: String, tabId: String, id: String, ticket: String?) -> URL {
    endpoint(httpBase, "/download", authed([("threadId", threadId), ("tabId", tabId), ("id", id)], ticket), webSocket: false)
  }

  /// `POST …/upload?threadId&tabId&chooser` with multipart `file` parts; an empty form cancels the page's picker.
  public static func uploadURL(httpBase: URL, threadId: String, tabId: String, chooser: String, ticket: String?) -> URL {
    endpoint(httpBase, "/upload", authed([("threadId", threadId), ("tabId", tabId), ("chooser", chooser)], ticket), webSocket: false)
  }

  private static func authed(_ pairs: [(String, String)], _ ticket: String?) -> [URLQueryItem] {
    pairs.map { URLQueryItem(name: $0.0, value: $0.1) } + (ticket.map { [URLQueryItem(name: "wsTicket", value: $0)] } ?? [])
  }

  private static func endpoint(_ base: URL, _ suffix: String, _ items: [URLQueryItem], webSocket: Bool) -> URL {
    var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
    components.path = basePath + suffix
    components.fragment = nil
    if webSocket { components.scheme = components.scheme == "https" ? "wss" : "ws" }
    // Percent-encoded by hand: URLComponents leaves `+` raw and the server reads it as a space (tickets contain it).
    components.percentEncodedQuery = items.map { "\(escape($0.name))=\(escape($0.value ?? ""))" }.joined(separator: "&")
    return components.url!
  }

  private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
  private static func escape(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value }
}

// MARK: - Server to client

public struct PreviewStreamControl: Sendable, Equatable {
  public enum Controller: String, Sendable { case agent, you, anotherViewer = "another-viewer", unclaimed }
  public struct Dialog: Sendable, Equatable {
    /// `alert`, `confirm`, `prompt` or `beforeunload`.
    public var type: String
    public var message: String
    public var defaultValue: String
  }

  public var canOperate: Bool
  public var controller: Controller
  public var generation: Int
  public var dialog: Dialog?

  public init(canOperate: Bool, controller: Controller, generation: Int, dialog: Dialog? = nil) {
    self.canOperate = canOperate
    self.controller = controller
    self.generation = generation
    self.dialog = dialog
  }

  /// The status line viewers show; a missing control means the socket is not connected.
  public static func label(_ control: PreviewStreamControl?) -> String {
    guard let control else { return "Connecting\u{2026}" }
    guard control.canOperate else { return "Read-only" }
    switch control.controller {
    case .you: return "You have control"
    case .agent: return "Agent has control"
    case .anotherViewer: return "Another viewer has control"
    case .unclaimed: return "Watching"
    }
  }
}

public struct PreviewStreamPointer: Sendable, Equatable {
  public enum Phase: String, Sendable { case move, click }
  public var phase: Phase
  public var x: Double
  public var y: Double
  public var sequence: Int
}

public struct PreviewStreamDownloadOffer: Sendable, Equatable {
  public var id: String
  public var fileName: String
  public var sizeBytes: Int
}

public struct PreviewStreamFileChooser: Sendable, Equatable {
  public var id: String
  public var multiple: Bool
  /// The input's `accept` attribute (comma-separated MIME types and extensions).
  public var accept: String
}

public struct PreviewStreamHostSetup: Sendable, Equatable {
  public enum Need: String, Sendable { case sandbox, libraries }
  public var need: Need
  /// For example `sudo npx t3 browser setup`.
  public var command: String

  /// A malformed reason still stops the viewer and offers the usual command; nil for a reason that is no host setup at all.
  public static func decode(reason: String?) -> PreviewStreamHostSetup? {
    guard let reason, !reason.isEmpty, let data = reason.data(using: .utf8),
      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let need = (object["need"] as? String).flatMap(Need.init(rawValue:)), let command = object["command"] as? String
    else { return nil }
    return PreviewStreamHostSetup(need: need, command: command)
  }

  public static let fallback = PreviewStreamHostSetup(need: .sandbox, command: "sudo npx t3 browser setup")

  public var message: String {
    need == .sandbox
      ? "This server's host blocks the sandbox its browser runs in. Run this once on the host, then try again:"
      : "This server's host is missing libraries its browser needs. Run this once on the host, then try again:"
  }
}

/// A JSON text message from the server. Unknown types and malformed shapes are dropped (nil), like the TS client.
public enum PreviewStreamMessage: Sendable, Equatable {
  /// The page's CSS viewport size, the coordinate space of input and pointer messages.
  case viewport(width: Double, height: Double)
  case control(PreviewStreamControl)
  /// Answer to a `probe`: whether the page point takes text.
  case probe(x: Double, y: Double, editable: Bool)
  /// Where an agent action is about to land.
  case pointer(PreviewStreamPointer)
  /// Text the page just copied or cut while this viewer had control.
  case clipboard(String)
  case download(PreviewStreamDownloadOffer)
  /// The page opened a new tab (a link or `window.open`).
  case popup(tabId: String)
  case fileChooser(PreviewStreamFileChooser)
  case fileChooserClosed(id: String)

  public static func decode(_ text: String) -> PreviewStreamMessage? {
    guard let data = text.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let type = object["type"] as? String
    else { return nil }
    func string(_ key: String) -> String? { object[key] as? String }
    func number(_ key: String) -> Double? { (object[key] as? NSNumber).flatMap { $0 === kCFBooleanTrue || $0 === kCFBooleanFalse ? nil : $0.doubleValue } }
    func bool(_ key: String) -> Bool? { (object[key] as? NSNumber).flatMap { $0 === kCFBooleanTrue || $0 === kCFBooleanFalse ? $0.boolValue : nil } }
    switch type {
    case "viewport":
      guard let width = number("width"), let height = number("height") else { return nil }
      return .viewport(width: width, height: height)
    case "control":
      guard let canOperate = bool("canOperate"), let controller = string("controller").flatMap(PreviewStreamControl.Controller.init(rawValue:)),
        let generation = number("generation")
      else { return nil }
      var dialog: PreviewStreamControl.Dialog?
      if let raw = object["dialog"], !(raw is NSNull) {
        guard let value = raw as? [String: Any], let type = value["type"] as? String, let message = value["message"] as? String,
          let defaultValue = value["defaultValue"] as? String
        else { return nil }
        dialog = .init(type: type, message: message, defaultValue: defaultValue)
      }
      return .control(PreviewStreamControl(canOperate: canOperate, controller: controller, generation: Int(generation), dialog: dialog))
    case "probe":
      guard let x = number("x"), let y = number("y"), let editable = bool("editable") else { return nil }
      return .probe(x: x, y: y, editable: editable)
    case "pointer":
      guard let phase = string("phase").flatMap(PreviewStreamPointer.Phase.init(rawValue:)), let x = number("x"), let y = number("y"),
        let sequence = number("sequence")
      else { return nil }
      return .pointer(PreviewStreamPointer(phase: phase, x: x, y: y, sequence: Int(sequence)))
    case "clipboard":
      return string("text").map { .clipboard($0) }
    case "download":
      guard let id = string("id"), let fileName = string("fileName"), let size = number("sizeBytes") else { return nil }
      return .download(PreviewStreamDownloadOffer(id: id, fileName: fileName, sizeBytes: Int(size)))
    case "popup":
      return string("tabId").map { .popup(tabId: $0) }
    case "fileChooser":
      guard let id = string("id"), let multiple = bool("multiple"), let accept = string("accept") else { return nil }
      return .fileChooser(PreviewStreamFileChooser(id: id, multiple: multiple, accept: accept))
    case "fileChooserClosed":
      return string("id").map { .fileChooserClosed(id: $0) }
    default:
      return nil
    }
  }
}

// MARK: - Client to server

/// CDP modifier bitmask: Alt 1, Ctrl 2, Meta 4, Shift 8.
public struct PreviewModifiers: OptionSet, Sendable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }
  public static let alt = PreviewModifiers(rawValue: 1)
  public static let control = PreviewModifiers(rawValue: 2)
  public static let meta = PreviewModifiers(rawValue: 4)
  public static let shift = PreviewModifiers(rawValue: 8)
}

/// A client message. Coordinates are page CSS pixels. Input is dropped by the server unless this viewer has control.
public enum PreviewStreamInput: Sendable, Equatable {
  public enum MouseAction: String, Sendable { case move, down, up }
  public enum MouseButton: String, Sendable { case none, left, middle, right }
  public enum KeyAction: String, Sendable { case down, up }

  case takeControl
  case releaseControl
  case dialog(accept: Bool, promptText: String? = nil)
  case viewport(PreviewViewportSetting)
  /// `buttons` is the pressed set: left 1, right 2, middle 4.
  case mouse(action: MouseAction, x: Double, y: Double, button: MouseButton, buttons: Int, clickCount: Int, modifiers: PreviewModifiers)
  case wheel(x: Double, y: Double, deltaX: Double, deltaY: Double, modifiers: PreviewModifiers)
  /// `keyCode` is the Windows virtual key code (Enter, Backspace and arrows need it); `text` only for printable keys without Ctrl or Meta.
  case key(action: KeyAction, key: String, code: String, keyCode: Int?, text: String?, modifiers: PreviewModifiers)
  case text(String)
  case resize(width: Int, height: Int)
  case navigate(url: String)
  case history(delta: Int)
  case reload(ignoreCache: Bool = false)
  case probe(x: Double, y: Double)

  /// Whether the server accepts it from a viewer that does not hold control (only the request for it).
  public var needsControl: Bool { self != .takeControl }

  public var json: JSONValue {
    switch self {
    case .takeControl: .object(["type": .string("takeControl")])
    case .releaseControl: .object(["type": .string("releaseControl")])
    case .dialog(let accept, let promptText):
      .object(["type": .string("dialog"), "accept": .bool(accept)].merging(promptText.map { ["promptText": .string($0)] } ?? [:]) { $1 })
    case .viewport(let setting): .object(["type": .string("viewport"), "setting": jsonValue(setting)])
    case .mouse(let action, let x, let y, let button, let buttons, let clickCount, let modifiers):
      .object([
        "type": .string("mouse"), "action": .string(action.rawValue), "x": .double(x), "y": .double(y), "button": .string(button.rawValue),
        "buttons": .int(buttons), "clickCount": .int(clickCount), "modifiers": .int(modifiers.rawValue),
      ])
    case .wheel(let x, let y, let deltaX, let deltaY, let modifiers):
      .object([
        "type": .string("wheel"), "x": .double(x), "y": .double(y), "deltaX": .double(deltaX), "deltaY": .double(deltaY), "modifiers": .int(modifiers.rawValue),
      ])
    case .key(let action, let key, let code, let keyCode, let text, let modifiers):
      .object(
        [
          "type": .string("key"), "action": .string(action.rawValue), "key": .string(key), "code": .string(code), "modifiers": .int(modifiers.rawValue),
        ]
        .merging(keyCode.map { ["keyCode": .int($0)] } ?? [:]) { $1 }
        .merging(text.map { ["text": .string($0)] } ?? [:]) { $1 })
    case .text(let text): .object(["type": .string("text"), "text": .string(text)])
    case .resize(let width, let height): .object(["type": .string("resize"), "width": .int(width), "height": .int(height)])
    case .navigate(let url): .object(["type": .string("navigate"), "url": .string(url)])
    case .history(let delta): .object(["type": .string("history"), "delta": .int(delta)])
    case .reload(let ignoreCache):
      .object(["type": .string("reload")].merging(ignoreCache ? ["ignoreCache": .bool(true)] : [:]) { $1 })
    case .probe(let x, let y): .object(["type": .string("probe"), "x": .double(x), "y": .double(y)])
    }
  }

  public func encoded() -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: (try? encoder.encode(json)) ?? Data("{}".utf8), as: UTF8.self)
  }

  private func jsonValue(_ setting: PreviewViewportSetting) -> JSONValue {
    guard let data = try? JSONEncoder().encode(setting), let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .null }
    return value
  }
}
