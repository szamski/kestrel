import SwiftUI
import T3ClientRuntime
import T3Contracts

/// The icon choices of the web picker (`projectIconOptions.ts`) with the SF Symbol each Lucide name maps to. The web
/// searches every Lucide icon; this build offers the curated set, and shows a folder for any other name a project already has.
enum ProjectIconOptions {
  static let icons: [(name: String, symbol: String)] = [
    ("folder-code", "folder"), ("code-2", "chevron.left.forwardslash.chevron.right"), ("terminal", "terminal"), ("globe-2", "globe"),
    ("server", "server.rack"), ("database", "cylinder"), ("bot", "cpu"), ("sparkles", "sparkles"), ("smartphone", "iphone"), ("monitor", "display"),
    ("cloud-cog", "cloud"), ("package", "shippingbox"), ("book-open", "book"), ("flask-conical", "testtube.2"), ("shield-check", "checkmark.shield"),
    ("rocket", "paperplane"), ("gamepad-2", "gamecontroller"), ("music", "music.note"), ("image", "photo"), ("shopping-bag", "bag"),
    ("git-branch", "arrow.triangle.branch"), ("workflow", "point.3.connected.trianglepath.dotted"), ("wrench", "wrench"), ("layers-3", "square.3.layers.3d"),
  ]

  static let emojis: [(emoji: String, label: String)] = [
    ("💻", "Computer"), ("🛠️", "Tools"), ("🚀", "Rocket"), ("🤖", "Robot"), ("✨", "Sparkles"), ("⚡", "Lightning"), ("🌐", "Web"), ("📱", "Mobile"),
    ("🖥️", "Desktop"), ("⌨️", "Keyboard"), ("⚙️", "Gear"), ("🗄️", "Database"), ("☁️", "Cloud"), ("📦", "Package"), ("📚", "Books"), ("🧪", "Test tube"),
    ("🔒", "Lock"), ("🎮", "Game"), ("🎵", "Music"), ("🎬", "Movie"), ("🖼️", "Picture"), ("🛍️", "Shopping"), ("🔥", "Fire"), ("💡", "Idea"),
    ("🧩", "Puzzle"), ("📊", "Chart"), ("🧠", "Brain"), ("🦄", "Unicorn"), ("🐙", "Octopus"), ("🌱", "Seedling"),
  ]

  static func symbol(_ lucideName: String) -> String { icons.first { $0.name == lucideName }?.symbol ?? "folder" }

  static func title(_ name: String) -> String { name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ") }

  /// Narrows the curated list the way the web search narrows Lucide's.
  static func filter(_ query: String) -> [(name: String, symbol: String)] {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "-")
    return needle.isEmpty ? icons : icons.filter { $0.name.contains(needle) }
  }
}

extension ProjectIconColor {
  var swiftUI: Color {
    switch self {
    case .red: .red
    case .orange: .orange
    case .amber: Color(red: 0.96, green: 0.62, blue: 0.04)
    case .yellow: .yellow
    case .lime: Color(red: 0.52, green: 0.80, blue: 0.09)
    case .green: .green
    case .emerald: Color(red: 0.06, green: 0.73, blue: 0.51)
    case .teal: .teal
    case .cyan: .cyan
    case .sky: Color(red: 0.05, green: 0.65, blue: 0.91)
    case .blue: .blue
    case .indigo: .indigo
    case .violet: Color(red: 0.55, green: 0.36, blue: 0.96)
    case .purple: .purple
    case .fuchsia: Color(red: 0.85, green: 0.27, blue: 0.94)
    case .pink: .pink
    case .rose: Color(red: 0.96, green: 0.25, blue: 0.37)
    default: .gray
    }
  }

  var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// A project's chosen icon in the shape the picker and the glyph share. Servers that predate monograms send one as a
/// Lucide icon carrying its text, which reads as a monogram here.
enum ProjectIconChoice: Equatable {
  case lucide(String, ProjectIconColor)
  case emoji(String)
  case monogram(String, ProjectIconColor)

  init?(_ icon: V1.ProjectIconOverride) {
    switch icon {
    case .lucide(let lucide):
      if let text = lucide.monogramText ?? lucide.monogram { self = .monogram(text, lucide.color) } else { self = .lucide(lucide.name, lucide.color) }
    case .emoji(let emoji): self = .emoji(emoji.emoji)
    case .monogram(let monogram): self = .monogram(monogram.text, monogram.color)
    case .unknown: return nil
    }
  }

  /// What `project.update` sends.
  var override: ProjectIconOverride {
    switch self {
    case .lucide(let name, let color): .lucide(ProjectIconOverrideLucide(name: name, color: color))
    case .emoji(let emoji): .emoji(ProjectIconOverrideEmoji(emoji: emoji))
    case .monogram(let text, let color): .monogram(ProjectIconOverrideMonogram(text: text, color: color))
    }
  }

  var summary: String {
    switch self {
    case .lucide(let name, let color): "\(name) \u{00B7} \(color.rawValue)"
    case .emoji(let emoji): emoji
    case .monogram(let text, let color): "\(text) \u{00B7} \(color.rawValue)"
    }
  }
}

extension EnvironmentProject {
  var iconChoice: ProjectIconChoice? {
    if case .some(.some(let icon)) = project.projectIcon { return ProjectIconChoice(icon) }
    return nil
  }

  var faviconPath: String? {
    if case .some(.some(let path)) = project.faviconPath { return path }
    return nil
  }
}

/// What a project shows next to its name: its chosen icon, else a monogram derived from the name.
struct ProjectGlyph: View {
  let project: EnvironmentProject
  var size: CGFloat = 26

  var body: some View {
    switch project.iconChoice {
    case .lucide(let name, let color): Image(systemName: ProjectIconOptions.symbol(name)).font(.system(size: size * 0.62)).foregroundStyle(color.swiftUI).frame(width: size, height: size)
    case .emoji(let emoji): Text(emoji).font(.system(size: size * 0.7)).frame(width: size, height: size)
    case .monogram(let text, let color): ProjectMonogram(text: text, color: color, size: size)
    case nil:
      if project.faviconPath != nil {
        Image(systemName: "photo").font(.system(size: size * 0.6)).foregroundStyle(.secondary).frame(width: size, height: size)
      } else {
        let identity = ProjectIdentity.derive(project.project.title)
        ProjectMonogram(text: identity.monogram, color: identity.color, size: size)
      }
    }
  }
}

struct ProjectMonogram: View {
  let text: String
  let color: ProjectIconColor
  var size: CGFloat = 26

  var body: some View {
    Text(text).font(.system(size: size * 0.42, weight: .semibold, design: .rounded)).foregroundStyle(color.swiftUI)
      .frame(width: size, height: size)
      .background(color.swiftUI.opacity(0.16), in: RoundedRectangle(cornerRadius: size * 0.26))
  }
}
