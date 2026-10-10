import Observation
import SwiftUI
import T3ClientRuntime
import T3Contracts
import T3Timeline

/// Which work entries the reader opened, and what their detail loads returned. Lives on the host (not in view
/// state) so an entry stays open when its row is recycled, and so the offscreen row measurement sees the loaded
/// output too: a change here re-measures the row through the hosting view.
@MainActor @Observable
final class EntryDisclosure {
  enum Fetched {
    case loading
    case loaded(TurnItemDetail?)
    case failed(String)
  }

  private(set) var open: Set<String> = []
  /// By entry id and detail revision.
  private(set) var fetched: [String: Fetched] = [:]

  func toggle(_ id: String) {
    if !open.insert(id).inserted { open.remove(id) }
  }

  func setFetched(_ value: Fetched, for key: String) { fetched[key] = value }
}

/// The body of an opened protocol-2 work entry (the web's V2ItemInspector): the full command and its output,
/// a dynamic tool's call and result, a file change's files. Output the timeline withholds loads on demand.
struct WorkEntryDetail: View {
  let work: V2WorkItem
  let entryId: String
  @Environment(\.timelineHost) private var host
  @Environment(\.timelineRowID) private var rowID

  private var key: String { "\(entryId)#\(work.detailRevision)" }
  private var fetched: EntryDisclosure.Fetched { host?.disclosure.fetched[key] ?? .loading }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      switch work.item {
      case .commandExecution(let value):
        Mono(text: loadedDetail?.command ?? value.input)
        output(loadedDetail?.output)
        if let code = value.exitCode, code != 0 { Text("exit \(code)").font(.caption).foregroundStyle(.red) }
      case .dynamicTool(let value):
        let call = loadedDetail?.call ?? (work.needsDetailFetch ? nil : TurnItemDetail.callText(value.input))
        if let call { Mono(text: call, foreground: Palette.text) }
        output(loadedDetail?.output ?? (work.needsDetailFetch ? nil : value.output.flatMap(TurnItemDetail.format)))
      case .fileChange(let value):
        FileChangeDetail(change: value)
      default:
        EmptyView()
      }
    }
    .padding(.leading, 24)
    .padding(.vertical, 4)
    .task(id: work.detailRevision) { await load() }
  }

  private var loadedDetail: TurnItemDetail? {
    if case .loaded(let detail) = fetched { detail } else { nil }
  }

  @ViewBuilder private func output(_ text: String?) -> some View {
    if let text {
      TruncatedOutput(text: text)
    } else if work.needsDetailFetch {
      switch fetched {
      case .loading: Text("Loading output…").font(.caption).italic().foregroundStyle(Palette.muted)
      case .loaded(nil): Text("Output is no longer available.").font(.caption).foregroundStyle(Palette.muted)
      case .loaded: Text("No output.").font(.caption).italic().foregroundStyle(Palette.muted)
      case .failed(let message): Text("Couldn't load output: \(message)").font(.caption).foregroundStyle(.red)
      }
    }
  }

  private func load() async {
    guard work.needsDetailFetch, let host else { return }
    let key = key
    do {
      let detail = try await host.details.detail(thread: work.sourceThreadId, item: work.sourceItemId, revision: work.detailRevision)
      host.disclosure.setFetched(.loaded(detail), for: key)
    } catch is CancellationError {
      return
    } catch {
      host.disclosure.setFetched(.failed(error.localizedDescription), for: key)
    }
    if let rowID { host.rowChanged(rowID) }
  }
}

/// Monospaced, selectable, wrapping text.
private struct Mono: View {
  let text: String
  var foreground: Color = Palette.muted

  var body: some View {
    Text(text)
      .font(.system(size: 12, design: .monospaced))
      .foregroundStyle(foreground)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Tool output, cut to its first lines until the reader asks for the rest (the web caps the block at 20rem and scrolls).
private struct TruncatedOutput: View {
  let text: String
  @State private var showsAll = false
  private static let previewLines = 20

  var body: some View {
    let lines = text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    VStack(alignment: .leading, spacing: 4) {
      Text(text)
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(Palette.muted)
        .lineLimit(showsAll ? nil : Self.previewLines)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      if lines > Self.previewLines {
        Button(showsAll ? "Show less" : "Show \(lines - Self.previewLines) more lines") { showsAll.toggle() }
          .buttonStyle(.plain)
          .font(.caption)
          .foregroundStyle(Color.accentColor)
      }
    }
  }
}

/// A file change: counts, the change list and, like the web, "Open diff" for the diff itself (it is not part of the item).
private struct FileChangeDetail: View {
  let change: OrchestrationV2ThreadProjectionTurnItemsItemFileChange
  @Environment(\.timelineHost) private var host

  var body: some View {
    let root = host?.workspaceRoot
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(formatWorkspaceRelativePath(change.fileName, workspaceRoot: root))
          .font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
        if change.additions != nil || change.deletions != nil {
          Text("+\(change.additions ?? 0)").foregroundStyle(.green)
          Text("-\(change.deletions ?? 0)").foregroundStyle(.red)
        }
        if let runId = change.runId {
          Button("Open diff") { host?.openDiff(V1.TurnId(rawValue: runId.rawValue), change.fileName) }
            .buttonStyle(.link)
        }
      }
      .font(.caption)
      if change.status.rawValue == "failed", let diff = change.diffStr, !diff.jsTrimmedIsEmpty {
        Mono(text: diff)
      }
      ForEach(Array((change.changes ?? []).enumerated()), id: \.offset) { _, item in
        Text("\(item.operation) \(item.oldPath.map { "\($0) → " } ?? "")\(formatWorkspaceRelativePath(item.path, workspaceRoot: root))")
          .font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
      }
    }
  }
}

private extension String {
  var jsTrimmedIsEmpty: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
