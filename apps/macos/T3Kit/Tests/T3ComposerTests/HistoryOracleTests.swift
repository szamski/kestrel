import Foundation
import Testing

@testable import T3Composer

@Suite("Prompt history and validation oracle") struct HistoryOracleTests {
  @Test func recall() throws {
    try Oracle.check("recallable") { ComposerPromptHistory.recallablePrompt($0.string("text")) }
    try Oracle.check("historyEntries") { input in
      let messages = (input["messages"] as! [[String: Any]]).map {
        ComposerPromptHistoryMessage(id: $0.string("id"), role: $0.string("role"), text: $0.string("text"))
      }
      return ComposerPromptHistory.entries(from: messages).map { ["id": $0.id, "prompt": $0.prompt] }
    }
    try Oracle.check("historyStep") { input in
      let entries = (input["entries"] as! [[String: Any]]).map { ComposerPromptHistoryEntry(id: $0.string("id"), prompt: $0.string("prompt")) }
      let position = (input["position"] as? [String: Any]).map { ComposerPromptHistoryPosition(entryId: $0.string("entryId"), recalled: $0.string("recalled")) }
      let step = ComposerPromptHistory.step(
        direction: ComposerPromptHistory.Direction(rawValue: input.string("direction"))!, entries: entries, position: position,
        currentPrompt: input.string("currentPrompt"))
      guard let step else { return NSNull() }
      let positionJSON: Any = step.position.map { ["entryId": $0.entryId, "recalled": $0.recalled] } ?? NSNull()
      return ["position": positionJSON, "prompt": step.prompt]
    }
  }

  @Test func validationAndOutgoingPrompt() throws {
    try Oracle.check("promptValidation") { input in
      let prompt = (input["parts"] as! [[Any]]).map { String(repeating: $0[0] as! String, count: ($0[1] as! NSNumber).intValue) }.joined()
      return [
        "message": ComposerSubmission.promptLengthValidationMessage(prompt) as Any? ?? NSNull(),
        "expanded": AssistantCitations.expandForProvider(prompt.jsTrim()).jsLength,
      ]
    }
    try Oracle.check("effortPrefix") { input in
      ComposerSubmission.applyClaudePromptEffortPrefix(input.string("prompt"), effort: input["effort"] as? String)
    }
    try Oracle.check("ultrathink") { ComposerSubmission.isUltrathinkPrompt($0.string("text")) }
  }
}
