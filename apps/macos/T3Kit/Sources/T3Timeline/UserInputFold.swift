import Foundation
import T3Contracts

// Port of packages/client-runtime/src/work-log/userInput.ts (+ projectQuestionToolInput from
// packages/shared/src/toolActivity.ts): a question and its answer appear once, at the position
// of the original request, instead of as three separate activities.

private func record(_ value: JSONValue?) -> JSObject? { value.strictRecord }

private func displayOptionAnswer(_ value: JSONValue, labels: [String: String]) -> JSONValue {
  switch value {
  case .string(let text): return .string(labels[text] ?? text)
  case .array(let items): return .array(items.map { displayOptionAnswer($0, labels: labels) })
  case .object(var nested):
    if let answers = nested["answers"] { nested["answers"] = displayOptionAnswer(answers, labels: labels) }
    return .object(nested)
  default: return value
  }
}

private struct QuestionFingerprint: Hashable {
  var turnId: String
  var texts: [String]
}

private func questionFingerprint(turnId: String, questions: [JSONValue?]) -> QuestionFingerprint? {
  let texts = questions.map { $0?.stringOrNil?.jsTrimmed ?? "" }
  return !texts.isEmpty && texts.allSatisfy({ !$0.isEmpty }) ? QuestionFingerprint(turnId: turnId, texts: jsCodeUnitSorted(texts)) : nil
}

private func hasTurn(_ activity: OrchestrationThreadActivity) -> String? {
  guard let turnId = activity.turnId?.rawValue, !turnId.isEmpty else { return nil }
  return turnId
}

/// `projectQuestionToolInput(data, title).input?.questions`: the canonical question texts of a
/// native question tool call, or nil when the call is not a question tool.
func questionToolQuestions(data: JSObject, title: JSONValue?) -> [JSONValue?]? {
  let item = record(data["item"])
  let toolName =
    [data["toolName"], data["tool"], item?["tool"], title].compactMap { $0 }.first { !$0.isNullish }
  guard case .string(let name)? = toolName else { return nil }
  let lastSegment = name.components(separatedBy: CharacterSet(charactersIn: "./")).flatMap { $0.components(separatedBy: "__") }.last ?? ""
  let normalized = lastSegment.filter { !isJSWhitespace($0.unicodeScalars.first!) && $0 != "_" }.lowercased()
  guard normalized.matches("^(askuserquestion|requestuserinput(?:async)?|askquestion|question)$") else { return nil }
  let inputSource = [data["input"], data["rawInput"], record(data["state"])?["input"], item?["arguments"]]
    .compactMap { $0 }.first { !$0.isNullish }
  let input = record(inputSource)
  let questions = input?["questions"].flatMap { $0.isNullish ? nil : $0 } ?? record(input?["params"])?["questions"]
  guard let list = questions?.arrayOrNil else { return nil }
  return list.map { value -> JSONValue? in
    let question = record(value)
    for key in ["question", "question_text", "prompt", "title"] {
      if let candidate = question?[key], !candidate.isNullish { return candidate.trimmedString.map { .string($0) } }
    }
    return nil
  }
}

private func withoutDuplicateQuestionTools(_ activities: [OrchestrationThreadActivity]) -> [OrchestrationThreadActivity] {
  var questions = Set<QuestionFingerprint>()
  for activity in activities where activity.kind == "user-input.answer-submitted" {
    guard let turnId = hasTurn(activity) else { continue }
    let texts = record(record(activity.payload)?["questionTextById"]).map { Array($0.values) } ?? []
    if let fingerprint = questionFingerprint(turnId: turnId, questions: texts) { questions.insert(fingerprint) }
  }
  if questions.isEmpty { return activities }
  struct ToolKey: Hashable {
    var turnId: String
    var toolCallId: String
  }
  var duplicateToolIds = Set<ToolKey>()
  for activity in activities where activity.kind.hasPrefix("tool.") {
    guard let turnId = hasTurn(activity), let payload = record(activity.payload), let toolCallId = payload["toolCallId"]?.stringOrNil,
      let list = questionToolQuestions(data: record(payload["data"]) ?? [:], title: payload["title"])
    else { continue }
    if let fingerprint = questionFingerprint(turnId: turnId, questions: list), questions.contains(fingerprint) {
      duplicateToolIds.insert(ToolKey(turnId: turnId, toolCallId: toolCallId))
    }
  }
  return activities.filter { activity in
    let payload = record(activity.payload)
    let toolCallId = payload?["toolCallId"]?.stringOrNil
    let status = jsString(payload?["status"])
    return activity.tone == .error || ["failed", "declined", "stopped", "cancelled"].contains(status)
      || !activity.kind.hasPrefix("tool.") || toolCallId == nil
      // The key is stringified JSON of [turnId, toolCallId]; a missing turn is `null`.
      || !duplicateToolIds.contains(ToolKey(turnId: activity.turnId?.rawValue ?? "\u{0}null", toolCallId: toolCallId!))
  }
}

