import SwiftUI
import T3Contracts

enum StatTone { case normal, warning, danger }

/// One labelled figure, like the web stat blocks.
struct StatTile: View {
  let title: String
  let value: String
  var detail: String?
  var tone: StatTone = .normal

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
      if let detail { Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private var color: Color {
    switch tone {
    case .normal: .primary
    case .warning: .orange
    case .danger: .red
    }
  }
}

/// A wrapping row of stat tiles.
struct StatGrid<Content: View>: View {
  var minimum: CGFloat = 150
  @ViewBuilder var content: Content

  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 16, alignment: .topLeading)], alignment: .leading, spacing: 12) { content }
      .padding(.vertical, 4)
  }
}

/// Section title with trailing controls.
struct PanelHeader<Trailing: View>: View {
  let title: String
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack(spacing: 8) {
      Text(title)
      Spacer(minLength: 8)
      trailing
    }
  }
}

/// "Checked 3 minutes ago" plus a refresh button that shows a spinner while the read is out.
struct RefreshControls: View {
  let checkedAt: IsoDateTime?
  let loading: Bool
  let label: String
  let refresh: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      if let checkedAt {
        Text("Checked \(checkedAt.instant, style: .relative) ago").font(.caption).monospacedDigit().foregroundStyle(.tertiary)
      } else {
        Text(loading ? "Checking" : "Not checked").font(.caption).foregroundStyle(.tertiary)
      }
      if loading {
        ProgressView().controlSize(.small)
      } else {
        Button(action: refresh) { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.borderless).help(label).accessibilityLabel(label)
      }
    }
  }
}

/// A destructive-looking line for a failed read.
struct ErrorLine: View {
  let message: String
  var warning = false

  var body: some View {
    Label {
      Text(message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(warning ? .orange : .red)
    }
  }
}

/// The empty or unavailable state of a panel.
struct PanelNote: View {
  let text: String
  var body: some View { Text(text).font(.callout).foregroundStyle(.secondary) }
}

extension View {
  /// A table that sizes to its rows up to `maxRows`, then scrolls: tables sit inside the page's own scroll view.
  func tableHeight(rows: Int, maxRows: Int = 12) -> some View { frame(height: CGFloat(min(max(rows, 1), maxRows)) * 26 + 34) }
}
