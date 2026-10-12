import Charts
import SwiftUI
import T3ClientRuntime
import T3Contracts

/// One point of a timeline series.
private struct Point: Identifiable {
  let id: String
  let series: String
  let start: Date
  let end: Date
  let value: Double
  init(_ series: String, _ start: Date, _ end: Date, _ value: Double) {
    (self.series, self.start, self.end, self.value) = (series, start, end, value)
    id = "\(series)@\(start.timeIntervalSince1970)"
  }
}

private struct Bucket {
  let start: Date
  let end: Date
  var cpuAverage = 0.0, cpuPeak = 0.0, memoryPeak = 0.0, read = 0.0, write = 0.0
}

/// A bucketed timeline chart. It takes plain values, so it is redrawn only when the page hands it a new history (once
/// per bucket at most), and hovering marks the bucket under the pointer.
private struct TimelineChart: View {
  let title: String
  let points: [Point]
  let buckets: [Bucket]
  @Binding var selected: Date?
  var stacked = false
  var format: (Double) -> String
  var summary: (Bucket) -> String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      Chart {
        ForEach(points) { point in
          if stacked {
            BarMark(xStart: .value("Start", point.start), xEnd: .value("End", point.end), y: .value(title, point.value))
              .foregroundStyle(by: .value("Series", point.series))
          } else {
            LineMark(x: .value("Time", point.start), y: .value(title, point.value), series: .value("Series", point.series))
              .foregroundStyle(by: .value("Series", point.series))
              .interpolationMethod(.monotone)
            // A line needs two points; a history that is just starting has one.
            if buckets.count < 3 { PointMark(x: .value("Time", point.start), y: .value(title, point.value)).foregroundStyle(by: .value("Series", point.series)) }
          }
        }
        if let bucket = nearest {
          RuleMark(x: .value("Selected", bucket.start))
            .foregroundStyle(.secondary.opacity(0.5))
            .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
              Text(summary(bucket)).font(.caption2).padding(4).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            }
        }
      }
      .chartXSelection(value: $selected)
      .chartYScale(domain: .automatic(includesZero: true))
      .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { if let v = value.as(Double.self) { Text(format(v)) } } } }
      .chartLegend(position: .top, alignment: .trailing)
      .frame(height: 110)
      .transaction { $0.animation = nil }
    }
  }

  private var nearest: Bucket? {
    guard let selected else { return nil }
    return buckets.min { abs($0.start.timeIntervalSince(selected)) < abs($1.start.timeIntervalSince(selected)) }
  }
}

/// "Resource timeline": CPU, memory and I/O of everything T3 runs, from the server's native history, plus the busiest
/// processes of the window. The server keeps no thermal or power history, so that chart only has what this page saw live.
struct TimelineSection: View {
  @Bindable var controller: DiagnosticsController
  @State private var selected: Date?

