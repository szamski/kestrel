import Foundation
import Observation
import T3ClientRuntime
import T3Contracts

/// One pull request as the detail shows it: the detail, its activity (comments, reviews, threads, commits), its stack and
/// the threads linked to it, with the writes the user can make. Reads go to the environment that owns the project; after a
/// write the server's cache for the pull request is invalidated and everything is read again.
@MainActor @Observable
final class PullRequestDetailModel {
  enum Phase: Equatable { case loading, ready, failed(String, PullRequestsFailure.Kind) }

  struct Notice: Identifiable, Equatable {
    var id = UUID()
    var isError: Bool
    var title: String
    var detail: String?
  }

  let target: PullRequestTarget
  private let client: PullRequestsClient
  private let store: PullRequestsStore

  private(set) var phase: Phase = .loading
  private(set) var detail: PullRequestDetail?
  private(set) var activity: PullRequestActivity?
  private(set) var activityError: String?
  private(set) var stack: PullRequestStack?
  private(set) var linkedThreads: [PullRequestLinkedThreadsResultThreadsItem] = []
  /// Replies of long review threads loaded on request, by thread id.
  private(set) var moreReplies: [String: [PullRequestThreadComment]] = [:]
  private(set) var moreRepliesCursor: [String: String?] = [:]
  /// Writes in flight; their controls are disabled meanwhile.
  private(set) var pending: Set<String> = []
  var notice: Notice?

  @ObservationIgnored private var noticeTask: Task<Void, Never>?

  init(target: PullRequestTarget, runtime: ClientRuntime, store: PullRequestsStore = .shared) {
    self.target = target
    client = PullRequestsClient(runtime: runtime)
    self.store = store
  }

  private var environmentId: EnvironmentId { target.environmentId }

  private func ref(fresh: Bool) -> PullRequestRef {
    PullRequestRef(projectId: target.projectId, host: target.host, allowStale: fresh ? false : nil, repository: target.repository, number: target.number)
  }

  // MARK: Reading

  /// Reads everything. `fresh` bypasses the server's cache (after a write, or an explicit refresh).
  func load(fresh: Bool = false) async {
    if detail == nil { phase = .loading }
    let ref = ref(fresh: fresh)
    async let activityResult = read(Rpc.pullRequestsActivity, ref)
    async let stackResult = readStack(ref)
    async let linkedResult = readLinked(ref)
    do {
      let next = try await client.call(Rpc.pullRequestsDetail, ref, in: environmentId)
      detail = next
      phase = .ready
    } catch {
      let failure = PullRequestsClient.failure(error)
      if failure.kind != .interrupted { phase = detail == nil ? .failed(failure.message, failure.kind) : .ready }
      if detail != nil, failure.kind != .interrupted { show(failure.message, isError: true, title: "Could not refresh this pull request") }
    }
    switch await activityResult {
    case .success(let value):
      activity = value
      activityError = nil
      moreReplies = [:]
      moreRepliesCursor = [:]
    case .failure(let failure):
      if failure.kind != .interrupted { activityError = failure.message }
    }
    stack = await stackResult
    linkedThreads = await linkedResult
  }

  private func read<S: Sendable, F: Error & Sendable & Encodable>(_ spec: RpcSpec<PullRequestRef, S, F>, _ ref: PullRequestRef) async -> Result<S, PullRequestsFailure> {
    do { return .success(try await client.call(spec, ref, in: environmentId)) } catch { return .failure(PullRequestsClient.failure(error)) }
  }

  /// A fresh absence overrides saved membership; a failed read keeps the stack that was already shown.
  private func readStack(_ ref: PullRequestRef) async -> PullRequestStack? {
    guard supportsStacks else { return nil }
    switch await read(Rpc.pullRequestsStack, ref) {
    case .success(let value): return value
    case .failure: return stack
    }
  }

  private func readLinked(_ ref: PullRequestRef) async -> [PullRequestLinkedThreadsResultThreadsItem] {
    guard store.app?.runtime.serverConfigs[environmentId]?.config.environment.capabilities.threadPullRequests == true else { return [] }
    switch await read(Rpc.pullRequestsLinkedThreads, ref) {
    case .success(let value): return value.threads
    case .failure: return linkedThreads
    }
  }

  private var supportsStacks: Bool { detail?.capabilities.stacks ?? store.app?.runtime.serverConfigs[environmentId]?.config.environment.capabilities.pullRequestStackActions ?? false }

  /// Replies beyond the ones the activity carried.
  func loadMoreReplies(_ thread: PullRequestReviewThread) async {
    let cursor = moreRepliesCursor[thread.id] ?? thread.nextCommentsCursor
    guard let cursor else { return }
    let input = PullRequestThreadCommentsInput(projectId: target.projectId, host: target.host, repository: target.repository, number: target.number, threadId: thread.id, cursor: cursor)
    guard case .success(let page) = await read(Rpc.pullRequestsThreadComments, input) else { return }
    moreReplies[thread.id, default: []] += page.comments
    moreRepliesCursor[thread.id] = .some(page.nextCursor)
  }

