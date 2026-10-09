import SwiftUI
import T3Contracts

/// The "Dev" marker of a development build in the sidebar, controlled by Environment identification. The web draws product
/// artwork behind the sidebar for the Artwork choice; this app has no such artwork, so Artwork shows the pill as well.
struct StageBadge: View {
  var body: some View {
    if let label = AppTheme.shared.stageLabel, ClientSettingsStore.shared.client.environmentIdentificationMode != .noneValue {
      HStack {
        Text(label.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(Palette.accent)
          .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Palette.accent.opacity(0.16)))
          .accessibilityLabel("\(label) environment")
        Spacer()
      }
      .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 2)
      .themedBarBackground()
    }
  }
}
