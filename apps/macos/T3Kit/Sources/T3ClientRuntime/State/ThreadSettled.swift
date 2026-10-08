import Foundation
import T3Contracts

/// Port of `state/threadSettled.ts`: queued turn starts, snooze overlay, wake detection and the
/// snooze menu presets. All timestamps are ISO strings; `now` is passed in, never read.
public enum ThreadSettled {
  /// A queued turn start lives at most this long: a user message still unadopted after the
  /// grace window is a failed start (or stale data), not pending work.
  public static let queuedTurnStartGraceMs = 2.0 * 60 * 1000

  private static func ms(_ value: IsoDateTime?) -> Double { value.flatMap(IsoTimestamp.parse) ?? .nan }

  /// A user message no turn has picked up yet, within the adoption grace window.
  public static func hasQueuedTurnStart(_ shell: OrchestrationThreadShell, now: IsoDateTime) -> Bool {
    guard let latestUserMessageAt = shell.latestUserMessageAt else { return false }
    if shell.session?.status == .error { return false }
    guard let messageAt = IsoTimestamp.parse(latestUserMessageAt), let nowMs = IsoTimestamp.parse(now) else { return false }
    // Bounded on both sides: a device clock ahead of ours must not hold the state for the skew.
    if abs(nowMs - messageAt) > queuedTurnStartGraceMs { return false }
    guard let turn = shell.latestTurn else { return true }
    return [turn.requestedAt, turn.startedAt, turn.completedAt].allSatisfy { candidate in
      guard let candidate else { return true }
      return ms(candidate) < messageAt
    }
  }

  /// Something outranks the user's snooze: the agent is blocked, the session failed after the
  /// snooze, or a run completed after the snooze was set.
  public static func threadRaisedHandWhileSnoozed(_ shell: OrchestrationThreadShell) -> Bool {
    if shell.hasPendingApprovals || shell.hasPendingUserInput { return true }
    let snoozedAt = optionalValue(shell.snoozedAt)
    if shell.session?.status == .error, snoozedAt == nil || ms(shell.session?.updatedAt) > ms(snoozedAt) { return true }
    if let snoozedAt, shell.latestTurn?.state == .completed, let completedAt = shell.latestTurn?.completedAt,
      ms(completedAt) > ms(snoozedAt)
    {
      return true
    }
    return false
  }

  /// A thread may be snoozed unless the agent is blocked on the user or a turn start is queued.
  public static func canSnooze(_ shell: OrchestrationThreadShell, now: IsoDateTime) -> Bool {
    if shell.hasPendingApprovals || shell.hasPendingUserInput { return false }
    return !hasQueuedTurnStart(shell, now: now)
  }

  /// Hidden from the inbox while the wake time is in the future and the thread has not raised its hand.
  public static func effectiveSnoozed(_ shell: OrchestrationThreadShell, now: IsoDateTime) -> Bool {
    guard let until = optionalValue(shell.snoozedUntil) else { return false }
    let wakeAt = ms(until)
    if wakeAt.isNaN { return false }  // malformed data never hides a thread
    if wakeAt <= ms(now) { return false }
    return !threadRaisedHandWhileSnoozed(shell)
  }

  /// When a previously snoozed thread woke, or nil when it never snoozed / is still snoozed.
  public static func threadWokeAt(_ shell: OrchestrationThreadShell, now: IsoDateTime) -> IsoDateTime? {
    guard let until = optionalValue(shell.snoozedUntil) else { return nil }
    let wakeAt = ms(until)
    if wakeAt.isNaN { return nil }
    if threadRaisedHandWhileSnoozed(shell) {
      let snoozedAt = optionalValue(shell.snoozedAt)
      if let snoozedAt, shell.latestTurn?.state == .completed, let completedAt = shell.latestTurn?.completedAt,
        ms(completedAt) > ms(snoozedAt)
      {
        return completedAt
      }
      return shell.session?.updatedAt ?? snoozedAt
    }
    return wakeAt <= ms(now) ? until : nil
  }

  // MARK: Presets

  public enum PresetId: String, Sendable, Codable { case hour, threeHours = "three-hours", evening, tomorrow, nextWeek = "next-week" }

  public struct Preset: Sendable, Hashable, Identifiable {
    public let id: PresetId
    public let label: String
    /// Menu-row time column ("9:00 AM"); localized, so tests compare `snoozedUntil` only.
    public let whenLabel: String
    public let snoozedUntil: IsoDateTime
  }

  private static let hourMs = 3_600_000.0
  private static let eveningHour = 18
  private static let morningHour = 9

