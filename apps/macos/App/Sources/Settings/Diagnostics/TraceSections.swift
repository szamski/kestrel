import AppKit
import SwiftUI
import T3ClientRuntime
import T3Contracts

private struct Indexed<Value>: Identifiable {
  let id: Int
  let value: Value
}

private func indexed<Value>(_ values: [Value]) -> [Indexed<Value>] { values.enumerated().map { Indexed(id: $0.offset, value: $0.element) } }

/// "Trace diagnostics": what the server's trace file says about spans, failures and slow work, then the lists behind it.
struct TraceSections: View {
  let controller: DiagnosticsController

  var body: some View {
    let panel = controller.trace
    let data = panel.value
    summary(panel, data)
    if let data {
      list("Latest failures", empty: "No failed spans found.", indexed(data.latestFailures)) {
        Table($0) {
          TableColumn("Span") { Text($0.value.name).lineLimit(1) }.width(min: 100, ideal: 170)
          TableColumn("Cause") { cause($0.value.cause) }.width(min: 100, ideal: 240)
          TableColumn("Duration") { number(DiagnosticsFormat.duration(ms: $0.value.durationMs)) }.width(min: 52, ideal: 64)
          TableColumn("Ended") { ago($0.value.endedAt) }.width(min: 70, ideal: 90)
        }
      }
      list("Most common failures", empty: "No repeated failures found.", indexed(data.commonFailures)) {
        Table($0) {
          TableColumn("Span") { Text($0.value.name).lineLimit(1) }.width(min: 100, ideal: 170)
          TableColumn("Count") { number(DiagnosticsFormat.count($0.value.count)) }.width(min: 44, ideal: 52)
          TableColumn("Cause") { cause($0.value.cause) }.width(min: 100, ideal: 240)
          TableColumn("Last seen") { ago($0.value.lastSeenAt) }.width(min: 70, ideal: 90)
        }
      }
      list("Slowest spans", empty: "No spans found.", indexed(data.slowestSpans)) {
        Table($0) {
          TableColumn("Span") { Text($0.value.name).lineLimit(1) }.width(min: 120, ideal: 210)
          TableColumn("Duration") { number(DiagnosticsFormat.duration(ms: $0.value.durationMs)) }.width(min: 52, ideal: 64)
          TableColumn("Ended") { ago($0.value.endedAt) }.width(min: 70, ideal: 90)
          TableColumn("Trace") { TraceIdCell(traceId: $0.value.traceId) }.width(min: 150, ideal: 230)
        }
      }
      list("Span logs", empty: "No warnings or errors found.", indexed(data.latestWarningAndErrorLogs)) {
        Table($0) {
          TableColumn("Time") { ago($0.value.seenAt) }.width(min: 70, ideal: 90)
          TableColumn("Level") { Text($0.value.level.uppercased()).font(.caption.monospaced()) }.width(min: 44, ideal: 50)
          TableColumn("Span") { Text($0.value.spanName).lineLimit(1) }.width(min: 90, ideal: 130)
          TableColumn("Message") { cause($0.value.message) }.width(min: 100, ideal: 180)
          TableColumn("Trace") { TraceIdCell(traceId: $0.value.traceId) }.width(min: 150, ideal: 200)
        }
      }
      list("Top span names", empty: "No spans found.", indexed(data.topSpansByCount)) {
        Table($0) {
          TableColumn("Span") { Text($0.value.name).lineLimit(1) }.width(min: 120, ideal: 280)
          TableColumn("Count") { number(DiagnosticsFormat.count($0.value.count)) }.width(min: 44, ideal: 60)
          TableColumn("Failures") { number(DiagnosticsFormat.count($0.value.failureCount)) }.width(min: 44, ideal: 60)
          TableColumn("Average") { number(DiagnosticsFormat.duration(ms: $0.value.averageDurationMs)) }.width(min: 52, ideal: 66)
          TableColumn("Max") { number(DiagnosticsFormat.duration(ms: $0.value.maxDurationMs)) }.width(min: 52, ideal: 66)
        }
      }
    }
  }