  var body: some View {
    let panel = controller.history
    Section {
      if let error = panel.error { ErrorLine(message: error) }
      if let history = panel.value {
        let buckets = history.buckets.filter { $0.maxProcessCount > 0 }.map {
          Bucket(
            start: $0.startedAt.instant, end: $0.endedAt.instant, cpuAverage: $0.avgCpuPercent, cpuPeak: $0.maxCpuPercent, memoryPeak: Double($0.maxRssBytes), read: Double($0.ioReadBytes),
            write: Double($0.ioWriteBytes))
        }
        if buckets.isEmpty {
          PanelNote(text: "No retained samples in this window yet.")
        } else {
          TimelineChart(
            title: "CPU", points: buckets.flatMap { [Point("Average", $0.start, $0.end, $0.cpuAverage), Point("Peak", $0.start, $0.end, $0.cpuPeak)] }, buckets: buckets, selected: $selected,
            format: { "\(Int($0))%" }, summary: { "Avg \(DiagnosticsFormat.percent($0.cpuAverage)), peak \(DiagnosticsFormat.percent($0.cpuPeak))" })
          TimelineChart(
            title: "Memory", points: buckets.map { Point("Peak memory", $0.start, $0.end, $0.memoryPeak) }, buckets: buckets, selected: $selected,
            format: { DiagnosticsFormat.bytes(Int($0)) }, summary: { "Peak \(DiagnosticsFormat.bytes(Int($0.memoryPeak)))" })
          TimelineChart(
            title: "I/O", points: buckets.flatMap { [Point("Reads", $0.start, $0.end, $0.read), Point("Writes", $0.start, $0.end, $0.write)] }, buckets: buckets, selected: $selected, stacked: true,
            format: { DiagnosticsFormat.bytes(Int($0)) }, summary: { "Read \(DiagnosticsFormat.bytes(Int($0.read))), write \(DiagnosticsFormat.bytes(Int($0.write)))" })
        }
      } else if panel.error == nil {
        PanelNote(text: "Collecting resource history.")
      }
      SpeedLimitView(controller: controller)
      if let processes = panel.value?.topProcesses {
        if processes.isEmpty {
          PanelNote(text: "No retained process samples in this window.")
        } else {
          Table(processes) {
            TableColumn("Process") { Text(ProcessTree.displayName(name: $0.name, command: $0.command)).lineLimit(1).help($0.command) }.width(min: 80, ideal: 120)
            TableColumn("Category") { Text(ProcessTree.categoryLabel($0.category)).foregroundStyle(.secondary) }.width(min: 64, ideal: 80)
            TableColumn("CPU time") { number(DiagnosticsFormat.cpuTime(seconds: Double($0.cpuTimeMs) / 1_000)) }.width(min: 52, ideal: 66)
            TableColumn("Peak CPU") { number(DiagnosticsFormat.percent($0.maxCpuPercent)) }.width(min: 52, ideal: 66)
            TableColumn("Peak mem") { number(DiagnosticsFormat.bytes($0.peakRssBytes)) }.width(min: 56, ideal: 70)
            TableColumn("Read") { number(DiagnosticsFormat.bytes($0.ioReadBytes)) }.width(min: 52, ideal: 66)
            TableColumn("Write") { number(DiagnosticsFormat.bytes($0.ioWriteBytes)) }.width(min: 52, ideal: 66)
            TableColumn("Samples") { number(DiagnosticsFormat.count($0.sampleCount)).foregroundStyle(.secondary) }.width(min: 52, ideal: 60)
            TableColumn("PID") { number(String($0.identity.pid)).foregroundStyle(.secondary) }.width(min: 44, ideal: 56)
          }
          .alternatingRowBackgrounds().tableHeight(rows: processes.count, maxRows: 10)
        }
      }
    } header: {
      PanelHeader(title: "Resource timeline") {
        Picker("Period", selection: $controller.historyWindow) {
          ForEach(HistoryWindow.telemetry) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        RefreshControls(checkedAt: panel.value?.readAt, loading: panel.loading, label: "Refresh resource history") { controller.refreshHistory() }
      }
    }
  }

  private func number(_ text: String) -> Text { Text(text).monospacedDigit() }
}

/// Thermal throttling as this page saw it. Kept apart from the history charts so a telemetry sample redraws only this.
private struct SpeedLimitView: View {
  let controller: DiagnosticsController

  var body: some View {
    let samples = controller.speedLimit
    if samples.count >= 2 {
      VStack(alignment: .leading, spacing: 4) {
        Text("CPU speed limit (thermal throttling, seen while this page is open)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        Chart(samples) { sample in
          LineMark(x: .value("Time", sample.date), y: .value("Speed limit", sample.percent))
        }
        .chartYScale(domain: 0...100)
        .chartYAxis { AxisMarks(values: [0, 50, 100]) { value in AxisGridLine(); AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))%") } } } }
        .frame(height: 80)
        .transaction { $0.animation = nil }
      }
    } else if let power = controller.telemetry?.power, !HostSection.hasSignal(power) {
      PanelNote(text: "Thermal and power history needs the desktop host, which this server does not have.")
    }
  }
}

extension ResourceTelemetryProcessSummary: @retroactive Identifiable {
  public var id: String { "\(identity.pid):\(identity.startTimeMs)" }
}

/// "Process CPU history": the server process and its children from the server's own process sampling.
struct ProcessHistorySection: View {
  @Bindable var controller: DiagnosticsController
  @State private var selected: Date?