  /// "In 1 hour", "In 3 hours", "This evening" (only while meaningfully before evening),
  /// "Tomorrow" 9:00 and "Next week" (Monday 9:00, collapsed when it equals Tomorrow).
  public static func resolveSnoozePresets(now: Date, calendar: Calendar = .current) -> [Preset] {
    func at(_ date: Date, hour: Int) -> Date {
      calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date, matchingPolicy: .nextTime) ?? date
    }
    func iso(_ date: Date) -> IsoDateTime { IsoTimestamp.format(milliseconds: (date.timeIntervalSince1970 * 1000).rounded(.down)) }
    func time(_ date: Date) -> String { date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(.current)) }
    let inAnHour = now.addingTimeInterval(3600), inThree = now.addingTimeInterval(3 * 3600)
    var presets = [
      Preset(id: .hour, label: "In 1 hour", whenLabel: time(inAnHour), snoozedUntil: iso(inAnHour)),
      Preset(id: .threeHours, label: "In 3 hours", whenLabel: time(inThree), snoozedUntil: iso(inThree)),
    ]
    let evening = at(now, hour: eveningHour)
    if (evening.timeIntervalSince(now) * 1000) > hourMs {
      presets.append(Preset(id: .evening, label: "This evening", whenLabel: time(evening), snoozedUntil: iso(evening)))
    }
    // Calendar-day advance, not +24h: fixed offsets land on the wrong local day across DST.
    let tomorrow = at(calendar.date(byAdding: .day, value: 1, to: now) ?? now, hour: morningHour)
    presets.append(Preset(id: .tomorrow, label: "Tomorrow", whenLabel: time(tomorrow), snoozedUntil: iso(tomorrow)))
    let weekday = calendar.component(.weekday, from: now) - 1  // JS getDay(): Sunday = 0
    let daysUntilMonday = (1 - weekday + 7) % 7 == 0 ? 7 : (1 - weekday + 7) % 7
    let nextWeek = at(calendar.date(byAdding: .day, value: daysUntilMonday, to: now) ?? now, hour: morningHour)
    if iso(nextWeek) != iso(tomorrow) {
      let day = nextWeek.formatted(Date.FormatStyle().weekday(.abbreviated))
      presets.append(Preset(id: .nextWeek, label: "Next week", whenLabel: "\(day) \(time(nextWeek))", snoozedUntil: iso(nextWeek)))
    }
    return presets
  }

  /// Compact "wakes in" label for snoozed rows: "2h", "18h", "3d". Minutes round up.
  public static func snoozeWakeLabel(_ snoozedUntil: IsoDateTime, now: IsoDateTime) -> String {
    let wake = ms(snoozedUntil), nowMs = ms(now)
    if wake.isNaN || nowMs.isNaN { return "now" }
    let remaining = wake - nowMs
    if remaining <= 0 { return "now" }
    if remaining < hourMs { return "\(max(1, Int((remaining / 60_000).rounded(.up))))m" }
    if remaining < 24 * hourMs { return "\(Int((remaining / hourMs).rounded(.up)))h" }
    return "\(Int((remaining / (24 * hourMs)).rounded(.up)))d"
  }

  public enum CustomSnoozeInput: Sendable {
    case date(date: String, time: String)  // "YYYY-MM-DD", "HH:mm" in the local calendar
    case duration(amount: String, unit: DurationUnit)
    public enum DurationUnit: String, Sendable { case minutes, hours, days }
  }

  /// Resolves local calendar input or elapsed time, rejecting past and invalid dates (nil).
  public static func resolveCustomSnooze(_ input: CustomSnoozeInput, now: Date, calendar: Calendar = .current) -> IsoDateTime? {
    let wake: Date
    switch input {
    case .duration(let amountText, let unit):
      guard let amount = Double(amountText.trimmingCharacters(in: .whitespaces)), amount.isFinite, amount > 0 else { return nil }
      let unitSeconds: Double = [.minutes: 60, .hours: 3600, .days: 86_400][unit]!
      wake = now.addingTimeInterval(amount * unitSeconds)
    case .date(let date, let time):
      let d = date.split(separator: "-", omittingEmptySubsequences: false), t = time.split(separator: ":", omittingEmptySubsequences: false)
      guard d.count == 3, d[0].count == 4, d[1].count == 2, d[2].count == 2, t.count == 2, t[0].count == 2, t[1].count == 2,
        let y = Int(d[0]), let mo = Int(d[1]), let day = Int(d[2]), let h = Int(t[0]), let mi = Int(t[1])
      else { return nil }
      var parts = DateComponents(year: y, month: mo, day: day, hour: h, minute: mi, second: 0)
      parts.calendar = calendar
      guard let candidate = calendar.date(from: parts) else { return nil }
      // Reject rolled-over dates and nonexistent local times during DST changes.
      let back = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: candidate)
      guard back.year == y, back.month == mo, back.day == day, back.hour == h, back.minute == mi else { return nil }
      wake = candidate
    }
    guard wake > now else { return nil }
    return IsoTimestamp.format(milliseconds: (wake.timeIntervalSince1970 * 1000).rounded(.down))
  }
}

/// `field` is `T??` on the wire models: absent and null both mean "not set".
func optionalValue<T>(_ value: T??) -> T? {
  switch value {
  case .some(.some(let v)): v
  default: nil
  }
}
