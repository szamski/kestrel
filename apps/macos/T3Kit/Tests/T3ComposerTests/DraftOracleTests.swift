import Foundation
import T3Contracts
import Testing

@testable import T3Composer

@Suite("Draft state oracle") struct DraftOracleTests {
  private func selection(_ any: Any?) throws -> ModelSelection {
    try JSONDecoder().decode(ModelSelection.self, from: JSONSerialization.data(withJSONObject: any as Any))
  }

  private func snapshot(_ state: ComposerDraftState, key: String) throws -> Any {
    let draft = state.draftsByKey[key]
    let draftJSON: Any
    if let draft {
      draftJSON = [
        "prompt": draft.prompt, "modelSelectionByProvider": try draft.modelSelectionByProvider.mapValues { try json($0) }, "activeProvider": draft.activeProvider as Any? ?? NSNull(),
        "explicit": draft.modelSelectionExplicit as Any? ?? NSNull(), "runtimeMode": draft.runtimeMode.map { $0.rawValue } as Any? ?? NSNull(),
        "interactionMode": draft.interactionMode.map { $0.rawValue } as Any? ?? NSNull(),
      ] as [String: Any]
    } else {
      draftJSON = NSNull()
    }
    return ["draft": draftJSON, "sticky": try state.stickyModelSelectionByProvider.mapValues { try json($0) }, "stickyActive": state.stickyActiveProvider as Any? ?? NSNull()]
  }

  @Test func modelSelectionScripts() throws {
    let key = "draft-oracle"
    try Oracle.check("draftScript", nullEqualsMissing: true) { input in
      var state = ComposerDraftState()
      var trace: [Any] = []
      for op in input["ops"] as! [[String: Any]] {
        switch op.string("op") {
        case "setPrompt": state.setPrompt(key, op.string("prompt"))
        case "setModelSelection": state.setModelSelection(key, try selection(op["selection"]), explicit: op.bool("explicit"), replaceOptions: op.bool("replaceOptions"))
        case "setSticky": state.setStickyModelSelection(try selection(op["selection"]))
        case "applySticky": state.applyStickyState(key)
        case "setOptions":
          let options = try (op["options"] as? [Any]).map { try JSONDecoder().decode([ProviderOptionSelection].self, from: JSONSerialization.data(withJSONObject: $0)) }
          state.setProviderModelOptions(key, instanceId: op.string("instanceId"), model: op.string("model"), options: options, persistSticky: op.bool("persistSticky"))
        case "setRuntimeMode": state.setRuntimeMode(key, (op["mode"] as? String).map { RuntimeMode(rawValue: $0) })
        case "setInteractionMode": state.setInteractionMode(key, (op["mode"] as? String).map { ProviderInteractionMode(rawValue: $0) })
        default: Issue.record("unknown op")
        }
        trace.append(try snapshot(state, key: key))
      }
      return trace
    }
  }

  @Test func attachmentsDedupeLimitAndReplaceMarkers() {
    var state = ComposerDraftState()
    func file(_ id: String, _ name: String = "a.txt", size: Int = 5, mime: String = "text/plain") -> ComposerAttachment {
      ComposerAttachment(id: id, kind: .file, name: name, mimeType: mime, sizeBytes: size, localPath: "/tmp/\(id)")
    }
    #expect(state.addAttachments("k", [file("1"), file("2"), file("3", "b.txt")]) == ["1", "3"])  // "2" duplicates "1"
    #expect(state.addAttachments("k", [file("1", "z")]).isEmpty)  // known id
    // A marker without bytes or upload is replaced in place by a re-pick, and its chip follows.
    var marker = file("m", "clip.mp4", size: 9, mime: "")
    marker.localPath = nil
    state.update("k") { $0.attachments.append(marker) }
    state.update("k") { $0.prompt = "see \(ComposerContextReferences.format(ContextRecords.fileReference(marker))) here" }
    #expect(state.addAttachments("k", [file("m2", "clip.mp4", size: 9, mime: "video/mp4")]).isEmpty)
    let draft = state.draft("k")
    #expect(draft.attachments.contains { $0.id == "m2" } && !draft.attachments.contains { $0.id == "m" })
    #expect(draft.prompt.contains("file_m2"))
    // The per-message cap.
    var full = ComposerDraftState()
    let many = (0..<(ModelConstants.maxAttachments + 5)).map { file("f\($0)", "n\($0)") }
    #expect(full.addAttachments("k", many).count == ModelConstants.maxAttachments)
    // Removing an attachment removes its chips with it; an empty draft disappears.
    var chips = ComposerDraftState()
    let image = ComposerAttachment(id: "i1", kind: .image, name: "pic.png", mimeType: "image/png", sizeBytes: 1)
    chips.addAttachments("k", [image])
    chips.setPrompt("k", "look \(ComposerContextReferences.format(ContextRecords.imageReference(image)))")
    #expect(chips.removeAttachment("k", id: "i1")?.id == "i1")
    #expect(chips.draftsByKey["k"]?.prompt.contains("t3-context") != true)
  }

  @Test func syncDropsOrphanedContextAndFiles() {
    var state = ComposerDraftState()
    let file = ComposerAttachment(id: "f1", kind: .file, name: "n.txt", mimeType: "text/plain", sizeBytes: 1)
    let pr = ContextRecords.pullRequestReferenceRecord(PullRequestContextMetadata(number: 3, title: "t", url: "u", headBranch: "h", baseBranch: "b", state: .open, isDraft: false))
    state.addAttachments("k", [file])
    state.addRecord("k", .reviewComment(pr))
    let referenced = "\(ComposerContextReferences.format(ContextRecords.fileReference(file))) \(ComposerContextReferences.format(ContextRecords.reference(for: .reviewComment(pr))))"
    state.setPrompt("k", referenced)
    state.syncWithPrompt("k")
    #expect(state.draft("k").records.count == 1 && state.draft("k").attachments.count == 1)
    state.setPrompt("k", "plain")
    state.syncWithPrompt("k")
    #expect(state.draft("k").records.isEmpty && state.draft("k").attachments.isEmpty)
  }

  @Test func persistenceRoundTripsAndRejectsOtherVersions() throws {
    var state = ComposerDraftState()
    state.setPrompt("k", "hello [a.ts](a.ts) ")
    state.setStickyModelSelection(ModelSelection(instanceId: "codex", model: "m", options: nil))
    state.setRuntimeMode("k", .auto)
    let data = try state.encoded()
    #expect(ComposerDraftState.decode(data) == state)
    #expect(ComposerDraftState.decode(nil) == ComposerDraftState())
    #expect(ComposerDraftState.decode(Data("{\"version\":99,\"state\":{}}".utf8)) == ComposerDraftState())
    #expect(ComposerDraftState.decode(Data("garbage".utf8)) == ComposerDraftState())
  }
}
