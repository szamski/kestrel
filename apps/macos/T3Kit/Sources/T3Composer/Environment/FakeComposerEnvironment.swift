import Foundation
import T3Contracts
import T3Timeline

/// An in-memory `ComposerEnvironment` for previews and tests. It records every call, serves
/// configurable data and lets a test drive thread state and failures.
public final class FakeComposerEnvironment: ComposerEnvironment, @unchecked Sendable {
  private let lock = NSLock()

  private var _catalog: ComposerCatalog
  private var catalogContinuations: [UUID: AsyncStream<ComposerCatalog>.Continuation] = [:]
  private var threads: [String: ComposerThreadSnapshot] = [:]
  private var threadContinuations: [String: [UUID: AsyncStream<ComposerThreadSnapshot>.Continuation]] = [:]
  private var storage: [String: Data] = [:]

  // MARK: Configuration

  /// Workspace entries `@` searches (filtered by substring of the path).
  public var workspaceEntries: [ProjectEntry] = []
  public var pullRequests: [ComposerPullRequestCandidate] = []
  /// Seconds each upload takes, in 5 steps; zero finishes at once.
  public var uploadDuration: Double = 0
  public var failUploadsWith: String?
  public var failSendsWith: String?
  public var failStorageWrites = false
  /// Simulated latency of searches.
  public var searchDelay: Duration = .zero

  // MARK: Recordings

  public private(set) var sentTurns: [(command: V1.ClientOrchestrationCommandThreadTurnStart, titleSeed: String?, isFirstMessage: Bool)] = []
  public private(set) var interrupts: [V1.ClientOrchestrationCommandThreadTurnInterrupt] = []
  public private(set) var approvalResponses: [V1.ClientOrchestrationCommandThreadApprovalRespond] = []
  public private(set) var userInputResponses: [V1.ClientOrchestrationCommandThreadUserInputRespond] = []
  public private(set) var dismissedUserInputs: [V1.ApprovalRequestId] = []
  public private(set) var uploads: [ComposerUploadRequest] = []
  public private(set) var deletedUploads: [String] = []
  public private(set) var searches: [String] = []

  public init(catalog: ComposerCatalog = ComposerCatalog()) { _catalog = catalog }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  // MARK: Driving the fake

  public func setCatalog(_ catalog: ComposerCatalog) {
    let continuations = locked { () -> [AsyncStream<ComposerCatalog>.Continuation] in
      _catalog = catalog
      return Array(catalogContinuations.values)
    }
    for continuation in continuations { continuation.yield(catalog) }
  }

  /// Publishes a thread state to everything following `key`.
  public func setThread(_ snapshot: ComposerThreadSnapshot, forKey key: String) {
    let continuations = locked { () -> [AsyncStream<ComposerThreadSnapshot>.Continuation] in
      threads[key] = snapshot
      return Array(threadContinuations[key, default: [:]].values)
    }
    for continuation in continuations { continuation.yield(snapshot) }
  }

  public func thread(forKey key: String) -> ComposerThreadSnapshot { locked { threads[key] } ?? ComposerThreadSnapshot() }

  // MARK: Server configuration

  public func catalog() async -> ComposerCatalog { locked { _catalog } }

  public func catalogUpdates() -> AsyncStream<ComposerCatalog> {
    AsyncStream { continuation in
      let id = UUID()
      locked { catalogContinuations[id] = continuation }
      continuation.onTermination = { [weak self] _ in self?.locked { self?.catalogContinuations[id] = nil } }
    }
  }

  public func threadSnapshots(for target: ComposerTarget) -> AsyncStream<ComposerThreadSnapshot> {
    AsyncStream { continuation in
      let id = UUID()
      let current = locked { () -> ComposerThreadSnapshot in
        threadContinuations[target.key, default: [:]][id] = continuation
        return threads[target.key] ?? ComposerThreadSnapshot()
      }
      continuation.yield(current)
      continuation.onTermination = { [weak self] _ in self?.locked { self?.threadContinuations[target.key]?[id] = nil } }
    }
  }

  // MARK: Context sources

  public func searchWorkspaceEntries(cwd: String, query: String, limit: Int) async throws -> ProjectSearchEntriesResult {
    locked { searches.append(query) }
    if searchDelay != .zero { try await Task.sleep(for: searchDelay) }
    let needle = query.lowercased()
    let matches = workspaceEntries.filter { needle.isEmpty || $0.path.lowercased().contains(needle) }
    return ProjectSearchEntriesResult(entries: Array(matches.prefix(limit)), truncated: matches.count > limit)
  }

  public func listPullRequests(projectId: String, query: String?, limit: Int) async throws -> [ComposerPullRequestCandidate] {
    if searchDelay != .zero { try await Task.sleep(for: searchDelay) }
    return Array(pullRequests.prefix(limit))
  }

  public func resolvePullRequest(projectId: String, repository: String, number: Int) async throws -> ComposerPullRequestCandidate? {
    pullRequests.first { $0.number == number }
  }

  // MARK: Attachments

  public func uploadAttachment(_ upload: ComposerUploadRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
    locked { uploads.append(upload) }
    if let failure = failUploadsWith { throw ComposerEnvironmentError(failure) }
    if uploadDuration > 0 {
      for step in 1...5 {
        try await Task.sleep(for: .seconds(uploadDuration / 5))
        progress(Double(step) / 5)
      }
    } else {
      progress(1)
    }
    return "server-\(upload.attachmentId)"
  }

  public func deleteUploadedAttachment(id: String) async { locked { deletedUploads.append(id) } }

  public func verifyUploadedAttachment(id: String) async -> UploadVerification { .verified }

  // MARK: Turn actions

  public func sendTurn(_ command: V1.ClientOrchestrationCommandThreadTurnStart, target: ComposerTarget, titleSeed: String?, isFirstMessage: Bool) async throws {
    if let failure = failSendsWith { throw ComposerEnvironmentError(failure) }
    locked { sentTurns.append((command, titleSeed, isFirstMessage)) }
  }

  public func interruptTurn(_ command: V1.ClientOrchestrationCommandThreadTurnInterrupt, target: ComposerTarget) async throws {
    locked { interrupts.append(command) }
  }

  public func respondToApproval(_ command: V1.ClientOrchestrationCommandThreadApprovalRespond, target: ComposerTarget) async throws {
    locked { approvalResponses.append(command) }
  }

  public func respondToUserInput(_ command: V1.ClientOrchestrationCommandThreadUserInputRespond, target: ComposerTarget) async throws {
    locked { userInputResponses.append(command) }
  }

  public func dismissUserInput(requestId: V1.ApprovalRequestId, target: ComposerTarget) async throws {
    locked { dismissedUserInputs.append(requestId) }
  }

  // MARK: Persistence

  public func loadStorage(key: String) async -> Data? { locked { storage[key] } }

  public func saveStorage(key: String, data: Data) async throws {
    if failStorageWrites { throw ComposerEnvironmentError("Storage is full") }
    locked { storage[key] = data }
  }
}
