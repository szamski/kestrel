import AppKit
import T3ClientRuntime
import T3Contracts
import T3Markdown
import T3Protocol

/// Images behind signed asset URLs (`assets.createUrl`) and plain http(s) images, cached in memory.
/// The server hands out a short-lived relative URL per resource; the bytes then load with a plain GET.
@MainActor
final class AssetStore {
  private let runtime: ClientRuntime
  private let cache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.totalCostLimit = 128 * 1024 * 1024
    return cache
  }()
  private var inflight: [String: Task<NSImage?, Never>] = [:]

  init(runtime: ClientRuntime) { self.runtime = runtime }

  /// Image for a Markdown reference inside a thread: workspace files resolve through the server.
  func image(for reference: MarkdownImage, in key: ScopedThreadKey) async -> NSImage? {
    switch reference.source {
    case .direct(let string):
      guard let url = URL(string: string), ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
      return await load(cacheKey: url.absoluteString) { await Self.fetch(url) }
    case .workspaceFile(let path):
      let resource = AssetResource.workspaceFile(AssetResourceWorkspaceFile(threadId: key.threadId, path: path))
      return await image(resource: resource, environment: key.environmentId, cacheKey: "ws:\(key):\(path)")
    case .blocked:
      return nil
    }
  }

  /// A message attachment (an uploaded image).
  func attachment(_ image: ChatImageAttachment, in key: ScopedThreadKey) async -> NSImage? {
    let resource = AssetResource.attachment(
      AssetResourceAttachment(attachmentId: image.id, fileName: image.name, mimeType: image.mimeType, disposition: .inline))
    return await self.image(resource: resource, environment: key.environmentId, cacheKey: "att:\(key.environmentId.rawValue):\(image.id)")
  }

  private func image(resource: AssetResource, environment: EnvironmentId, cacheKey: String) async -> NSImage? {
    let runtime = runtime
    return await load(cacheKey: cacheKey) {
      guard let environmentRuntime = await runtime.runtime(for: environment),
        let session = environmentRuntime.supervisor.session.value,
        let result = try? await session.call(Rpc.assetsCreateUrl, AssetCreateUrlInput(resource: resource)),
        let url = URL(string: result.relativeUrl, relativeTo: environmentRuntime.entry.httpBaseURL)?.absoluteURL
      else { return nil }
      return await Self.fetch(url)
    }
  }

  private func load(cacheKey: String, _ fetch: @escaping @Sendable () async -> NSImage?) async -> NSImage? {
    let key = cacheKey as NSString
    if let hit = cache.object(forKey: key) { return hit }
    if let running = inflight[cacheKey] { return await running.value }
    let task = Task { await fetch() }
    inflight[cacheKey] = task
    let image = await task.value
    inflight[cacheKey] = nil
    if let image { cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4)) }
    return image
  }

  private nonisolated static func fetch(_ url: URL) async -> NSImage? {
    guard let (data, response) = try? await URLSession.shared.data(from: url),
      (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
    else { return nil }
    return NSImage(data: data)
  }
}
