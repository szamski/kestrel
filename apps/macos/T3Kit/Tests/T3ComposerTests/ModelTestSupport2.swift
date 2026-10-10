import Foundation
import T3Contracts
import T3Timeline
import Testing

@testable import T3Composer

func decodeJSON<T: Decodable>(_ json: String) -> T {
  try! JSONDecoder().decode(T.self, from: Data(json.utf8))
}

func threadActivity(_ id: String, _ kind: String, at: String = "2026-02-23T00:00:01.000Z", tone: String = "info", sequence: Int? = nil, payload: String = "{}") -> V1.OrchestrationThreadActivity {
  decodeJSON("""
    {"id":"\(id)","tone":"\(tone)","kind":"\(kind)","summary":"s","payload":\(payload),"turnId":null,\(sequence.map { "\"sequence\":\($0)," } ?? "")"createdAt":"\(at)"}
    """)
}

func pendingApprovalSnapshot(detail: String = "bun run lint") -> ComposerThreadSnapshot {
  var snapshot = ComposerThreadSnapshot(phase: .running)
  snapshot.pending = derivePendingPrompts([threadActivity("a1", "approval.requested", tone: "approval", payload: #"{"requestId":"req-1","requestKind":"command","detail":"\#(detail)"}"#)])
  return snapshot
}

func pendingQuestionSnapshot(multiSelect: Bool = false, allowCustom: Bool = true, questions: Int = 1) -> ComposerThreadSnapshot {
  let items = (1...questions).map { index in
    #"{"id":"q\#(index)","header":"Header \#(index)","question":"Which one \#(index)?","options":[{"label":"Alpha","description":"first"},{"label":"Beta","description":"second","value":"beta"}],"multiSelect":\#(multiSelect),"allowCustomAnswer":\#(allowCustom)}"#
  }.joined(separator: ",")
  var snapshot = ComposerThreadSnapshot(phase: .running)
  snapshot.pending = derivePendingPrompts([
    threadActivity("u1", "user-input.requested", tone: "approval", payload: #"{"requestId":"req-q","questions":[\#(items)]}"#)
  ])
  return snapshot
}

@MainActor
struct ModelFixture {
  let env: FakeComposerEnvironment
  let services: ComposerServices
  let model: ComposerModel
  let directory: URL

  static let target = ComposerTarget(
    key: "env:thread-1", environmentId: "env", threadId: "thread-1", projectId: "project-1", cwd: "/work", repository: "org/repo")

  static func make(
    planMode: Bool = false, followUp: FollowUpBehavior = .queue, sendShortcut: SendShortcut = .enter, thread: ComposerThreadSnapshot? = nil,
    target: ComposerTarget = ModelFixture.target
  ) async throws -> ModelFixture {
    let catalog = try OracleCatalog.load().composerCatalog(planMode: planMode, followUp: followUp, sendShortcut: sendShortcut)
    let env = FakeComposerEnvironment(catalog: catalog)
    env.workspaceEntries = [
      ProjectEntry(path: "src/main.ts", kind: .file), ProjectEntry(path: "src/lib", kind: .directory), ProjectEntry(path: "docs/readme.md", kind: .file),
    ]
    if let thread { env.setThread(thread, forKey: target.key) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("t3-composer-tests-\(UUID().uuidString)", isDirectory: true)
    let services = ComposerServices(environment: env, storageDirectory: directory)
    let model = ComposerModel(target: target, services: services)
    await model.start()
    return ModelFixture(env: env, services: services, model: model, directory: directory)
  }

  /// Types text as the editor would report it (caret at the end).
  func type(_ markdown: String) {
    let cursor = ComposerLogic.collapseExpandedCursor(markdown, markdown.jsLength)
    model.editorDidChange(EditorSnapshot(value: markdown, cursor: cursor, expandedCursor: markdown.jsLength, selection: markdown.jsLength..<markdown.jsLength, contextIds: ComposerContextReferences.collectInlineContextIds(markdown)))
  }

  func push(_ snapshot: ComposerThreadSnapshot) async {
    env.setThread(snapshot, forKey: ModelFixture.target.key)
    await settle { self.model.thread.phase == snapshot.phase && self.model.thread.pending.approvals.count == snapshot.pending.approvals.count && self.model.thread.latestToolActivityId == snapshot.latestToolActivityId }
  }

  func settle(timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool = { true }) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
  }

  func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
