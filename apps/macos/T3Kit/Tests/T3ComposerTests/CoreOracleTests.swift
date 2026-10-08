import Foundation
import Testing

@testable import T3Composer

private func segmentJSON(_ segment: ComposerPromptSegment) throws -> Any {
  switch segment {
  case .text(let text): return ["type": "text", "text": text]
  case .mention(let path, let source): return ["type": "mention", "path": path, "source": source]
  case .skill(let name, let source): return ["type": "skill", "name": name, "source": source]
  case .citation(let citation, let source): return ["type": "citation", "citation": try json(citation), "source": source]
  case .contextReference(let kind, let contextId, let label, let source):
    return ["type": "context-reference", "kind": kind, "contextId": contextId, "label": label, "source": source]
  }
}

private func triggerJSON(_ trigger: ComposerTrigger?) -> Any {
  guard let trigger else { return NSNull() }
  return ["kind": trigger.kind.rawValue, "query": trigger.query, "rangeStart": trigger.rangeStart, "rangeEnd": trigger.rangeEnd]
}

private func tokenJSON(_ token: ComposerInlineToken) -> [String: Any] {
  ["type": token.kind.rawValue, "value": token.value, "source": token.source, "start": token.start, "end": token.end]
}

@Suite("Composer core oracle") struct CoreOracleTests {
  @Test func segments() throws {
    try Oracle.check("segments") { input in try ComposerPromptSegments.split(input.string("text")).map(segmentJSON) }
  }

  @Test func inlineTokens() throws {
    try Oracle.check("inlineTokens") { input in
      let text = input.string("text")
      var preserve: [ComposerInlineToken] = []
      if input.optionalBool("preserve") == true {
        let source = "@a.ts"
        let start = text.jsLength - source.jsLength
        preserve = [ComposerInlineToken(kind: .mention, value: "a.ts", source: source, start: start, end: start + 5)]
      }
      return ComposerInlineTokens.collect(text, preserveTrailingFrom: preserve).map(tokenJSON)
    }
  }

  @Test func promptTokens() throws {
    try Oracle.check("promptTokens") { input in
      try ComposerPromptSegments.collectTokens(input.string("text")).map { token -> [String: Any] in
        var out: [String: Any] = ["source": token.source, "start": token.start, "end": token.end]
        switch token.payload {
        case .mention(let path): out["type"] = "mention"; out["value"] = path
        case .skill(let name): out["type"] = "skill"; out["value"] = name
        case .citation(let citation): out["type"] = "citation"; out["citation"] = try json(citation)
        case .contextReference(let kind, let contextId, let label):
          out["type"] = "context-reference"; out["kind"] = kind; out["contextId"] = contextId; out["label"] = label
        }
        return out
      }
    }
  }

  @Test func selectionBoundary() throws {
    try Oracle.check("selectionBoundary") { input in
      ComposerPromptSegments.selectionTouchesMentionBoundary(input.string("text"), start: input.int("start"), end: input.int("end"))
    }
  }

  @Test func triggers() throws {
    try Oracle.check("triggers") { input in
      let text = input.string("text")
      let cursor = input.int("cursor")
      return [
        "web": triggerJSON(ComposerLogic.detectTrigger(text, cursor)),
        "shared": triggerJSON(ComposerLogic.detectSharedTrigger(text, cursor)),
      ]
    }
  }

  @Test func cursorSpaces() throws {
    try Oracle.check("cursors") { input in
      let text = input.string("text")
      let cursor = input.int("cursor")
      return [
        "expand": ComposerLogic.expandCollapsedCursor(text, cursor),
        "collapse": ComposerLogic.collapseExpandedCursor(text, cursor),
        "clamp": ComposerLogic.clampCollapsedCursor(text, cursor),
        "adjacentLeft": ComposerLogic.isCollapsedCursorAdjacentToInlineToken(text, cursor, .left),
        "adjacentRight": ComposerLogic.isCollapsedCursorAdjacentToInlineToken(text, cursor, .right),
      ]
    }
    try Oracle.check("promptEnd") { input in
      let state = ComposerLogic.stateAtPromptEnd(input.string("text"))
      return ["cursor": state.cursor, "trigger": triggerJSON(state.trigger)]
    }
  }

  @Test func slashCommandsAndRanges() throws {
    try Oracle.check("slashCommand") { input in ComposerLogic.parseStandaloneSlashCommand(input.string("text"))?.rawValue }
    try Oracle.check("replaceTextRange") { input in
      let result = ComposerLogic.replaceTextRange(
        input.string("text"), rangeStart: input.int("start"), rangeEnd: input.int("end"), replacement: input.string("replacement"))
      return ["text": result.text, "cursor": result.cursor]
    }
  }

  @Test func submitIntent() throws {
    try Oracle.check("submitIntent") { input in
      ComposerLogic.submissionIntentForEnter(
        isMobileViewport: input.bool("isMobileViewport"), shiftKey: input.bool("shiftKey"), modifierKey: input.bool("modifierKey"),
        isDraftThread: input.bool("isDraftThread"), isRunning: input.bool("isRunning"),
        sendShortcut: input.optionalString("sendShortcut").flatMap(SendShortcut.init(rawValue:)), prompt: input.string("prompt"))?.rawValue
    }
  }

  @Test func fileLinks() throws {
    try Oracle.check("fileLink") { input in
      let link = ComposerMenu.fileLink(forPath: input.string("path"))
      return ["link": link, "tokens": ComposerInlineTokens.collect(link + " ").map(tokenJSON)]
    }
  }

  @Test func listContinuation() throws {
    func edit(_ edit: ComposerListEdit?) -> Any {
      guard let edit else { return NSNull() }
      return ["start": edit.start, "end": edit.end, "replacement": edit.replacement]
    }
    try Oracle.check("listEnter") { input in edit(ComposerListContinuation.forEnter(input.string("text"), input.int("cursor"))) }
    try Oracle.check("listTab") { input in
      edit(ComposerListContinuation.indentForTab(input.string("text"), start: input.int("start"), end: input.int("end")))
    }
  }
}
