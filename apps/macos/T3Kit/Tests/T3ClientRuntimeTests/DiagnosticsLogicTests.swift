import Foundation
import Testing
import T3Contracts
@testable import T3ClientRuntime

@Suite struct DiagnosticsLogicTests {
  static func row(_ pid: Int, parent: Int, _ name: String, cpu: Double = 0, memory: Int = 0) -> ProcessTreeRow {
    ProcessTreeRow(pid: pid, startTimeMs: pid * 10, ppid: parent, name: name, command: name, kind: "Process", cpuPercent: cpu, memoryBytes: memory, canSignal: true)
  }

  static let rows = [
    row(10, parent: 1, "server", cpu: 1), row(11, parent: 10, "codex", cpu: 30), row(12, parent: 10, "git", cpu: 5), row(13, parent: 11, "node", cpu: 20), row(99, parent: 98, "orphan"),
  ]

  @Test func treeKeepsChildrenUnderTheirParentAndSortsSiblings() {
    let byCpu = ProcessTree.flatten(Self.rows, collapsed: [], order: [KeyPathComparator(\.cpuPercent, order: .reverse)])
    #expect(byCpu.map(\.pid) == [10, 11, 13, 12, 99])
    #expect(byCpu.first { $0.pid == 13 }?.depth == 2)
    #expect(byCpu.first { $0.pid == 10 }?.hasChildren == true && byCpu.first { $0.pid == 12 }?.hasChildren == false)
    let byName = ProcessTree.flatten(Self.rows, collapsed: [], order: [KeyPathComparator(\.name)])
    #expect(byName.map(\.pid).filter { [11, 12].contains($0) } == [11, 12])  // codex before git
  }

  @Test func collapsingHidesTheWholeSubtree() {
    let flat = ProcessTree.flatten(Self.rows, collapsed: ["11:110"], order: [KeyPathComparator(\.pid)])
    #expect(flat.map(\.pid) == [10, 11, 12, 99])
    #expect(ProcessTree.flatten(Self.rows, collapsed: ["10:100"], order: [KeyPathComparator(\.pid)]).map(\.pid) == [10, 99])
  }

  @Test func aParentCycleCannotLoopForever() {
    let cyclic = [Self.row(1, parent: 2, "a"), Self.row(2, parent: 1, "b")]
    #expect(ProcessTree.flatten(cyclic, collapsed: [], order: []).count <= 2)
  }

  @Test func namesFallBackToTheExecutable() {
    #expect(ProcessTree.displayName(name: "", command: "\"/usr/bin/git\" status") == "git")
    #expect(ProcessTree.displayName(name: "codex", command: "/x/y") == "codex")
  }

  @Test func retryIsOfferedOnlyForADeadCollector() {
    #expect(DiagnosticsLogic.showsMonitorRetry(nativeStatus: nil, error: "boom"))
    #expect(!DiagnosticsLogic.showsMonitorRetry(nativeStatus: nil, error: nil))
    #expect(DiagnosticsLogic.showsMonitorRetry(nativeStatus: .degraded, error: nil))
    #expect(!DiagnosticsLogic.showsMonitorRetry(nativeStatus: .healthy, error: nil))
  }

  @Test func observabilitySummaryCollapsesMatchingSignalUrls() {
    func summary(local: Bool, traces: String?, metrics: String?) -> String {
      DiagnosticsLogic.observabilitySummary(
        ServerObservability(
          logsDirectoryPath: "/logs", localTracingEnabled: local, otlpTracesUrl: traces, otlpTracesEnabled: traces != nil, otlpMetricsUrl: metrics, otlpMetricsEnabled: metrics != nil))
    }
    #expect(summary(local: true, traces: nil, metrics: nil) == "Local trace file.")
    #expect(summary(local: false, traces: "http://h/v1/traces", metrics: "http://h/v1/metrics") == "Terminal logs only. Exporting OTEL to http://h/v1/{traces,metrics}.")
    #expect(summary(local: true, traces: "http://a/traces", metrics: "http://b/metrics") == "Local trace file. Exporting OTEL traces to http://a/traces and metrics to http://b/metrics.")
  }
}