  private func summary(_ panel: Panel<ServerTraceDiagnosticsResult>, _ data: ServerTraceDiagnosticsResult?) -> some View {
    Section {
      if let error = panel.error { ErrorLine(message: error) }
      if let problem = data?.error {
        ErrorLine(
          message: data?.partialFailure == true ? "Some trace files could not be read, so diagnostics may be incomplete. \(problem.message)" : problem.message,
          warning: data?.partialFailure == true)
      }
      StatGrid {
        StatTile(title: "Spans", value: data.map { DiagnosticsFormat.count($0.recordCount) } ?? "...")
        StatTile(title: "Failures", value: data.map { DiagnosticsFormat.count($0.failureCount) } ?? "...", tone: (data?.failureCount ?? 0) > 0 ? .danger : .normal)
        StatTile(
          title: "Slow spans", value: data.map { DiagnosticsFormat.count($0.slowSpanCount) } ?? "...",
          detail: data.map { "At or above \(DiagnosticsFormat.duration(ms: Double($0.slowSpanThresholdMs)))" }, tone: (data?.slowSpanCount ?? 0) > 0 ? .warning : .normal)
        StatTile(title: "Parse errors", value: data.map { DiagnosticsFormat.count($0.parseErrorCount) } ?? "...", tone: (data?.parseErrorCount ?? 0) > 0 ? .warning : .normal)
      }
      if let config = controller.config { PanelNote(text: DiagnosticsLogic.observabilitySummary(config.observability)) }
    } header: {
      PanelHeader(title: "Trace diagnostics") {
        Button { controller.openLogs() } label: { Image(systemName: "folder") }
          .buttonStyle(.borderless).disabled(!controller.canOpenLogs)
          .help(logsHelp).accessibilityLabel("Open logs folder")
        RefreshControls(checkedAt: data?.readAt, loading: panel.loading, label: "Refresh trace diagnostics") { controller.refreshTrace() }
      }
    }
  }

  private var logsHelp: String {
    if !controller.isLocal { return "Logs are on \(controller.environmentLabel), not on this Mac." }
    return (controller.logsDirectory ?? "").isEmpty ? "This server did not report a logs folder." : "Open the logs folder in Finder"
  }

  private func list<Value, Rows: View>(_ title: String, empty: String, _ rows: [Indexed<Value>], @ViewBuilder table: ([Indexed<Value>]) -> Rows) -> some View {
    Section(title) {
      if rows.isEmpty {
        PanelNote(text: controller.trace.loading ? "Loading." : empty)
      } else {
        table(rows).alternatingRowBackgrounds().tableHeight(rows: rows.count, maxRows: 8)
      }
    }
  }

  private func number(_ text: String) -> some View { Text(text).monospacedDigit().lineLimit(1) }

  private func ago(_ date: IsoDateTime) -> some View { Text("\(date.instant, style: .relative) ago").foregroundStyle(.secondary).lineLimit(1) }

  private func cause(_ text: String) -> some View { Text(text).lineLimit(1).foregroundStyle(.secondary).textSelection(.enabled).help(text) }
}

/// A shortened trace ID with a copy button.
private struct TraceIdCell: View {
  let traceId: String
  @State private var copied = false

  var body: some View {
    HStack(spacing: 6) {
      Text(DiagnosticsFormat.shortTrace(traceId)).font(.caption.monospaced()).lineLimit(1).help(traceId)
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(traceId, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
      } label: {
        Image(systemName: copied ? "checkmark" : "doc.on.doc").imageScale(.small)
      }
      .buttonStyle(.borderless).help(copied ? "Copied" : "Copy full trace ID").accessibilityLabel(copied ? "Copied trace ID" : "Copy trace ID")
    }
  }
}
