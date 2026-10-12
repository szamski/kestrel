import Foundation
import T3Contracts

/// A thread's browser tabs as `preview.list` and `subscribePreviewEvents` describe them (the mobile app's
/// `threadPreviewTabsAtom`, as a value). Events carry the server's process epoch and a monotonic revision: a list is
/// authoritative for its revision, events at or below it are stale, and an event from another epoch means the server
/// restarted and only a fresh list can be trusted.
public struct PreviewTabsState: Sendable, Equatable {
  public enum EventOutcome: Sendable, Equatable { case applied, ignored, needsRefresh }

  public private(set) var serverEpoch: String?
  public private(set) var revision = 0
  public private(set) var sessions: [PreviewSessionSnapshot] = []
  /// A list result arrived, so `sessions` covers tabs opened before this view existed.
  public private(set) var listed = false
  private var replay: [PreviewEvent] = []
  private static let maxReplay = 200

  public init() {}

  /// Tabs the server's own browser hosts (desktop `<webview>` tabs belong to one desktop client).
  public var serverTabs: [PreviewSessionSnapshot] { sessions.filter { $0.runtime == .server } }

  public mutating func apply(list result: PreviewListResult) {
    if serverEpoch == result.serverEpoch, listed, result.revision < revision { return }
    serverEpoch = result.serverEpoch
    revision = result.revision
    sessions = result.sessions
    listed = true
    // Lists can land after events they predate; replay the newer ones.
    let pending = replay.filter { Self.epoch($0) == result.serverEpoch && Self.revision($0) > result.revision }
    replay = pending
    for event in pending { _ = applyEvent(event) }
  }

  /// An event of this thread (callers filter by thread: the stream carries every thread of the environment).
  @discardableResult
  public mutating func apply(event: PreviewEvent) -> EventOutcome {
    if case .unknown = event { return .ignored }
    if let serverEpoch, Self.epoch(event) == serverEpoch, Self.revision(event) <= revision { return .ignored }
    replay = Array((replay + [event]).suffix(Self.maxReplay))
    // A restarted server resets revisions; only a fresh list is authoritative.
    if let serverEpoch, Self.epoch(event) != serverEpoch { return .needsRefresh }
    guard listed else { return .applied }
    return applyEvent(event)
  }

  private mutating func applyEvent(_ event: PreviewEvent) -> EventOutcome {
    guard Self.revision(event) > revision else { return .ignored }
    let tabId = Self.tabId(event)
    let index = sessions.firstIndex { $0.tabId == tabId }
    switch event {
    case .closed:
      if let index { sessions.remove(at: index) }
    case .failed(let failed):
      if let index {
        sessions[index].navStatus = .loadFailed(
          PreviewNavStatusLoadFailed(url: failed.url, title: failed.title, code: failed.code, description: failed.description, download: failed.download))
        sessions[index].updatedAt = failed.createdAt
      }
    case .opened(let value): place(value.snapshot, at: index)
    case .navigated(let value): place(value.snapshot, at: index)
    case .resized(let value): place(value.snapshot, at: index)
    case .unknown: return .ignored
    }
    serverEpoch = Self.epoch(event)
    revision = Self.revision(event)
    return .applied
  }

  /// A tab keeps its place so the strip order is stable.
  private mutating func place(_ snapshot: PreviewSessionSnapshot, at index: Int?) {
    if let index { sessions[index] = snapshot } else { sessions.append(snapshot) }
  }

  public static func threadId(_ event: PreviewEvent) -> String? {
    switch event {
    case .opened(let e): e.threadId
    case .navigated(let e): e.threadId
    case .resized(let e): e.threadId
    case .failed(let e): e.threadId
    case .closed(let e): e.threadId
    case .unknown: nil
    }
  }

  static func tabId(_ event: PreviewEvent) -> String {
    switch event {
    case .opened(let e): e.tabId
    case .navigated(let e): e.tabId
    case .resized(let e): e.tabId
    case .failed(let e): e.tabId
    case .closed(let e): e.tabId
    case .unknown: ""
    }
  }

  static func epoch(_ event: PreviewEvent) -> String {
    switch event {
    case .opened(let e): e.serverEpoch
    case .navigated(let e): e.serverEpoch
    case .resized(let e): e.serverEpoch
    case .failed(let e): e.serverEpoch
    case .closed(let e): e.serverEpoch
    case .unknown: ""
    }
  }

  static func revision(_ event: PreviewEvent) -> Int {
    switch event {
    case .opened(let e): e.revision
    case .navigated(let e): e.revision
    case .resized(let e): e.revision
    case .failed(let e): e.revision
    case .closed(let e): e.revision
    case .unknown: 0
    }
  }
}

// MARK: - Tab presentation

