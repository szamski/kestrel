import ClerkKit
import Foundation

/// `CloudSession` over clerk-ios (ClerkKit, macOS 14+). Clerk owns session storage and the system web-authentication
/// callback; this wrapper only asks for the account and the relay token.
///
/// Redirect: Clerk's native OAuth redirect is `<bundle id>://callback` and must be on the Clerk instance's
/// "Allowlist for mobile SSO redirect". Email-code sign-in needs no redirect.
@MainActor
public final class ClerkCloudSession: CloudSession {
  private let clerk: Clerk
  private let template: String
  private var pendingEmailSignIn: SignIn?
  private let changes: AsyncStream<CloudAccount?>
  private let changesContinuation: AsyncStream<CloudAccount?>.Continuation
  private var eventTask: Task<Void, Never>?

  public init(configuration: T3ConnectConfiguration, bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "codes.t3.macos") {
    template = configuration.clerkJWTTemplate
    clerk = Clerk.configure(
      publishableKey: configuration.clerkPublishableKey,
      options: .init(
        // No usage telemetry to a third party by default.
        telemetryEnabled: false,
        keychainConfig: .init(service: bundleIdentifier),
        redirectConfig: .init(redirectUrl: "\(bundleIdentifier)://callback", callbackUrlScheme: bundleIdentifier)))
    (changes, changesContinuation) = AsyncStream.makeStream(of: CloudAccount?.self, bufferingPolicy: .bufferingNewest(1))
    eventTask = Task { [weak self, events = clerk.auth.events] in
      for await _ in events {
        guard let self else { return }
        changesContinuation.yield(account)
      }
    }
  }

  isolated deinit { eventTask?.cancel() }

  public var account: CloudAccount? {
    guard let user = clerk.user else { return nil }
    return CloudAccount(id: user.id, email: user.primaryEmailAddress?.emailAddress, imageURL: user.hasImage ? URL(string: user.imageUrl) : nil)
  }

  public var accountChanges: AsyncStream<CloudAccount?> { changes }

  public func refresh() async {
    _ = try? await clerk.refreshClient()
    changesContinuation.yield(account)
  }

  public func relayToken() async throws -> String {
    guard clerk.session != nil else { throw CloudSessionError.signedOut }
    // Same as web (`relayClerkTokenOptions`): skip Clerk's cache.
    guard let token = try await clerk.auth.getToken(.init(template: template, skipCache: true)), !token.isEmpty else { throw CloudSessionError.signedOut }
    return token
  }

  public func signIn(with provider: CloudSignInProvider) async throws {
    let oauth: OAuthProvider =
      switch provider {
      case .github: .github
      case .google: .google
      case .microsoft: .microsoft
      case .apple: .apple
      }
    try await clerk.auth.signInWithOAuth(provider: oauth)
    try requireAccount("Sign-in needs another step. Finish it at app.t3.codes, then try again.")
  }

  public func startEmailCode(email: String) async throws {
    pendingEmailSignIn = try await clerk.auth.signInWithEmailCode(emailAddress: email.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  public func verifyEmailCode(_ code: String) async throws {
    guard let pending = pendingEmailSignIn else { throw CloudSessionError.incomplete("Request a code first.") }
    try await pending.verifyCode(code.trimmingCharacters(in: .whitespacesAndNewlines))
    pendingEmailSignIn = nil
    try requireAccount("This account needs another verification step. Sign in at app.t3.codes first.")
  }

  public func signOut() async throws {
    pendingEmailSignIn = nil
    try await clerk.auth.signOut()
    changesContinuation.yield(account)
  }

  private func requireAccount(_ message: String) throws {
    guard account != nil else { throw CloudSessionError.incomplete(message) }
    changesContinuation.yield(account)
  }
}