  private func read<S: Sendable, F: Error & Sendable & Encodable>(_ spec: RpcSpec<PullRequestThreadCommentsInput, S, F>, _ input: PullRequestThreadCommentsInput) async -> Result<S, PullRequestsFailure> {
    do { return .success(try await client.call(spec, input, in: environmentId)) } catch { return .failure(PullRequestsClient.failure(error)) }
  }

  // MARK: Notices

  func show(_ detail: String?, isError: Bool, title: String) {
    noticeTask?.cancel()
    let next = Notice(isError: isError, title: title, detail: detail)
    notice = next
    guard !isError else { return }
    noticeTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(5))
      if !Task.isCancelled, self?.notice?.id == next.id { self?.notice = nil }
    }
  }

  // MARK: Writes

  /// Runs one write: the server's cache is invalidated and the pull request read again, so every surface shows the
  /// confirmed state. Returns whether it succeeded.
  @discardableResult
  private func write(_ name: String, failure title: String, hint: String, success: String? = nil, _ operation: () async throws -> Void) async -> Bool {
    guard !pending.contains(name) else { return false }
    pending.insert(name)
    defer { pending.remove(name) }
    do {
      try await operation()
    } catch {
      let failure = PullRequestsClient.failure(error)
      if failure.kind != .interrupted { show(failure.readable(hint: hint), isError: true, title: title) }
      return false
    }
    _ = try? await client.call(Rpc.pullRequestsInvalidate, PullRequestInvalidateInput(reference: ref(fresh: false)), in: environmentId)
    if let success { show(nil, isError: false, title: success) }
    await load(fresh: true)
    store.noteChanged()
    return true
  }

  func perform(_ action: PullRequestAction, method: PullRequestMergeMethod? = nil) async {
    let input = PullRequestActionInput(
      projectId: target.projectId, host: target.host, repository: target.repository, number: target.number, action: action, mergeMethod: method)
    await write(
      "action", failure: PullRequestDetailLogic.failureTitle(action), hint: "The host refused it. Check that you have write access to this repository.",
      success: PullRequestDetailLogic.successMessage(action)
    ) {
      _ = try await self.client.call(Rpc.pullRequestsRunAction, input, in: self.environmentId)
    }
  }

  @discardableResult
  func submitReview(_ verdict: PullRequestReviewVerdict, body: String, comments: [PullRequestReviewCommentDraft]) async -> Bool {
    let input = PullRequestSubmitReviewInput(
      projectId: target.projectId, host: target.host, repository: target.repository, number: target.number, verdict: verdict, body: body, comments: comments)
    return await write("review", failure: "Could not submit the review", hint: "The host refused the review.", success: "Review submitted") {
      _ = try await self.client.call(Rpc.pullRequestsSubmitReview, input, in: self.environmentId)
    }
  }

  @discardableResult
  func comment(_ body: String) async -> Bool {
    let input = PullRequestCommentInput(projectId: target.projectId, host: target.host, repository: target.repository, number: target.number, body: body)
    return await write("comment", failure: "Could not post the comment", hint: "The host refused the comment.", success: "Comment posted") {
      _ = try await self.client.call(Rpc.pullRequestsComment, input, in: self.environmentId)
    }
  }

  @discardableResult
  func update(title: String?, body: String?) async -> Bool {
    let input = PullRequestUpdateInput(projectId: target.projectId, host: target.host, repository: target.repository, number: target.number, title: title, body: body)
    return await write("update", failure: "Could not save the changes", hint: "The host refused the edit.", success: "Saved") {
      _ = try await self.client.call(Rpc.pullRequestsUpdate, input, in: self.environmentId)
    }
  }

  @discardableResult
  func updateComment(_ comment: PullRequestComment, body: String) async -> Bool {
    let kind: PullRequestCommentUpdateInputKind = comment.kind == .reviewComment ? .reviewComment : .issueComment
    let input = PullRequestCommentUpdateInput(
      projectId: target.projectId, host: target.host, repository: target.repository, number: target.number, commentId: comment.id, kind: kind, body: body)
    return await write("comment:\(comment.id)", failure: "Could not edit the comment", hint: "The host refused the edit.") {
      _ = try await self.client.call(Rpc.pullRequestsUpdateComment, input, in: self.environmentId)
    }
  }

  /// Reacts to the pull request itself (`subject` nil) or to a comment.
  func react(_ content: PullRequestReactionContent, subject: String?, reacted: Bool) async {
    let input = PullRequestReactionInput(
      projectId: target.projectId, host: target.host, repository: target.repository, number: target.number, subjectId: subject, content: content, reacted: reacted)
    await write("reaction", failure: "Could not update the reaction", hint: "The host refused the reaction.") {
      _ = try await self.client.call(Rpc.pullRequestsSetReaction, input, in: self.environmentId)
    }
  }

  @discardableResult
  func reply(to thread: PullRequestReviewThread, body: String) async -> Bool {
    let input = PullRequestThreadReplyInput(
      projectId: target.projectId, host: target.host, repository: target.repository, number: target.number, threadId: thread.id, body: body)
    return await write("thread:\(thread.id)", failure: "Could not post the reply", hint: "The host refused the reply.") {
      _ = try await self.client.call(Rpc.pullRequestsReplyToThread, input, in: self.environmentId)
    }
  }

  func setResolved(_ thread: PullRequestReviewThread, resolved: Bool) async {
    let input = PullRequestThreadResolutionInput(
      projectId: target.projectId, host: target.host, repository: target.repository, number: target.number, threadId: thread.id, resolved: resolved)
    await write("thread:\(thread.id)", failure: resolved ? "Could not resolve the thread" : "Could not reopen the thread", hint: "The host refused it.") {
      _ = try await self.client.call(Rpc.pullRequestsSetThreadResolution, input, in: self.environmentId)
    }
  }

  func setLabel(_ name: String, applied: Bool) async {
    let input = PullRequestLabelChangeInput(
      projectId: target.projectId, host: target.host, repository: target.repository, number: target.number, labels: [name], applied: applied)
    await write("labels", failure: "Could not change the labels", hint: "The host refused the label change.") {
      _ = try await self.client.call(Rpc.pullRequestsSetLabels, input, in: self.environmentId)
    }
  }

  func setReviewer(_ candidate: PullRequestReviewerCandidate, requested: Bool) async {
    let input = PullRequestReviewerRequestInput(
      projectId: target.projectId, host: target.host, repository: target.repository, number: target.number,
      reviewers: [PullRequestReviewerRequestInputReviewersItem(id: candidate.id, kind: candidate.kind)], requested: requested)
    await write("reviewers", failure: "Could not change the reviewers", hint: "The host refused the reviewer change.") {
      _ = try await self.client.call(Rpc.pullRequestsRequestReviewers, input, in: self.environmentId)
    }
  }

  // MARK: Pickers

  func labelCandidates() async -> PullRequestLabelCandidateList? {
    try? await client.call(Rpc.pullRequestsLabelCandidates, ref(fresh: false), in: environmentId)
  }

  func reviewerCandidates() async -> PullRequestReviewerCandidateList? {
    try? await client.call(Rpc.pullRequestsReviewerCandidates, ref(fresh: false), in: environmentId)
  }

  // MARK: Files viewed

  func filesViewed() async -> [String: PullRequestFileViewedState] {
    guard detail?.capabilities.viewedFiles != nil, let result = try? await client.call(Rpc.pullRequestsFilesViewed, ref(fresh: false), in: environmentId) else { return [:] }
    return Dictionary(result.files.map { ($0.path, $0.state) }, uniquingKeysWith: { _, last in last })
  }

  func setFiles(viewed: Bool, paths: [String]) async -> Bool {
    let input = PullRequestSetFilesViewedInput(
      projectId: target.projectId, host: target.host, repository: target.repository, number: target.number,
      files: paths.map { PullRequestSetFilesViewedInputFilesItem(path: $0, viewed: viewed) })
    do {
      _ = try await client.call(Rpc.pullRequestsSetFilesViewed, input, in: environmentId)
      _ = try? await client.call(Rpc.pullRequestsInvalidate, PullRequestInvalidateInput(reference: ref(fresh: false), filesViewedOnly: true), in: environmentId)
      return true
    } catch {
      show(PullRequestsClient.failure(error).message, isError: true, title: "Could not save viewed files")
      return false
    }
  }

  // MARK: Diff

  /// Files the host left out of the diff (too large), as the last read reported them.
  private(set) var omittedFiles: [PullRequestOmittedFileStat] = []

  /// Where the Code tab reads from.
  func diffPatch(commit: String? = nil) async throws -> PullRequestDiffResult {
    let result = try await client.diff(
      PullRequestDiffInput(projectId: target.projectId, host: target.host, repository: target.repository, number: target.number, commit: commit), in: environmentId)
    omittedFiles = result.omittedFileStats ?? []
    return result
  }

  var viewerPermissions: PullRequestViewerPermissions? { detail?.viewerPermissions }

  /// The viewer authored this comment (for the edit button).
  func isMine(_ actor: PullRequestActor?) -> Bool {
    guard let viewer = detail?.viewer?.lowercased(), let login = actor?.login.lowercased() else { return false }
    return viewer == login
  }
}
