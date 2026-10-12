import SwiftUI
import T3ClientRuntime
import T3Contracts

/// In-app notification toasts, top trailing over the window: a turn finished, failed or waits for the user, on a thread
/// that is not the one in view. They dismiss themselves; Open selects the thread.
struct NotificationBanners: View {
  let notifications: ThreadNotifications
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .trailing, spacing: 8) {
      ForEach(notifications.banners) { banner in
        BannerView(banner: banner, notifications: notifications)
          .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
      }
    }
    .padding(12)
    .allowsHitTesting(!notifications.banners.isEmpty)
  }
}

private struct BannerView: View {
  let banner: ThreadNotifications.Banner
  let notifications: ThreadNotifications

  var body: some View {
    let kind = banner.event.kind
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: Self.symbol(kind)).font(.title3).foregroundStyle(Self.tint(kind)).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(kind.title).font(.callout.weight(.semibold))
        Text(banner.event.threadTitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button("Open") { notifications.open(banner) }.controlSize(.small)
      Button { notifications.dismiss(banner.id) } label: { Label("Dismiss", systemImage: "xmark") }
        .labelStyle(.iconOnly).buttonStyle(.borderless).help("Dismiss")
    }
    .padding(12)
    .frame(width: 360)
    .background(.regularMaterial, in: .rect(cornerRadius: 14))
    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
    .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    .accessibilityElement(children: .contain)
  }

  private static func symbol(_ kind: ThreadNotificationKind) -> String {
    switch kind {
    case .completion: "checkmark.circle.fill"
    case .approval: "lock.shield.fill"
    case .input: "questionmark.bubble.fill"
    case .failed: "exclamationmark.octagon.fill"
    case .limited: "hourglass"
    }
  }

  private static func tint(_ kind: ThreadNotificationKind) -> Color {
    switch kind {
    case .completion: .green
    case .approval: .orange
    case .input: .blue
    case .failed, .limited: .red
    }
  }
}

/// Settings › General: tells when the chosen mode cannot show system notifications.
struct NotificationPermissionHint: View {
  @Environment(AppModel.self) private var app
  let mode: ClientSettingsSchemaNotificationMode

  var body: some View {
    if (mode == .notifications || mode == .notificationsAndSound), app.notifications.permission == .denied {
      HStack(alignment: .firstTextBaseline) {
        Label("Kestrel is not allowed to show notifications.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
        Spacer()
        Button("Open System Settings") {
          NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
        }
      }
    }
  }
}