/// Keep a question and its answer at the original tool position in the work log.
func foldUserInputActivities(_ activities: [OrchestrationThreadActivity]) -> [OrchestrationThreadActivity] {
  var groupOrder: [String] = []
  var groups: [String: [Int]] = [:]
  for (index, activity) in activities.enumerated() {
    guard ["user-input.requested", "user-input.resolved", "user-input.answer-submitted"].contains(activity.kind),
      let requestId = record(activity.payload)?["requestId"]?.stringOrNil, !requestId.isEmpty
    else { continue }
    if groups[requestId] == nil { groupOrder.append(requestId) }
    groups[requestId, default: []].append(index)
  }
  var replacements: [Int: OrchestrationThreadActivity] = [:]
  var removed = Set<Int>()
  for requestId in groupOrder {
    let group = groups[requestId]!
    let payloads = group.map { record(activities[$0].payload)! }
    var questions: [String: JSObject] = [:]
    var texts: [(key: String, value: JSONValue)] = []
    func setText(_ id: String, _ value: JSONValue) {
      if let index = texts.firstIndex(where: { $0.key == id }) { texts[index].value = value } else { texts.append((id, value)) }
    }
    for payload in payloads {
      for (id, text) in record(payload["questionTextById"]) ?? [:] { setText(id, text) }
      for value in payload["questions"]?.arrayOrNil ?? [] {
        guard let question = record(value), let id = question["id"]?.stringOrNil else { continue }
        questions[id] = question
        if let text = question["question"]?.stringOrNil { setText(id, .string(text)) }
      }
    }
    let questionTextById = JSObject(texts.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
    let submitted = group.last { index in
      activities[index].kind == "user-input.answer-submitted" && record(record(activities[index].payload)?["answers"]) != nil
    }
    let rawAnswers =
      record(record(submitted.map { activities[$0].payload })?["answers"])
      ?? payloads.compactMap { record($0["answers"]) }.last ?? [:]
    var answers = JSObject()
    for (id, value) in rawAnswers {
      var labels: [String: String] = [:]
      for candidate in questions[id]?["options"]?.arrayOrNil ?? [] {
        if let option = record(candidate), let optionValue = option["value"]?.stringOrNil, let label = option["label"]?.stringOrNil {
          labels[optionValue] = label
        }
      }
      answers[id] = displayOptionAnswer(value, labels: labels)
    }
    var attachmentsByQuestionId = JSObject()
    for payload in payloads { for (id, value) in record(payload["attachmentsByQuestionId"]) ?? [:] { attachmentsByQuestionId[id] = value } }
    let answer: JSONValue = .object([
      "requestId": .string(requestId),
      "questionTextById": .object(questionTextById),
      "answers": .object(answers),
      "attachmentsByQuestionId": .object(attachmentsByQuestionId),
    ])
    guard let data = try? JSONEncoder().encode(answer), (try? JSONDecoder().decode(UserInputAnswer.self, from: data)) != nil else {
      continue
    }
    let submittedAnswer = !answers.isEmpty || !attachmentsByQuestionId.isEmpty
    removed.formUnion(group)
    var leader = activities[group[0]]
    leader.kind = "user-input.answer-submitted"
    leader.tone = .tool
    leader.summary =
      submittedAnswer
      ? "User input submitted"
      : group.contains { activities[$0].kind == "user-input.resolved" } ? "User input dismissed" : "User input requested"
    leader.payload = answer
    replacements[group[0]] = leader
  }
  var folded: [OrchestrationThreadActivity] = []
  folded.reserveCapacity(activities.count)
  for (index, activity) in activities.enumerated() {
    if let replacement = replacements[index] {
      folded.append(replacement)
    } else if !removed.contains(index) {
      folded.append(activity)
    }
  }
  return withoutDuplicateQuestionTools(folded)
}
