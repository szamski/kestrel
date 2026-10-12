import SwiftUI
import T3ClientRuntime
import T3Contracts

/// A process tree: parents above their children, siblings in the chosen sort order, branches that collapse, and INT / KILL
/// per row behind a confirmation (decided by the page). Both process lists of the web page use it; `showsIO` adds the
/// columns that only the telemetry stream measures.
struct ProcessTable: View {
  let controller: DiagnosticsController
  let rows: [ProcessTreeRow]
  let source: PendingSignal.Source
  var showsIO = false
  let emptyText: String

  @State private var sort = [KeyPathComparator(\ProcessTreeRow.cpuPercent, order: .reverse)]
  @State private var collapsed: Set<String> = []

  var body: some View {
    if rows.isEmpty {
      PanelNote(text: emptyText)
    } else {
      let flat = ProcessTree.flatten(rows, collapsed: collapsed, order: sort)
      Table(flat, sortOrder: $sort) {
        TableColumn("Process", value: \.name) { row in name(row) }.width(min: 100, ideal: 130)
        TableColumn("Type", value: \.kind) { row in Text(row.kind).foregroundStyle(.secondary) }.width(min: 60, ideal: 84)
        TableColumn("CPU", value: \.cpuPercent) { row in number(DiagnosticsFormat.percent(row.cpuPercent)) }.width(min: 40, ideal: 48)
        TableColumn("Memory", value: \.memoryBytes) { row in number(DiagnosticsFormat.bytes(row.memoryBytes)) }.width(min: 56, ideal: 66)
        if showsIO {
          TableColumn("Read/s", value: \.readBytesPerSecond) { row in number(row.hasIO ? DiagnosticsFormat.rate(row.readBytesPerSecond) : "-") }.width(min: 56, ideal: 64)
          TableColumn("Write/s", value: \.writeBytesPerSecond) { row in number(row.hasIO ? DiagnosticsFormat.rate(row.writeBytesPerSecond) : "-") }.width(min: 56, ideal: 64)
        }
        TableColumn("PID", value: \.pid) { row in number(String(row.pid)).foregroundStyle(.secondary) }.width(min: 52, ideal: 60)
        TableColumn("Signal") { row in signals(row) }.width(min: 72, ideal: 80)
      }
      .alternatingRowBackgrounds()
      .tableHeight(rows: flat.count, maxRows: 14)
    }
  }

  private func name(_ row: ProcessTreeRow) -> some View {
    HStack(spacing: 4) {
      Color.clear.frame(width: CGFloat(min(row.depth, 7)) * 12, height: 1)
      if row.hasChildren {
        Button {
          if collapsed.contains(row.id) { collapsed.remove(row.id) } else { collapsed.insert(row.id) }
        } label: {
          Image(systemName: collapsed.contains(row.id) ? "chevron.right" : "chevron.down").imageScale(.small).frame(width: 12)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("\(collapsed.contains(row.id) ? "Expand" : "Collapse") \(row.name)")
      } else {
        Color.clear.frame(width: 12, height: 1)
      }
      Text(row.name).lineLimit(1)
    }
    .help(row.command)
  }

  private func number(_ text: String) -> some View {
    Text(text).monospacedDigit().lineLimit(1)
  }

  @ViewBuilder private func signals(_ row: ProcessTreeRow) -> some View {
    if row.canSignal {
      let disabled = !controller.canMaintain || controller.signaling.contains(row.id)
      HStack(spacing: 6) {
        Button("INT") { controller.request(.SIGINT, for: row, from: source) }.help("Send SIGINT to \(row.name)")
        Button("KILL", role: .destructive) { controller.request(.SIGKILL, for: row, from: source) }.help("Send SIGKILL to \(row.name)")
      }
      .buttonStyle(.borderless).font(.caption.weight(.medium)).disabled(disabled)
    } else {
      Text("-").foregroundStyle(.tertiary)
    }
  }
}