extension PreviewSessionSnapshot {
  /// The address the tab shows; empty for a new tab.
  public var address: String {
    switch navStatus {
    case .idle, .unknown: ""
    case .loading(let status): status.url
    case .success(let status): status.url
    case .loadFailed(let status): status.url
    }
  }

  public var isLoading: Bool {
    if case .loading = navStatus { return true }
    return false
  }

  /// A failed load, in the browser's words.
  public var failure: PreviewNavStatusLoadFailed? {
    if case .loadFailed(let status) = navStatus { return status }
    return nil
  }

  public var displayTitle: String {
    let title: String
    switch navStatus {
    case .idle, .unknown: return "New tab"
    case .loading(let status): title = status.title
    case .success(let status): title = status.title
    case .loadFailed(let status): title = status.title
    }
    if !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
    return URL(string: address)?.host(percentEncoded: false).flatMap { $0.isEmpty ? nil : $0 } ?? address
  }
}

extension Collection where Element == PreviewSessionSnapshot {
  /// The tab the agent touched last, the default when nothing is selected.
  public var mostRecent: PreviewSessionSnapshot? { self.max { $0.updatedAt.rawValue < $1.updatedAt.rawValue } }
}

// MARK: - Viewport and zoom

public struct PreviewViewportPreset: Sendable, Equatable, Identifiable {
  public enum Category: String, Sendable { case phone = "Phone", tablet = "Tablet" }
  public var id: String
  public var label: String
  public var category: Category
  public var width: Int
  public var height: Int

  public var setting: PreviewViewportSetting {
    .preset(PreviewViewportSettingPreset(width: width, height: height, presetId: PreviewViewportSettingPresetPresetId(rawValue: id)))
  }
}

public enum PreviewViewports {
  /// Chrome DevTools' default devices, as packages/shared/src/previewViewport.ts lists them.
  public static let presets: [PreviewViewportPreset] = [
    .init(id: "iphone-se", label: "iPhone SE", category: .phone, width: 375, height: 667),
    .init(id: "iphone-xr", label: "iPhone XR", category: .phone, width: 414, height: 896),
    .init(id: "iphone-12-pro", label: "iPhone 12 Pro", category: .phone, width: 390, height: 844),
    .init(id: "iphone-14-pro-max", label: "iPhone 14 Pro Max", category: .phone, width: 430, height: 932),
    .init(id: "pixel-7", label: "Pixel 7", category: .phone, width: 412, height: 915),
    .init(id: "samsung-galaxy-s8-plus", label: "Samsung Galaxy S8+", category: .phone, width: 360, height: 740),
    .init(id: "samsung-galaxy-s20-ultra", label: "Samsung Galaxy S20 Ultra", category: .phone, width: 412, height: 915),
    .init(id: "ipad-mini", label: "iPad Mini", category: .tablet, width: 768, height: 1024),
    .init(id: "ipad-air", label: "iPad Air", category: .tablet, width: 820, height: 1180),
    .init(id: "ipad-pro", label: "iPad Pro", category: .tablet, width: 1024, height: 1366),
    .init(id: "surface-pro-7", label: "Surface Pro 7", category: .tablet, width: 912, height: 1368),
    .init(id: "surface-duo", label: "Surface Duo", category: .phone, width: 540, height: 720),
    .init(id: "galaxy-z-fold-5", label: "Galaxy Z Fold 5", category: .phone, width: 344, height: 882),
    .init(id: "asus-zenbook-fold", label: "Asus Zenbook Fold", category: .tablet, width: 853, height: 1280),
    .init(id: "samsung-galaxy-a51-71", label: "Samsung Galaxy A51/71", category: .phone, width: 412, height: 914),
    .init(id: "nest-hub", label: "Nest Hub", category: .tablet, width: 1024, height: 600),
    .init(id: "nest-hub-max", label: "Nest Hub Max", category: .tablet, width: 1280, height: 800),
  ]

  /// The same viewport turned a quarter: the device toolbar's rotate button. Fill has no orientation.
  public static func rotated(_ setting: PreviewViewportSetting) -> PreviewViewportSetting? {
    switch setting {
    case .fill, .unknown: nil
    case .freeform(let value): .freeform(PreviewViewportSettingFreeform(width: value.height, height: value.width))
    case .preset(let value): .preset(PreviewViewportSettingPreset(width: value.height, height: value.width, presetId: value.presetId))
    }
  }

  /// Chrome's zoom ladder (`PREVIEW_ZOOM_LEVELS`).
  public static let zoomLevels: [Double] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 5.0]
  public static let defaultZoom = 1.0

  /// The next ladder step from `current` (a value off the ladder steps from its nearest rung).
  public static func zoom(from current: Double, step: Int) -> Double {
    let index = zoomLevels.enumerated().min { abs($0.element - current) < abs($1.element - current) }?.offset ?? 7
    return zoomLevels[min(max(index + step, 0), zoomLevels.count - 1)]
  }
}