  var body: some View {
    let panel = controller.processHistory
    let result = panel.value
    Section {
      if let error = panel.error { ErrorLine(message: error) }
      if let problem = result?.error { ErrorLine(message: problem.message) }
      StatGrid {
        StatTile(title: "CPU time", value: result.map { DiagnosticsFormat.cpuTime(seconds: $0.totalCpuSecondsApprox) } ?? "...")
        StatTile(title: "Samples", value: result.map { DiagnosticsFormat.count($0.retainedSampleCount) } ?? "...")
        StatTile(title: "Interval", value: result.map { DiagnosticsFormat.duration(ms: Double($0.sampleIntervalMs)) } ?? "...")
        StatTile(title: "Processes", value: result.map { DiagnosticsFormat.count($0.topProcesses.count) } ?? "...")
      }
      if let result, !result.buckets.isEmpty {
        let buckets = result.buckets.filter { $0.maxProcessCount > 0 }.map { Bucket(start: $0.startedAt.instant, end: $0.endedAt.instant, cpuAverage: $0.avgCpuPercent, cpuPeak: $0.maxCpuPercent) }
        TimelineChart(
          title: "CPU", points: buckets.flatMap { [Point("Average", $0.start, $0.end, $0.cpuAverage), Point("Peak", $0.start, $0.end, $0.cpuPeak)] }, buckets: buckets, selected: $selected,
          format: { "\(Int($0))%" }, summary: { "Avg \(DiagnosticsFormat.percent($0.cpuAverage)), peak \(DiagnosticsFormat.percent($0.cpuPeak))" })
      }
      if let processes = result?.topProcesses {
        if processes.isEmpty {
          PanelNote(text: panel.loading ? "Collecting process resource samples." : "No process resource samples found for this window.")
        } else {
          Table(processes) {
            TableColumn("Process") { Text(ProcessTree.displayName(name: "", command: $0.command)).lineLimit(1).help($0.command) }.width(min: 100, ideal: 150)
            TableColumn("CPU time") { number(DiagnosticsFormat.cpuTime(seconds: $0.cpuSecondsApprox)) }
            TableColumn("Current") { number(DiagnosticsFormat.percent($0.currentCpuPercent)) }
            TableColumn("Average") { number(DiagnosticsFormat.percent($0.avgCpuPercent)) }
            TableColumn("Peak") { number(DiagnosticsFormat.percent($0.maxCpuPercent)) }
            TableColumn("Max mem") { number(DiagnosticsFormat.bytes($0.maxRssBytes)) }
            TableColumn("PID") { number(String($0.pid)).foregroundStyle(.secondary) }.width(min: 48, ideal: 60)
          }
          .alternatingRowBackgrounds().tableHeight(rows: processes.count, maxRows: 10)
        }
      }
    } header: {
      PanelHeader(title: "Process CPU history") {
        Picker("Period", selection: $controller.processWindow) {
          ForEach(HistoryWindow.processes) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        RefreshControls(checkedAt: result?.readAt, loading: panel.loading, label: "Refresh process history") { controller.refreshProcessHistory() }
      }
    }
  }

  private func number(_ text: String) -> Text { Text(text).monospacedDigit() }
}

extension ServerProcessResourceHistorySummary: @retroactive Identifiable {
  public var id: String { processKey }
}

/// "Live processes": the server's descendants as the OS reports them, with the signal buttons.
struct LiveProcessesSection: View {
  let controller: DiagnosticsController

  var body: some View {
    let panel = controller.processes
    let result = panel.value
    Section {
      if let error = panel.error { ErrorLine(message: error) }
      if let problem = result?.error { ErrorLine(message: problem.message) }
      StatGrid {
        StatTile(title: "Child processes", value: result.map { DiagnosticsFormat.count($0.processCount) } ?? "...")
        StatTile(title: "CPU", value: result.map { DiagnosticsFormat.percent($0.totalCpuPercent) } ?? "...", detail: "Children of the server process")
        StatTile(title: "Memory", value: result.map { DiagnosticsFormat.bytes($0.totalRssBytes) } ?? "...", detail: "Children of the server process")
        StatTile(title: "Server PID", value: result.map { String($0.serverPid) } ?? "...")
      }
      ProcessTable(
        controller: controller, rows: ProcessTree.rows(result?.processes ?? []), source: .diagnostics,
        emptyText: panel.loading && result == nil ? "Loading live processes." : "No live descendant processes found.")
    } header: {
      PanelHeader(title: "Live processes") {
        RefreshControls(checkedAt: result?.readAt, loading: panel.loading, label: "Refresh process diagnostics") { controller.refreshProcesses() }
      }
    }
  }
}

/// "Live process tree": every process T3 owns, from the telemetry stream.
struct ProcessTreeSection: View {
  let controller: DiagnosticsController

  var body: some View {
    let snapshot = controller.telemetry
    Section {
      ProcessTable(
        controller: controller, rows: ProcessTree.rows(snapshot?.processes ?? []), source: .telemetry, showsIO: true,
        emptyText: "Waiting for the native process monitor.")
    } header: {
      PanelHeader(title: "Live process tree") {
        if snapshot != nil { Text("Identity: PID + start time").font(.caption).foregroundStyle(.tertiary) }
      }
    }
  }
}
